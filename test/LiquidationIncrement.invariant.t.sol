// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {APPROVED_OPERATOR, FEE_RECIPIENT} from "../src/DeploymentConfig.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {SplitVault} from "./LiquidationIncrement.t.sol";

/// @dev Drives the increment's vault through random borrower, keeper and liquidator actions with the
/// spot feed moving in and out of the divergence bound. Every call either succeeds or reverts with the
/// error the handler predicted; anything else fails the campaign because fail_on_revert is set.
contract IncrementHandler is Test {
    uint256 public constant MAX_DIVERGENCE_BPS = 500;
    uint256 public constant MARKER_SHARE_BPS = 1000;
    uint256 public constant PROTOCOL_SHARE_BPS = 2000;
    uint256 public constant PAYOUT_SCALE = 1.1e18;
    uint256 public constant INITIAL_IMD = 1e30;

    MockIMD public imd;
    CompToken public comp;
    MockWorkOracle public oracle;
    SplitVault public vault;
    TestSwarmFeed public primary;
    TestSwarmFeed public spot;
    TestSwarmFeed public nhi;
    uint256 public immutable rate;

    address[3] public borrowers = [address(0x2001), address(0x2002), address(0x2003)];
    address[2] public keepers = [address(0x2101), address(0x2102)];
    address[2] public liquidators = [address(0x2201), address(0x2202)];

    // Ghost accounting.
    uint256 public protocolIMDPaid;
    uint256 public markerIMDPaid;
    uint256 public liquidatorIMDPaid;
    uint256 public totalSeized;
    uint256 public lastFeesMinted;
    uint256 public liquidations;
    uint256 public exhaustingLiquidations;
    uint256 public combinedPayouts;
    uint256 public guardedRejections;
    uint256 public divergentRepayments;
    uint256 public divergentExits;
    uint256 public marks;
    uint256 public feeAccrualChecks;
    uint256 public incidentalClears;
    uint256 public disputedClearsRefused;

    constructor(uint256 rate_) {
        rate = rate_;
        imd = new MockIMD();
        primary = new TestSwarmFeed(1 ether);
        spot = new TestSwarmFeed(1 ether);
        nhi = new TestSwarmFeed(0.85 ether);
        vault = new SplitVault(
            address(imd),
            address(primary),
            address(nhi),
            address(spot),
            MAX_DIVERGENCE_BPS,
            MARKER_SHARE_BPS,
            rate_,
            PROTOCOL_SHARE_BPS
        );
        comp = vault.compToken();
        oracle = MockWorkOracle(address(vault.oracle()));
        for (uint256 i; i < borrowers.length; ++i) {
            _fund(borrowers[i]);
            vm.startPrank(borrowers[i]);
            vault.depositCollateral(300 ether);
            vault.mintCOMP(100 ether);
            vm.stopPrank();
        }
        for (uint256 i; i < liquidators.length; ++i) {
            _fund(liquidators[i]);
        }
        for (uint256 i; i < keepers.length; ++i) {
            _fund(keepers[i]);
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Borrower actions
    // ------------------------------------------------------------------------------------------------

    /// @dev A deposit must succeed under every spot state; what the spot decides is only whether the
    /// recovery it causes may discard a live mark.
    function deposit(uint256 seed, uint256 amount) external {
        address actor = borrowers[seed % borrowers.length];
        amount = bound(amount, 1, 1000 ether);
        MarkBefore memory before = _markBefore(actor);
        vm.prank(actor);
        vault.depositCollateral(amount);
        _checkIncidentalClear(actor, before);
    }

    function mintDebt(uint256 seed, uint256 amount) external {
        address actor = borrowers[seed % borrowers.length];
        amount = bound(amount, 1, 500 ether);
        bytes4 guard = _guardError();
        vm.prank(actor);
        try vault.mintCOMP(amount) {
            assertEq(guard, bytes4(0), "mint passed a failing guard");
        } catch (bytes memory reason) {
            _expectGuardOr(reason, guard, CDPVault.UnsafeCollateralRatio.selector);
            if (guard != bytes4(0)) ++guardedRejections;
        }
    }

    function mintWork(uint256 seed, uint256 amount) external {
        address actor = borrowers[seed % borrowers.length];
        amount = bound(amount, 1, 100 ether);
        _grant(actor, amount);
        vm.prank(actor);
        vault.mintFromWork(amount);
    }

    /// @dev Repayment must succeed under every spot state, so no try/catch here.
    function repay(uint256 seed, uint256 amount) external {
        address actor = borrowers[seed % borrowers.length];
        uint256 owed = vault.debtOf(actor);
        if (owed == 0) return;
        amount = bound(amount, 1, owed);
        _ensureComp(actor, amount);
        uint256 feeBefore = vault.feeOf(actor);
        uint256 feesMintedBefore = vault.totalFeesMinted();
        uint256 recipientBefore = comp.balanceOf(FEE_RECIPIENT);
        uint256 recordedBefore = vault.recordedBadDebtOf(actor);
        bool diverged = _guardError() != bytes4(0);
        MarkBefore memory before = _markBefore(actor);

        vm.prank(actor);
        vault.repayCOMP(amount);

        _checkIncidentalClear(actor, before);
        uint256 feePaid = Math.min(amount, feeBefore);
        assertEq(vault.debtOf(actor), owed - amount, "repayment reduces accrued debt one for one");
        assertEq(vault.feeOf(actor), feeBefore - feePaid, "fees are paid first");
        assertEq(vault.totalFeesMinted() - feesMintedBefore, feePaid, "only the fee portion is minted");
        assertEq(comp.balanceOf(FEE_RECIPIENT) - recipientBefore, feePaid, "minted to the recipient");
        if (recordedBefore != 0) {
            assertLe(vault.recordedBadDebtOf(actor), recordedBefore, "a payment never grows the record");
        }
        lastFeesMinted = vault.totalFeesMinted();
        if (diverged) ++divergentRepayments;
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address actor = borrowers[seed % borrowers.length];
        (uint256 collateral, uint256 debt) = vault.positions(actor);
        if (collateral == 0) return;
        amount = bound(amount, 1, collateral);
        if (debt == 0) {
            // A debt-free exit must succeed whatever the spot says.
            bool diverged = _guardError() != bytes4(0);
            vm.prank(actor);
            vault.withdrawCollateral(amount);
            if (diverged) ++divergentExits;
            return;
        }
        // A withdrawal against open debt is price-dependent: the divergence guard comes first, and only
        // an agreeing spot lets the health check decide.
        bytes4 guard = _guardError();
        vm.prank(actor);
        try vault.withdrawCollateral(amount) {
            assertEq(guard, bytes4(0), "debt-bearing withdrawal passed a failing guard");
        } catch (bytes memory reason) {
            _expectGuardOr(reason, guard, CDPVault.UnsafeCollateralRatio.selector);
            if (guard != bytes4(0)) ++guardedRejections;
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Market and time
    // ------------------------------------------------------------------------------------------------

    function setMarket(uint256 priceSeed, uint256 nhiSeed) external {
        uint256[5] memory prices = [uint256(0.5 ether), 0.8 ether, 1 ether, 1.2 ether, 2 ether];
        uint256[3] memory nhis = [uint256(0.6 ether), 0.7 ether, 0.85 ether];
        uint256 price = prices[priceSeed % prices.length];
        primary.setValue(price);
        spot.setValue(price);
        spot.setStale(false);
        nhi.setValue(nhis[nhiSeed % nhis.length]);
    }

    function setSpot(uint256 mode) external {
        mode %= 8;
        (uint256 price,) = primary.latestValue();
        uint256 tolerance = Math.mulDiv(price, MAX_DIVERGENCE_BPS, 10_000);
        spot.setStale(false);
        if (mode == 0) spot.setValue(price);
        else if (mode == 1) spot.setValue(price + tolerance);
        else if (mode == 2) spot.setValue(price - tolerance);
        else if (mode == 3) spot.setValue(price + tolerance + 1);
        else if (mode == 4) spot.setValue(price - tolerance - 1);
        else if (mode == 5) spot.setStale(true);
        else if (mode == 6) spot.setValue(0);
        else spot.setValue(price * 10);
    }

    function advanceTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 2 days);
        uint256[3] memory debtsBefore;
        uint256[3] memory principals;
        for (uint256 i; i < borrowers.length; ++i) {
            debtsBefore[i] = vault.debtOf(borrowers[i]);
            principals[i] = debtsBefore[i] - vault.feeOf(borrowers[i]);
        }
        uint256 indexBefore = vault.debtIndex();
        uint256 badDebtBefore = vault.totalBadDebt();
        uint256 feesMintedBefore = vault.totalFeesMinted();

        vm.warp(block.timestamp + seconds_);

        uint256 delta = vault.debtIndex() - indexBefore;
        for (uint256 i; i < borrowers.length; ++i) {
            uint256 grown = vault.debtOf(borrowers[i]) - debtsBefore[i];
            uint256 expected = Math.mulDiv(principals[i], delta, 1e18);
            // The carried remainder can add at most one minor unit over the floor.
            assertGe(grown, expected, "accrual below the linear index");
            assertLe(grown, expected + 1, "accrual above the linear index");
            if (rate == 0 || principals[i] == 0) assertEq(grown, 0, "nothing accrues without rate or principal");
            ++feeAccrualChecks;
        }
        assertEq(vault.totalBadDebt(), badDebtBefore, "time alone never moves the accumulator");
        assertEq(vault.totalFeesMinted(), feesMintedBefore, "time alone never mints");
    }

    // ------------------------------------------------------------------------------------------------
    // Keeper and liquidator actions
    // ------------------------------------------------------------------------------------------------

    function mark(uint256 keeperSeed, uint256 ownerSeed) external {
        address keeper = keepers[keeperSeed % keepers.length];
        address owner = borrowers[ownerSeed % borrowers.length];
        bytes4 guard = _guardError();
        (uint256 atBefore, uint256 graceBefore, bool markedBefore, address markerBefore) = vault.liquidationMarks(owner);
        bool activeBefore = markedBefore && block.timestamp <= atBefore + graceBefore + vault.liquidationWindow();
        uint256 grace = vault.gracePeriod();

        vm.prank(keeper);
        try vault.markUnderwater(owner) {
            assertEq(guard, bytes4(0), "mark passed a failing guard");
            (uint256 at, uint256 g, bool marked, address marker) = vault.liquidationMarks(owner);
            assertTrue(marked);
            if (activeBefore) {
                assertEq(at, atBefore, "active mark keeps its timestamp");
                assertEq(g, graceBefore, "active mark keeps its grace");
                assertEq(marker, markerBefore, "active mark keeps its marker");
            } else {
                assertEq(at, block.timestamp, "fresh mark is stamped now");
                assertEq(g, grace, "fresh mark snapshots the current grace");
                assertEq(marker, keeper, "fresh mark records its keeper");
                ++marks;
            }
        } catch (bytes memory reason) {
            _expectGuardOr(reason, guard, CDPVault.HealthyPosition.selector);
            if (guard != bytes4(0)) ++guardedRejections;
        }
    }

    function clearMark(uint256 seed, uint256 ownerSeed) external {
        address owner = borrowers[ownerSeed % borrowers.length];
        // Recovery is judged at the primary price, so a disputed primary cannot discard a live mark:
        // the divergence guard comes before the health check here as well.
        bytes4 guard = _guardError();
        (,, bool markedBefore,) = vault.liquidationMarks(owner);
        vm.prank(keepers[seed % keepers.length]);
        try vault.clearRecoveredMark(owner) {
            assertEq(guard, bytes4(0), "clear passed a failing guard");
            (,, bool marked, address marker) = vault.liquidationMarks(owner);
            assertFalse(marked, "a successful clear leaves no mark");
            assertEq(marker, address(0), "a successful clear leaves no marker");
        } catch (bytes memory reason) {
            _expectGuardOr(reason, guard, CDPVault.UnderwaterPosition.selector);
            (,, bool marked,) = vault.liquidationMarks(owner);
            assertEq(marked, markedBefore, "a rejected clear leaves the mark as it was");
            if (guard != bytes4(0)) ++guardedRejections;
        }
    }

    function liquidate(uint256 liquidatorSeed, uint256 ownerSeed, uint256 amount, bool asMarker) external {
        address owner = borrowers[ownerSeed % borrowers.length];
        (,, bool marked, address marker) = vault.liquidationMarks(owner);
        address liquidator = asMarker && marked ? marker : liquidators[liquidatorSeed % liquidators.length];
        uint256 owed = vault.debtOf(owner);
        if (owed == 0) return;
        amount = bound(amount, 1, owed);
        _ensureComp(liquidator, amount);

        bytes4 guard = _guardError();
        Snapshot memory s = _snapshot(owner, liquidator, marker, amount);

        vm.prank(liquidator);
        try vault.liquidate(owner, amount) {
            assertEq(guard, bytes4(0), "liquidation passed a failing guard");
            _checkLiquidation(owner, liquidator, marker, s);
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            if (guard != bytes4(0)) {
                assertEq(selector, guard, "guard error must come first");
                ++guardedRejections;
            } else {
                assertTrue(
                    selector == CDPVault.HealthyPosition.selector || selector == CDPVault.PositionNotMarked.selector
                        || selector == CDPVault.GracePeriodNotElapsed.selector
                        || selector == CDPVault.MarkExpired.selector
                        || selector == CDPVault.InsufficientCollateral.selector,
                    "unexpected liquidation error"
                );
            }
        }
    }

    struct Snapshot {
        uint256 amount;
        uint256 seized;
        uint256 markerCut;
        uint256 protocolCut;
        uint256 ownerCollateral;
        uint256 ownerDebt;
        uint256 ownerFee;
        uint256 liquidatorIMD;
        uint256 markerIMD;
        uint256 protocolIMD;
        uint256 vaultIMD;
        uint256 feesMinted;
        uint256 recorded;
        uint256 badDebt;
        uint256 totalDebt;
    }

    function _snapshot(address owner, address liquidator, address marker, uint256 amount)
        private
        view
        returns (Snapshot memory s)
    {
        (uint256 price,) = primary.latestValue();
        s.amount = amount;
        s.seized = Math.mulDiv(amount, PAYOUT_SCALE, price);
        uint256 bonus = s.seized - Math.mulDiv(amount, 1e18, price);
        s.markerCut = Math.mulDiv(bonus, MARKER_SHARE_BPS, 10_000);
        s.protocolCut = Math.mulDiv(bonus, PROTOCOL_SHARE_BPS, 10_000);
        (s.ownerCollateral, s.ownerDebt) = vault.positions(owner);
        s.ownerFee = vault.feeOf(owner);
        s.liquidatorIMD = imd.balanceOf(liquidator);
        s.markerIMD = imd.balanceOf(marker);
        s.protocolIMD = imd.balanceOf(FEE_RECIPIENT);
        s.vaultIMD = imd.balanceOf(address(vault));
        s.feesMinted = vault.totalFeesMinted();
        s.recorded = vault.recordedBadDebtOf(owner);
        s.badDebt = vault.totalBadDebt();
        s.totalDebt = vault.totalDebt();
    }

    function _checkLiquidation(address owner, address liquidator, address marker, Snapshot memory s) private {
        uint256 amount = s.amount;
        uint256 seized = s.seized;
        uint256 markerCut = s.markerCut;
        uint256 protocolCut = s.protocolCut;
        (uint256 collateral, uint256 debt) = vault.positions(owner);
        assertEq(s.ownerCollateral - collateral, seized, "borrower loses exactly the seized collateral");
        assertEq(s.ownerDebt - debt, amount, "debt falls by the repaid amount");
        assertEq(s.vaultIMD - imd.balanceOf(address(vault)), seized, "the vault pays out exactly seized");
        uint256 feePaid = Math.min(amount, s.ownerFee);
        assertEq(vault.totalFeesMinted() - s.feesMinted, feePaid, "liquidator pays the fee portion first");
        assertEq(s.totalDebt - vault.totalDebt(), amount - feePaid, "only principal frees headroom");

        if (liquidator == marker) {
            assertEq(imd.balanceOf(liquidator) - s.liquidatorIMD, seized - protocolCut, "combined payout");
            ++combinedPayouts;
            markerIMDPaid += markerCut;
            liquidatorIMDPaid += seized - protocolCut - markerCut;
        } else {
            assertEq(imd.balanceOf(liquidator) - s.liquidatorIMD, seized - markerCut - protocolCut, "liquidator");
            assertEq(imd.balanceOf(marker) - s.markerIMD, markerCut, "marker");
            markerIMDPaid += markerCut;
            liquidatorIMDPaid += seized - protocolCut - markerCut;
        }
        assertEq(imd.balanceOf(FEE_RECIPIENT) - s.protocolIMD, protocolCut, "protocol");
        protocolIMDPaid += protocolCut;
        totalSeized += seized;
        lastFeesMinted = vault.totalFeesMinted();
        ++liquidations;

        if (collateral == 0) {
            assertEq(vault.recordedBadDebtOf(owner), debt, "exhausted collateral records the full remainder");
            assertEq(vault.totalBadDebt() + s.recorded, s.badDebt + debt, "accumulator moves by the record delta");
            if (debt != 0) ++exhaustingLiquidations;
        } else if (s.recorded == 0) {
            assertEq(vault.recordedBadDebtOf(owner), 0, "collateral left: nothing new is recorded");
            assertEq(vault.totalBadDebt(), s.badDebt, "accumulator untouched");
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------

    struct MarkBefore {
        uint256 at;
        uint256 grace;
        bool marked;
        address marker;
    }

    function _markBefore(address owner) private view returns (MarkBefore memory m) {
        (m.at, m.grace, m.marked, m.marker) = vault.liquidationMarks(owner);
    }

    /// @dev Mirrors _clearIfRecovered after a deposit or repayment: a debt-free position clears its mark
    /// unconditionally; a debt-bearing one clears only when the spot agrees with the primary and the
    /// position is healthy at the primary; a disputed spot leaves the whole mark untouched.
    function _checkIncidentalClear(address owner, MarkBefore memory before) private {
        (uint256 at, uint256 grace, bool marked, address marker) = vault.liquidationMarks(owner);
        if (!before.marked) {
            assertFalse(marked, "deposit and repayment never create a mark");
            return;
        }
        bool healthyAtPrimary = vault.debtOf(owner) == 0 || vault.collateralRatio(owner) >= vault.minCR();
        bool shouldClear = vault.debtOf(owner) == 0 || (_guardError() == bytes4(0) && healthyAtPrimary);
        if (shouldClear) {
            assertFalse(marked, "recovery with an agreeing spot clears the mark");
            assertEq(marker, address(0), "a cleared mark forgets its keeper");
            ++incidentalClears;
        } else {
            assertTrue(marked, "a disputed or still-underwater mark survives");
            assertEq(at, before.at, "kept mark keeps its timestamp");
            assertEq(grace, before.grace, "kept mark keeps its grace snapshot");
            assertEq(marker, before.marker, "kept mark keeps its marker");
            if (healthyAtPrimary) ++disputedClearsRefused;
        }
    }

    /// @dev Mirrors _requirePriceAgreement: the error every price-dependent entry point (mint, mark,
    /// liquidate, clear and a debt-bearing withdrawal) must surface before any other check.
    function _guardError() private view returns (bytes4) {
        if (spot.isStale()) return CDPVault.StaleFeed.selector;
        (uint256 spotPrice,) = spot.latestValue();
        if (spotPrice == 0) return CDPVault.InvalidPrice.selector;
        (uint256 price,) = primary.latestValue();
        uint256 difference = spotPrice > price ? spotPrice - price : price - spotPrice;
        if (difference > Math.mulDiv(price, MAX_DIVERGENCE_BPS, 10_000)) return CDPVault.PriceDivergence.selector;
        return bytes4(0);
    }

    function _expectGuardOr(bytes memory reason, bytes4 guard, bytes4 other) private pure {
        bytes4 selector = bytes4(reason);
        if (guard != bytes4(0)) {
            assertEq(selector, guard, "guard error must come first");
        } else {
            assertEq(selector, other, "unexpected error with an agreeing spot");
        }
    }

    function _fund(address user) private {
        vm.prank(APPROVED_OPERATOR);
        imd.mint(user, INITIAL_IMD);
        vm.prank(user);
        imd.approve(address(vault), type(uint256).max);
    }

    function _grant(address user, uint256 amount) private {
        vm.prank(APPROVED_OPERATOR);
        oracle.grantRights(user, amount);
    }

    function _ensureComp(address user, uint256 amount) private {
        uint256 balance = comp.balanceOf(user);
        if (balance >= amount) return;
        uint256 shortfall = amount - balance;
        _grant(user, shortfall);
        vm.prank(user);
        vault.mintFromWork(shortfall);
    }

    function borrowerCount() external view returns (uint256) {
        return borrowers.length;
    }

    function liquidatorCount() external view returns (uint256) {
        return liquidators.length;
    }

    function keeperCount() external view returns (uint256) {
        return keepers.length;
    }
}

abstract contract IncrementInvariantBase is StdInvariant, Test {
    IncrementHandler internal handler;
    SplitVault internal vault;
    CompToken internal comp;
    MockIMD internal imd;

    function _rate() internal pure virtual returns (uint256);

    function setUp() public {
        vm.warp(10 days);
        handler = new IncrementHandler(_rate());
        vault = handler.vault();
        comp = handler.comp();
        imd = handler.imd();
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.mintDebt.selector;
        selectors[2] = handler.mintWork.selector;
        selectors[3] = handler.repay.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.setMarket.selector;
        selectors[6] = handler.setSpot.selector;
        selectors[7] = handler.advanceTime.selector;
        selectors[8] = handler.mark.selector;
        selectors[9] = handler.clearMark.selector;
        selectors[10] = handler.liquidate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _sumPrincipal() internal view returns (uint256 principal, uint256 accrued, uint256 collateral) {
        for (uint256 i; i < handler.borrowerCount(); ++i) {
            address borrower = handler.borrowers(i);
            (uint256 c, uint256 d) = vault.positions(borrower);
            collateral += c;
            accrued += d;
            principal += d - vault.feeOf(borrower);
        }
    }

    function invariant_supplyEqualsOutstandingPrincipalPlusWork() public view {
        (uint256 principal,,) = _sumPrincipal();
        assertEq(vault.totalDebt(), principal, "totalDebt is the summed principal");
        assertEq(comp.totalSupply(), vault.totalDebt() + vault.totalWorkMinted(), "supply == principal + work");
    }

    function invariant_feesAreMintedOnlyToTheRecipientAndOnlyWhenPaid() public view {
        assertEq(comp.balanceOf(FEE_RECIPIENT), vault.totalFeesMinted(), "recipient holds exactly the paid fees");
        assertGe(vault.totalFeesMinted(), handler.lastFeesMinted(), "paid fees never fall");
    }

    function invariant_collateralCustodyAndPayoutsReconcile() public view {
        (,, uint256 collateral) = _sumPrincipal();
        assertEq(imd.balanceOf(address(vault)), collateral, "vault holds exactly the summed collateral");
        assertEq(imd.balanceOf(FEE_RECIPIENT), handler.protocolIMDPaid(), "protocol received only its cuts");
        assertEq(
            handler.protocolIMDPaid() + handler.markerIMDPaid() + handler.liquidatorIMDPaid(),
            handler.totalSeized(),
            "every seized wei went to exactly one of the three parties"
        );
    }

    function invariant_badDebtAccumulatorIsTheSumOfRecords() public view {
        uint256 records;
        for (uint256 i; i < handler.borrowerCount(); ++i) {
            address borrower = handler.borrowers(i);
            uint256 recorded = vault.recordedBadDebtOf(borrower);
            records += recorded;
            assertLe(recorded, vault.debtOf(borrower), "a record never exceeds what is owed");
        }
        assertEq(vault.totalBadDebt(), records, "accumulator == summed records");
    }

    function invariant_allCompIsHeldByKnownParties() public view {
        uint256 held = comp.balanceOf(FEE_RECIPIENT);
        for (uint256 i; i < handler.borrowerCount(); ++i) {
            held += comp.balanceOf(handler.borrowers(i));
        }
        for (uint256 i; i < handler.liquidatorCount(); ++i) {
            held += comp.balanceOf(handler.liquidators(i));
        }
        for (uint256 i; i < handler.keeperCount(); ++i) {
            held += comp.balanceOf(handler.keepers(i));
        }
        assertEq(held, comp.totalSupply(), "all COMP accounted for");
    }

    function invariant_marksAlwaysCarryTheirMarkerAndClosedDebtCarriesNoFee() public view {
        for (uint256 i; i < handler.borrowerCount(); ++i) {
            address borrower = handler.borrowers(i);
            (uint256 at,, bool marked, address marker) = vault.liquidationMarks(borrower);
            if (marked) {
                assertTrue(marker != address(0), "a live mark names its keeper");
                assertLe(at, block.timestamp);
            } else {
                assertEq(marker, address(0), "a cleared mark forgets its keeper");
                assertEq(at, 0);
            }
            if (vault.debtOf(borrower) == 0) assertEq(vault.feeOf(borrower), 0, "no debt, no fee");
        }
    }

    /// @dev Every sequence ends with the spot far out of bound: every borrower still repays in full
    /// and withdraws everything, which is the liveness the guard must never take away.
    function afterInvariant() public {
        handler.setSpot(7);
        MockWorkOracle oracle = handler.oracle();
        for (uint256 i; i < handler.borrowerCount(); ++i) {
            address borrower = handler.borrowers(i);
            uint256 owed = vault.debtOf(borrower);
            if (owed != 0) {
                uint256 balance = comp.balanceOf(borrower);
                if (balance < owed) {
                    vm.prank(APPROVED_OPERATOR);
                    oracle.grantRights(borrower, owed - balance);
                    vm.prank(borrower);
                    vault.mintFromWork(owed - balance);
                }
                vm.prank(borrower);
                vault.repayCOMP(owed);
            }
            (uint256 collateral,) = vault.positions(borrower);
            if (collateral != 0) {
                vm.prank(borrower);
                vault.withdrawCollateral(collateral);
            }
            (collateral, owed) = vault.positions(borrower);
            assertEq(collateral, 0, "full exit while diverged");
            assertEq(owed, 0, "full repayment while diverged");
            assertEq(vault.recordedBadDebtOf(borrower), 0, "repayment clears the record");
        }
        assertEq(vault.totalDebt(), 0);
        assertEq(vault.totalBadDebt(), 0, "every record was repaid");
        assertEq(imd.balanceOf(address(vault)), 0, "nothing stranded in the vault");
        assertEq(comp.totalSupply(), vault.totalWorkMinted(), "only work-minted COMP remains");
    }

    function test_handlerSequenceReachesTheThreeWaySplitAndTheBadDebtCheckpoint() public {
        handler.setMarket(2, 2); // price 1, NHI .85
        handler.mintDebt(0, 100 ether); // borrower 0: 300 IMD against 200 COMP
        handler.advanceTime(1 days);
        handler.setMarket(0, 0); // price 0.5, NHI .60: CR 75 against a 200 floor
        handler.setSpot(3); // one wei beyond the bound
        handler.mark(0, 0);
        assertEq(handler.guardedRejections(), 1, "the diverged mark was rejected");
        handler.setSpot(1); // exactly at the bound
        handler.mark(0, 0);
        assertEq(handler.marks(), 1, "the in-bound mark landed");
        handler.liquidate(1, 0, 10 ether, false);
        assertEq(handler.liquidations(), 1, "three-way split verified");
        handler.liquidate(0, 0, 10 ether, true);
        assertEq(handler.combinedPayouts(), 1, "marker-as-liquidator verified");
        // 300 - 22 - 22 = 256 IMD covers 116.36 COMP of payout at 0.5; the rest is bad debt.
        handler.liquidate(1, 0, 116 ether, false);
        (uint256 collateral, uint256 debt) = vault.positions(handler.borrowers(0));
        assertEq(collateral, 800000000000000000, "0.8 IMD of dust remains");
        assertGt(debt, 0);
        assertEq(vault.totalBadDebt(), 0, "dust left: nothing recorded yet");
        handler.setSpot(7);
        handler.repay(0, 1 ether);
        assertEq(handler.divergentRepayments(), 1, "repayment while diverged");
        handler.setSpot(0);
        afterInvariant();
    }

    function test_handlerSequenceRefusesADisputedIncidentalClearAndThenClears() public {
        handler.setMarket(2, 2); // price 1, NHI .85: 300 IMD against 100 COMP, CR 300
        handler.setMarket(0, 0); // price 0.5, NHI .60: CR 150 against a 200 floor
        handler.mark(0, 0);
        assertEq(handler.marks(), 1);
        // The pushed primary that the finding used: healthy at 1 while the spot still says 0.5.
        handler.primary().setValue(1 ether);
        handler.deposit(0, 1);
        assertEq(handler.disputedClearsRefused(), 1, "a one-wei deposit cannot discard the mark");
        handler.repay(0, 1);
        assertEq(handler.disputedClearsRefused(), 2, "nor can a one-wei repayment");
        handler.setSpot(5); // stale spot with a genuine recovery at the primary
        handler.deposit(0, 1);
        assertEq(handler.disputedClearsRefused(), 3);
        assertEq(handler.incidentalClears(), 0);
        handler.setSpot(1); // exactly at the bound
        handler.deposit(0, 1);
        assertEq(handler.incidentalClears(), 1, "an agreeing spot lets the recovery clear the mark");
        (,, bool marked,) = vault.liquidationMarks(handler.borrowers(0));
        assertFalse(marked);
        afterInvariant();
    }

    function test_handlerSequenceRecordsAnExhaustingLiquidation() public {
        handler.setMarket(2, 2);
        handler.mintDebt(0, 100 ether); // 200 COMP
        handler.deposit(0, 30 ether); // 330 IMD
        handler.setMarket(0, 0); // price 0.5: 150 COMP repaid seizes exactly 330 IMD
        handler.mark(1, 0);
        assertEq(Math.mulDiv(150 ether, 1.1e18, 0.5 ether), 330 ether);
        handler.liquidate(0, 0, 150 ether, false);
        (uint256 collateral, uint256 debt) = vault.positions(handler.borrowers(0));
        assertEq(collateral, 0);
        assertEq(debt, 50 ether);
        assertEq(handler.exhaustingLiquidations(), 1);
        assertEq(vault.totalBadDebt(), 50 ether, "exactly the shortfall");
        handler.advanceTime(1 days);
        assertEq(vault.totalBadDebt(), 50 ether, "time does not move it");
        handler.deposit(0, 1);
        assertEq(vault.totalBadDebt(), 50 ether, "a dust deposit does not move it");
        afterInvariant();
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract IncrementInvariantTest is IncrementInvariantBase {
    function _rate() internal pure override returns (uint256) {
        return 1000;
    }

    function invariant_feeIsActuallyBeingCharged() public view {
        assertEq(vault.stabilityFeeBps(), 1000);
        assertEq(
            vault.debtIndex(), 1e18 + Math.mulDiv(block.timestamp - vault.deployedAt(), 1000e18, 365 days * 10_000)
        );
    }
}

/// @dev The deployment word that ships: the original supply identity over accrued debt must be exact and
/// nothing fee-related may ever move.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract IncrementZeroRateInvariantTest is IncrementInvariantBase {
    function _rate() internal pure override returns (uint256) {
        return 0;
    }

    function invariant_zeroRateKeepsTheOriginalSupplyIdentity() public view {
        (, uint256 accrued,) = _sumPrincipal();
        assertEq(comp.totalSupply(), accrued + vault.totalWorkMinted(), "supply == summed debt + work");
        assertEq(vault.totalFeesMinted(), 0, "no fee is ever minted");
        assertEq(comp.balanceOf(FEE_RECIPIENT), 0, "the recipient never receives COMP");
        assertEq(vault.debtIndex(), 1e18, "the index never moves");
        for (uint256 i; i < handler.borrowerCount(); ++i) {
            assertEq(vault.feeOf(handler.borrowers(i)), 0, "nothing accrues");
            assertEq(vault.debtIndexOf(handler.borrowers(i)), 0, "no checkpoint is written");
        }
    }
}
