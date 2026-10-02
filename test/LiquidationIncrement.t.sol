// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {APPROVED_OPERATOR, FEE_RECIPIENT} from "../src/DeploymentConfig.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";

/// @dev The production vault with the protocol bonus hook turned on, so marker, liquidator and
/// FEE_RECIPIENT can all be paid from one liquidation. Nothing else is overridden.
contract SplitVault is CDPVault {
    uint256 private immutable protocolShare;

    constructor(
        address imd,
        address primary,
        address nhi,
        address spot,
        uint256 maxDivergence,
        uint256 markerShare,
        uint256 rate,
        uint256 protocolShare_
    ) CDPVault(imd, address(0), address(0), primary, nhi, spot, maxDivergence, markerShare, rate) {
        protocolShare = protocolShare_;
    }

    function protocolBonusShareBps() public view override returns (uint256) {
        return protocolShare;
    }
}

/// @notice Divergence guard, marker split, stability fee and bad-debt accounting of the fifth increment,
/// including the exact boundaries and the zero-rate deployment that ships.
contract LiquidationIncrementTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    address internal constant KEEPER = address(0x6EE9E2);
    uint256 internal constant PAYOUT_SCALE = 1.1e18;

    MockIMD internal imd;
    TestSwarmFeed internal primary;
    TestSwarmFeed internal spot;
    TestSwarmFeed internal nhi;
    SplitVault internal vault;
    CompToken internal comp;
    MockWorkOracle internal oracle;

    function setUp() public {
        vm.warp(10 days);
        imd = new MockIMD();
        primary = new TestSwarmFeed(1 ether);
        spot = new TestSwarmFeed(1 ether);
        nhi = new TestSwarmFeed(0.85 ether);
        _deploy(500, 1000, 0, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Fixture helpers
    // ---------------------------------------------------------------------------------------------

    function _deploy(uint256 maxDivergence, uint256 markerShare, uint256 rate, uint256 protocolShare) internal {
        vault = new SplitVault(
            address(imd), address(primary), address(nhi), address(spot), maxDivergence, markerShare, rate, protocolShare
        );
        comp = vault.compToken();
        oracle = MockWorkOracle(address(vault.oracle()));
        _fund(ALICE);
        _fund(BOB);
        _fund(CAROL);
        _fund(KEEPER);
    }

    function _fund(address user) internal {
        vm.prank(APPROVED_OPERATOR);
        imd.mint(user, 1e27);
        vm.prank(user);
        imd.approve(address(vault), type(uint256).max);
    }

    function _open(address user, uint256 collateral, uint256 debt) internal {
        vm.startPrank(user);
        vault.depositCollateral(collateral);
        if (debt != 0) vault.mintCOMP(debt);
        vm.stopPrank();
    }

    function _work(address user, uint256 amount) internal {
        vm.prank(APPROVED_OPERATOR);
        oracle.grantRights(user, amount);
        vm.prank(user);
        vault.mintFromWork(amount);
    }

    function _price(uint256 price) internal {
        primary.setValue(price);
        spot.setValue(price);
    }

    function _mark(address marker, address owner) internal {
        vm.prank(marker);
        vault.markUnderwater(owner);
    }

    function _mint(address user, uint256 amount) internal {
        vm.prank(user);
        vault.mintCOMP(amount);
    }

    function _expectMintRevert(address user, uint256 amount, bytes4 selector) internal {
        vm.expectRevert(selector);
        vm.prank(user);
        vault.mintCOMP(amount);
    }

    function _assertPrincipalSupply() internal view {
        assertEq(comp.totalSupply(), vault.totalDebt() + vault.totalWorkMinted(), "supply == principal + work");
    }

    function _transfersTo(Vm.Log[] memory logs, address to) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(imd) && logs[i].topics.length == 3
                    && logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")
                    && logs[i].topics[2] == bytes32(uint256(uint160(to)))
            ) ++count;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // ONE. Divergence guard
    // ---------------------------------------------------------------------------------------------

    function test_divergenceExactlyAtBoundIsAcceptedAndOneWeiBeyondReverts() public {
        _open(ALICE, 300 ether, 100 ether);
        uint256 tolerance = Math.mulDiv(1 ether, vault.maxDivergenceBps(), 10_000);
        assertEq(tolerance, 0.05 ether);

        spot.setValue(1 ether + tolerance);
        _mint(ALICE, 1 ether);
        spot.setValue(1 ether - tolerance);
        _mint(ALICE, 1 ether);

        spot.setValue(1 ether + tolerance + 1);
        _expectMintRevert(ALICE, 1 ether, CDPVault.PriceDivergence.selector);
        spot.setValue(1 ether - tolerance - 1);
        _expectMintRevert(ALICE, 1 ether, CDPVault.PriceDivergence.selector);

        assertEq(vault.debtOf(ALICE), 102 ether, "only the in-bound mints landed");
    }

    function test_divergenceIsMeasuredAgainstThePrimaryNotTheSpot() public {
        _open(ALICE, 300 ether, 100 ether);
        // 5% below the primary is in bound; the spot whose own 5% reaches the primary is not.
        spot.setValue(0.95 ether);
        _mint(ALICE, 1);
        uint256 spotAboveByItsOwnFivePercent = uint256(1 ether) * 10_000 / 9500 + 1; // ~1.0526e18
        spot.setValue(spotAboveByItsOwnFivePercent);
        _expectMintRevert(ALICE, 1, CDPVault.PriceDivergence.selector);
    }

    function test_divergenceToleranceFloorsAtSmallPrimaryPrices() public {
        _price(101);
        _open(ALICE, 1e24, 1);
        spot.setValue(106); // floor(101 * 500 / 10000) == 5
        _mint(ALICE, 1);
        spot.setValue(107);
        _expectMintRevert(ALICE, 1, CDPVault.PriceDivergence.selector);
        spot.setValue(96);
        _mint(ALICE, 1);
        spot.setValue(95);
        _expectMintRevert(ALICE, 1, CDPVault.PriceDivergence.selector);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_divergenceBoundIsInclusiveForAnyPrimaryAndWord(uint256 price, uint256 bps) public {
        price = bound(price, 1, 1e30);
        bps = bound(bps, 0, 10_000);
        _price(price);
        _deploy(bps, 0, 0, 0);
        _open(ALICE, 1e26, 1);
        uint256 tolerance = Math.mulDiv(price, bps, 10_000);

        spot.setValue(price + tolerance);
        _mint(ALICE, 1);
        spot.setValue(price + tolerance + 1);
        _expectMintRevert(ALICE, 1, CDPVault.PriceDivergence.selector);

        if (price > tolerance) {
            spot.setValue(price - tolerance);
            _mint(ALICE, 1);
            if (price - tolerance > 1) {
                spot.setValue(price - tolerance - 1);
                _expectMintRevert(ALICE, 1, CDPVault.PriceDivergence.selector);
            }
        }
    }

    function test_divergenceGuardsMarkAndLiquidateAtTheSameBoundary() public {
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 100 ether);
        nhi.setValue(0.6 ether); // minCR 200, zero grace: ALICE is underwater at CR 150.

        spot.setValue(1.05 ether + 1);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        _mark(KEEPER, ALICE);
        (,, bool marked,) = vault.liquidationMarks(ALICE);
        assertFalse(marked, "a rejected mark records nothing");

        spot.setValue(1.05 ether);
        _mark(KEEPER, ALICE);
        (,, marked,) = vault.liquidationMarks(ALICE);
        assertTrue(marked);

        spot.setValue(0.95 ether - 1);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(BOB);
        vault.liquidate(ALICE, 10 ether);
        assertEq(vault.debtOf(ALICE), 100 ether, "a rejected liquidation changes nothing");

        spot.setValue(0.95 ether);
        vm.prank(BOB);
        vault.liquidate(ALICE, 10 ether);
        assertEq(vault.debtOf(ALICE), 90 ether);
        (uint256 collateral,) = vault.positions(ALICE);
        assertEq(collateral, 139 ether, "payout still prices off the primary, not the spot");
    }

    function test_debtBearingWithdrawalIsGuardedAtTheSameBoundaryAndDebtFreeExitIsNot() public {
        _open(ALICE, 300 ether, 100 ether);
        uint256 tolerance = Math.mulDiv(1 ether, vault.maxDivergenceBps(), 10_000);

        // Exactly at the bound in both directions the health check decides, and the remainder is healthy.
        spot.setValue(1 ether + tolerance);
        vm.prank(ALICE);
        vault.withdrawCollateral(1 ether);
        spot.setValue(1 ether - tolerance);
        vm.prank(ALICE);
        vault.withdrawCollateral(1 ether);
        (uint256 collateral,) = vault.positions(ALICE);
        assertEq(collateral, 298 ether);

        // One wei beyond, stale or zero: the guard refuses before the health check even runs.
        spot.setValue(1 ether + tolerance + 1);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(ALICE);
        vault.withdrawCollateral(1 ether);
        spot.setValue(1 ether - tolerance - 1);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(ALICE);
        vault.withdrawCollateral(1 ether);
        spot.setStale(true);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vm.prank(ALICE);
        vault.withdrawCollateral(1 ether);
        spot.setStale(false);
        spot.setValue(0);
        vm.expectRevert(CDPVault.InvalidPrice.selector);
        vm.prank(ALICE);
        vault.withdrawCollateral(1 ether);
        (collateral,) = vault.positions(ALICE);
        assertEq(collateral, 298 ether, "rejected withdrawals release nothing");

        // The attack the guard exists for: a pushed primary says 98 IMD at 2 COMP covers 100 COMP at
        // CR 196, but the spot still says 1, so no collateral leaves against the open debt.
        spot.setValue(1 ether);
        primary.setValue(2 ether);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(ALICE);
        vault.withdrawCollateral(200 ether);
        primary.setValue(1 ether);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vm.prank(ALICE);
        vault.withdrawCollateral(200 ether);
        (collateral,) = vault.positions(ALICE);
        assertEq(collateral, 298 ether);

        // Once the debt is gone the spot is irrelevant: repay while diverged, exit while stale.
        spot.setValue(100 ether);
        vm.prank(ALICE);
        vault.repayCOMP(100 ether);
        spot.setStale(true);
        vm.prank(ALICE);
        vault.withdrawCollateral(298 ether);
        (collateral,) = vault.positions(ALICE);
        assertEq(collateral, 0, "debt-free exit ignores the spot entirely");
    }

    function test_clearRecoveredMarkRefusesADisputedPriceAndKeepsTheMark() public {
        _open(ALICE, 150 ether, 100 ether);
        _price(0.9 ether); // CR 135 < 150: underwater at an honest price
        _mark(KEEPER, ALICE);
        (uint256 markedAt, uint256 grace, bool marked, address marker) = vault.liquidationMarks(ALICE);
        assertTrue(marked);
        uint256 tolerance = Math.mulDiv(0.9 ether, vault.maxDivergenceBps(), 10_000);

        // A pushed primary alone would make ALICE healthy (CR 150) but the spot disagrees.
        primary.setValue(1 ether);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(KEEPER);
        vault.clearRecoveredMark(ALICE);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(ALICE);
        vault.clearRecoveredMark(ALICE);
        primary.setValue(0.9 ether);

        // Stale and zero spot are refused the same way, whatever the primary says.
        spot.setStale(true);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vm.prank(KEEPER);
        vault.clearRecoveredMark(ALICE);
        spot.setStale(false);
        spot.setValue(0);
        vm.expectRevert(CDPVault.InvalidPrice.selector);
        vm.prank(KEEPER);
        vault.clearRecoveredMark(ALICE);

        // Exactly at the bound the guard passes and the health check, at the primary, still says underwater.
        spot.setValue(0.9 ether + tolerance);
        vm.expectRevert(CDPVault.UnderwaterPosition.selector);
        vm.prank(KEEPER);
        vault.clearRecoveredMark(ALICE);
        spot.setValue(0.9 ether + tolerance + 1);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(KEEPER);
        vault.clearRecoveredMark(ALICE);

        (uint256 stillAt, uint256 stillGrace, bool stillMarked, address stillMarker) = vault.liquidationMarks(ALICE);
        assertTrue(stillMarked, "every rejected clear leaves the mark live");
        assertEq(stillAt, markedAt);
        assertEq(stillGrace, grace);
        assertEq(stillMarker, marker, "the marker keeps its claim on the bonus");

        // An honest recovery, both feeds agreeing, clears it.
        _price(1 ether);
        vm.prank(KEEPER);
        vault.clearRecoveredMark(ALICE);
        (,, marked, marker) = vault.liquidationMarks(ALICE);
        assertFalse(marked);
        assertEq(marker, address(0));
    }

    function test_depositAgainstADisputedPrimaryKeepsTheMarkAndItsMarker() public {
        _open(ALICE, 150 ether, 100 ether);
        _price(0.9 ether); // CR 135 < 150: underwater at an honest price
        _mark(KEEPER, ALICE);
        (uint256 markedAt, uint256 grace,, address marker) = vault.liquidationMarks(ALICE);
        uint256 tolerance = Math.mulDiv(0.9 ether, vault.maxDivergenceBps(), 10_000);

        // The finding this guards against: a pushed primary says CR 150 and a one-wei deposit would have
        // discarded the live mark. The deposit lands; the mark, its grace snapshot and its marker do not move.
        primary.setValue(1 ether);
        vm.prank(ALICE);
        vault.depositCollateral(1);
        (uint256 collateral,) = vault.positions(ALICE);
        assertEq(collateral, 150 ether + 1, "the deposit itself succeeds");
        _assertMarkUnchanged(markedAt, grace, marker, "pushed primary");
        primary.setValue(0.9 ether);

        // A genuine recovery at the primary is still not cleared while the spot is stale or zero.
        spot.setStale(true);
        vm.prank(ALICE);
        vault.depositCollateral(100 ether); // 250 IMD at 0.9 against 100 COMP: CR 225
        assertGe(vault.collateralRatio(ALICE), vault.minCR(), "healthy at the primary");
        _assertMarkUnchanged(markedAt, grace, marker, "stale spot");
        spot.setStale(false);
        spot.setValue(0);
        vm.prank(ALICE);
        vault.depositCollateral(1);
        _assertMarkUnchanged(markedAt, grace, marker, "zero spot");

        // One wei beyond the bound keeps it; exactly at the bound the same deposit clears it.
        spot.setValue(0.9 ether + tolerance + 1);
        vm.prank(ALICE);
        vault.depositCollateral(1);
        _assertMarkUnchanged(markedAt, grace, marker, "one wei beyond");
        spot.setValue(0.9 ether - tolerance - 1);
        vm.prank(ALICE);
        vault.depositCollateral(1);
        _assertMarkUnchanged(markedAt, grace, marker, "one wei beyond, below");
        spot.setValue(0.9 ether + tolerance);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CDPVault.UnderwaterMarkCleared(ALICE);
        vm.prank(ALICE);
        vault.depositCollateral(1);
        (,, bool marked, address cleared) = vault.liquidationMarks(ALICE);
        assertFalse(marked, "an agreeing spot lets the recovery clear the mark");
        assertEq(cleared, address(0));
    }

    function test_repaymentAgainstADisputedPrimaryKeepsADebtBearingMarkAndADebtFreeOneClears() public {
        _open(ALICE, 150 ether, 100 ether);
        _price(0.9 ether);
        _mark(KEEPER, ALICE);
        (uint256 markedAt, uint256 grace,, address marker) = vault.liquidationMarks(ALICE);
        uint256 tolerance = Math.mulDiv(0.9 ether, vault.maxDivergenceBps(), 10_000);

        // Repayment is never gated, but a stale spot stops the recovery it causes from discarding the mark.
        spot.setStale(true);
        vm.prank(ALICE);
        vault.repayCOMP(50 ether); // 150 IMD at 0.9 against 50 COMP: CR 270
        assertEq(vault.debtOf(ALICE), 50 ether, "the repayment itself succeeds");
        assertGe(vault.collateralRatio(ALICE), vault.minCR(), "healthy at the primary");
        _assertMarkUnchanged(markedAt, grace, marker, "stale spot");
        spot.setStale(false);
        spot.setValue(0);
        vm.prank(ALICE);
        vault.repayCOMP(1);
        _assertMarkUnchanged(markedAt, grace, marker, "zero spot");
        primary.setValue(1 ether);
        vm.prank(ALICE);
        vault.repayCOMP(1);
        _assertMarkUnchanged(markedAt, grace, marker, "pushed primary");
        primary.setValue(0.9 ether);
        spot.setValue(0.9 ether - tolerance - 1);
        vm.prank(ALICE);
        vault.repayCOMP(1);
        _assertMarkUnchanged(markedAt, grace, marker, "one wei beyond");
        spot.setValue(0.9 ether - tolerance);
        vm.prank(ALICE);
        vault.repayCOMP(1);
        (,, bool marked,) = vault.liquidationMarks(ALICE);
        assertFalse(marked, "exactly at the bound the repayment clears the mark");
        assertEq(vault.debtOf(ALICE), 50 ether - 4);

        // A repayment that closes the debt clears the mark whatever the spot says: nothing is left to liquidate.
        _price(0.3 ether); // 150 IMD at 0.3 against ~50 COMP: CR 90 < 150
        _mark(CAROL, ALICE);
        (,, marked, marker) = vault.liquidationMarks(ALICE);
        assertTrue(marked);
        assertEq(marker, CAROL);
        spot.setStale(true);
        uint256 owed = vault.debtOf(ALICE);
        vm.prank(ALICE);
        vault.repayCOMP(owed);
        (,, marked, marker) = vault.liquidationMarks(ALICE);
        assertFalse(marked, "debt-free positions clear unconditionally");
        assertEq(marker, address(0));
        assertEq(vault.debtOf(ALICE), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_incidentalClearUsesTheSameInclusiveBoundAsTheGuard(uint256 price, uint256 bps) public {
        price = bound(price, 4, 1e30);
        bps = bound(bps, 0, 10_000);
        _deploy(bps, 0, 0, 0);
        _price(price);
        _open(ALICE, 1e26, Math.mulDiv(1e26, price, 4e18)); // CR about 400 at the opening price
        nhi.setValue(0.6 ether); // minCR 200
        _price(price / 4); // CR about 100: underwater
        _mark(KEEPER, ALICE);
        (uint256 markedAt, uint256 grace,, address marker) = vault.liquidationMarks(ALICE);
        uint256 primaryPrice = price / 4;
        uint256 tolerance = Math.mulDiv(primaryPrice, bps, 10_000);

        // Recover at the primary with a deposit while the spot sits one wei outside the bound: kept.
        spot.setValue(primaryPrice + tolerance + 1);
        vm.prank(ALICE);
        vault.depositCollateral(3e26); // CR about 400 again
        assertGe(vault.collateralRatio(ALICE), vault.minCR(), "healthy at the primary");
        _assertMarkUnchanged(markedAt, grace, marker, "beyond the bound");

        // The same recovery with the spot exactly at the bound: cleared.
        spot.setValue(primaryPrice + tolerance);
        vm.prank(ALICE);
        vault.depositCollateral(1);
        (,, bool marked,) = vault.liquidationMarks(ALICE);
        assertFalse(marked, "at the bound");
    }

    function _assertMarkUnchanged(uint256 markedAt, uint256 grace, address marker, string memory why) internal view {
        (uint256 at, uint256 g, bool marked, address m) = vault.liquidationMarks(ALICE);
        assertTrue(marked, string.concat("mark kept: ", why));
        assertEq(at, markedAt, string.concat("timestamp kept: ", why));
        assertEq(g, grace, string.concat("grace snapshot kept: ", why));
        assertEq(m, marker, string.concat("marker kept: ", why));
    }

    function test_staleOrZeroSpotBlocksGuardedActionsOnly() public {
        _open(ALICE, 300 ether, 100 ether);
        _work(BOB, 100 ether);

        spot.setStale(true);
        _expectMintRevert(ALICE, 1, CDPVault.StaleFeed.selector);
        spot.setStale(false);
        spot.setValue(0);
        _expectMintRevert(ALICE, 1, CDPVault.InvalidPrice.selector);

        // Push ALICE underwater on the primary alone; mark and liquidate must still refuse.
        primary.setValue(0.4 ether);
        vm.expectRevert(CDPVault.InvalidPrice.selector);
        _mark(KEEPER, ALICE);
        spot.setStale(true);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        _mark(KEEPER, ALICE);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vm.prank(BOB);
        vault.liquidate(ALICE, 1 ether);

        // Work minting is not price-dependent and ignores the spot entirely.
        _work(BOB, 1 ether);

        // The borrower can always get out.
        vm.prank(ALICE);
        vault.repayCOMP(100 ether);
        vm.prank(ALICE);
        vault.withdrawCollateral(300 ether);
        (uint256 collateral, uint256 debt) = vault.positions(ALICE);
        assertEq(collateral, 0);
        assertEq(debt, 0);
    }

    function test_primaryStalenessStillWinsOverAnAgreeingSpot() public {
        _open(ALICE, 300 ether, 100 ether);
        primary.setStale(true);
        _expectMintRevert(ALICE, 1, CDPVault.StaleFeed.selector);
        primary.setStale(false);
        nhi.setStale(true);
        _expectMintRevert(ALICE, 1, CDPVault.StaleFeed.selector);
    }

    function test_repaymentAndDebtFreeWithdrawalSucceedBeyondTheBound() public {
        _deploy(500, 1000, 1000, 2000);
        _open(ALICE, 300 ether, 100 ether);
        uint256 aliceBefore = imd.balanceOf(ALICE);
        _work(ALICE, 50 ether);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.debtOf(ALICE), 110 ether);

        spot.setValue(100 ether); // a hundred times the primary
        _expectMintRevert(ALICE, 1, CDPVault.PriceDivergence.selector);

        vm.prank(ALICE);
        vault.repayCOMP(60 ether); // fee first, then principal, while diverged
        assertEq(vault.debtOf(ALICE), 50 ether);
        assertEq(vault.feeOf(ALICE), 0);
        assertEq(vault.totalFeesMinted(), 10 ether);
        assertEq(comp.balanceOf(FEE_RECIPIENT), 10 ether);

        spot.setValue(1); // one wei spot
        vm.prank(ALICE);
        vault.repayCOMP(50 ether);
        assertEq(vault.debtOf(ALICE), 0);

        spot.setStale(true);
        vm.prank(ALICE);
        vault.withdrawCollateral(300 ether);
        (uint256 collateral, uint256 debt) = vault.positions(ALICE);
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(imd.balanceOf(ALICE), aliceBefore + 300 ether);
        _assertPrincipalSupply();
    }

    function test_repaymentOfRecordedBadDebtSucceedsWhileFeedsDiverge() public {
        _open(ALICE, 220 ether, 100 ether);
        _work(BOB, 100 ether);
        _work(ALICE, 100 ether);
        _price(0.25 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        vm.prank(BOB);
        vault.liquidate(ALICE, 50 ether);
        assertEq(vault.totalBadDebt(), 50 ether);

        spot.setValue(0);
        primary.setStale(true);
        vm.prank(ALICE);
        vault.repayCOMP(50 ether);
        assertEq(vault.totalBadDebt(), 0, "repayment under any feed state clears the record");
        assertEq(vault.debtOf(ALICE), 0);
    }

    function test_zeroDivergenceWordRequiresExactAgreement() public {
        _deploy(0, 0, 0, 0);
        _open(ALICE, 300 ether, 100 ether);
        spot.setValue(1 ether + 1);
        _expectMintRevert(ALICE, 1, CDPVault.PriceDivergence.selector);
        spot.setValue(1 ether - 1);
        _expectMintRevert(ALICE, 1, CDPVault.PriceDivergence.selector);
        spot.setValue(1 ether);
        _mint(ALICE, 1);
    }

    function test_fullDivergenceWordAllowsUpToDoubleThePrimary() public {
        _deploy(10_000, 0, 0, 0);
        _open(ALICE, 300 ether, 100 ether);
        spot.setValue(2 ether);
        _mint(ALICE, 1);
        spot.setValue(2 ether + 1);
        _expectMintRevert(ALICE, 1, CDPVault.PriceDivergence.selector);
        spot.setValue(1);
        _mint(ALICE, 1);
        spot.setValue(0);
        _expectMintRevert(ALICE, 1, CDPVault.InvalidPrice.selector);
    }

    /// @dev The bound is one number shared by every price-dependent entry point. For random primary
    /// prices and words, mint, mark, liquidate, clearRecoveredMark and a debt-bearing withdrawal all
    /// accept a spot exactly at the bound and all refuse one wei beyond it, while repayment, deposit
    /// and work minting proceed regardless.
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_everyGuardedEntryPointSharesTheInclusiveBound(uint256 price, uint256 bps) public {
        price = bound(price, 4e12, 1e24);
        bps = bound(bps, 0, 10_000);
        _price(price);
        _deploy(bps, 1000, 0, 0);
        uint256 debt = Math.mulDiv(1e24, price, 4e18); // CR 400 against 1e24 IMD at the opening price
        _open(ALICE, 1e24, debt);
        _open(BOB, 1e25, debt); // CR 4000
        _work(CAROL, debt);
        nhi.setValue(0.6 ether); // minCR 200, zero grace
        uint256 primaryPrice = price / 4;
        _price(primaryPrice); // ALICE at CR 100 is underwater; BOB at CR 1000 stays healthy
        uint256 tolerance = Math.mulDiv(primaryPrice, bps, 10_000);

        _assertGuardedActionsAccept(primaryPrice + tolerance);
        _assertGuardedActionsRefuse(primaryPrice + tolerance + 1);
        if (primaryPrice > tolerance) {
            _assertGuardedActionsAccept(primaryPrice - tolerance);
            if (primaryPrice - tolerance > 1) _assertGuardedActionsRefuse(primaryPrice - tolerance - 1);
        }
    }

    function _assertGuardedActionsAccept(uint256 spotPrice) internal {
        spot.setValue(spotPrice);
        _mark(KEEPER, ALICE);
        (,, bool marked,) = vault.liquidationMarks(ALICE);
        assertTrue(marked, "mark accepted at the bound");
        uint256 owed = vault.debtOf(ALICE);
        vm.prank(CAROL);
        vault.liquidate(ALICE, 1);
        assertEq(vault.debtOf(ALICE), owed - 1, "liquidation accepted at the bound");
        (uint256 collateral, uint256 debt) = vault.positions(BOB);
        vm.prank(BOB);
        vault.mintCOMP(1);
        vm.prank(BOB);
        vault.withdrawCollateral(1);
        vm.prank(KEEPER);
        vault.clearRecoveredMark(BOB);
        (uint256 collateralAfter, uint256 debtAfter) = vault.positions(BOB);
        assertEq(debtAfter, debt + 1, "mint accepted at the bound");
        assertEq(collateralAfter, collateral - 1, "debt-bearing withdrawal accepted at the bound");
    }

    function _assertGuardedActionsRefuse(uint256 spotPrice) internal {
        spot.setValue(spotPrice);
        (uint256 aliceCollateral, uint256 aliceDebt) = vault.positions(ALICE);
        (uint256 bobCollateral, uint256 bobDebt) = vault.positions(BOB);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        _mark(KEEPER, ALICE);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(CAROL);
        vault.liquidate(ALICE, 1);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(BOB);
        vault.mintCOMP(1);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(BOB);
        vault.withdrawCollateral(1);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(KEEPER);
        vault.clearRecoveredMark(BOB);
        (uint256 collateral, uint256 debt) = vault.positions(ALICE);
        assertEq(collateral, aliceCollateral, "refused liquidation seizes nothing");
        assertEq(debt, aliceDebt, "refused liquidation repays nothing");
        (collateral, debt) = vault.positions(BOB);
        assertEq(collateral, bobCollateral, "refused withdrawal releases nothing");
        assertEq(debt, bobDebt, "refused mint issues nothing");

        // The borrower's way out and the price-independent channels never consult the spot.
        vm.prank(ALICE);
        vault.repayCOMP(1);
        vm.prank(BOB);
        vault.depositCollateral(1);
        _work(CAROL, 1);
        (collateral, debt) = vault.positions(ALICE);
        assertEq(debt, aliceDebt - 1, "repayment proceeds beyond the bound");
        (collateral,) = vault.positions(BOB);
        assertEq(collateral, bobCollateral + 1, "deposit proceeds beyond the bound");
    }

    function test_constructorBoundsEveryWordAndValidatesTheSpotFeed() public {
        address p = address(primary);
        address n = address(nhi);
        address s = address(spot);
        address i = address(imd);
        vm.expectRevert(CDPVault.InvalidBasisPoints.selector);
        new CDPVault(i, address(0), address(0), p, n, s, 10_001, 0, 0);
        vm.expectRevert(CDPVault.InvalidBasisPoints.selector);
        new CDPVault(i, address(0), address(0), p, n, s, 0, 10_001, 0);
        vm.expectRevert(CDPVault.InvalidBasisPoints.selector);
        new CDPVault(i, address(0), address(0), p, n, s, 0, 0, 10_001);
        vm.expectRevert(CDPVault.InvalidFeed.selector);
        new CDPVault(i, address(0), address(0), p, n, address(0), 500, 0, 0);
        vm.expectRevert(CDPVault.InvalidFeed.selector);
        new CDPVault(i, address(0), address(0), p, n, address(0xDEAD), 500, 0, 0);
        vm.expectRevert(CDPVault.InvalidFeed.selector);
        new CDPVault(i, address(0), address(0), p, n, n, 500, 0, 0);

        CDPVault edge = new CDPVault(i, address(0), address(0), p, n, s, 10_000, 10_000, 10_000);
        assertEq(edge.maxDivergenceBps(), 10_000);
        assertEq(edge.markerShareBps(), 10_000);
        assertEq(edge.stabilityFeeBps(), 10_000);
        assertEq(edge.deployedAt(), block.timestamp);
        assertEq(address(edge.spotFeed()), s);
    }

    // ---------------------------------------------------------------------------------------------
    // TWO. Marker split
    // ---------------------------------------------------------------------------------------------

    function test_markerLiquidatorAndProtocolEachReceiveExactlyTheirShare() public {
        _deploy(500, 1000, 0, 2000);
        assertTrue(KEEPER != BOB && BOB != FEE_RECIPIENT && KEEPER != FEE_RECIPIENT, "three distinct parties");
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 100 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);

        uint256 keeperBefore = imd.balanceOf(KEEPER);
        uint256 bobBefore = imd.balanceOf(BOB);
        uint256 protocolBefore = imd.balanceOf(FEE_RECIPIENT);
        uint256 vaultBefore = imd.balanceOf(address(vault));

        vm.prank(BOB);
        vault.liquidate(ALICE, 10 ether);

        // seized 11, principal 10, bonus 1: marker 10% = 0.1, protocol 20% = 0.2, liquidator the rest.
        assertEq(imd.balanceOf(KEEPER) - keeperBefore, 0.1 ether, "marker share");
        assertEq(imd.balanceOf(FEE_RECIPIENT) - protocolBefore, 0.2 ether, "protocol share");
        assertEq(imd.balanceOf(BOB) - bobBefore, 10.7 ether, "liquidator remainder");
        assertEq(vaultBefore - imd.balanceOf(address(vault)), 11 ether, "exactly seized leaves the vault");
        (uint256 collateral, uint256 debt) = vault.positions(ALICE);
        assertEq(collateral, 139 ether);
        assertEq(debt, 90 ether);
        assertEq(comp.balanceOf(BOB), 90 ether);
        _assertPrincipalSupply();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_threeWaySplitIsExactAndConservesSeizedCollateral(
        uint256 markerShare,
        uint256 protocolShare,
        uint256 price,
        uint256 debtToRepay
    ) public {
        markerShare = bound(markerShare, 0, 10_000);
        protocolShare = bound(protocolShare, 0, 10_000 - markerShare);
        price = bound(price, 0.8 ether, 1.3 ether);
        debtToRepay = bound(debtToRepay, 1, 100 ether);
        _deploy(500, markerShare, 0, protocolShare);
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 100 ether);
        _price(price);
        nhi.setValue(0.6 ether); // minCR 200; CR is at most 195 across the price range.
        _mark(KEEPER, ALICE);

        uint256 seized = Math.mulDiv(debtToRepay, PAYOUT_SCALE, price);
        uint256 principal = Math.mulDiv(debtToRepay, 1e18, price);
        uint256 bonus = seized - principal;
        uint256 markerCut = Math.mulDiv(bonus, markerShare, 10_000);
        uint256 protocolCut = Math.mulDiv(bonus, protocolShare, 10_000);

        uint256 keeperBefore = imd.balanceOf(KEEPER);
        uint256 bobBefore = imd.balanceOf(BOB);
        uint256 protocolBefore = imd.balanceOf(FEE_RECIPIENT);
        vm.prank(BOB);
        vault.liquidate(ALICE, debtToRepay);

        assertEq(imd.balanceOf(KEEPER) - keeperBefore, markerCut, "marker");
        assertEq(imd.balanceOf(FEE_RECIPIENT) - protocolBefore, protocolCut, "protocol");
        assertEq(imd.balanceOf(BOB) - bobBefore, seized - markerCut - protocolCut, "liquidator");
        assertGe(imd.balanceOf(BOB) - bobBefore, principal, "liquidator is never short of the principal");
        (uint256 collateral, uint256 debt) = vault.positions(ALICE);
        assertEq(collateral, 150 ether - seized, "borrower loses exactly the seized amount");
        assertEq(debt, 100 ether - debtToRepay);
    }

    function test_markerWhoLiquidatesReceivesOneCombinedTransfer() public {
        _deploy(500, 1000, 0, 2000);
        _open(ALICE, 150 ether, 100 ether);
        _work(KEEPER, 10 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);

        uint256 before = imd.balanceOf(KEEPER);
        uint256 protocolBefore = imd.balanceOf(FEE_RECIPIENT);
        vm.recordLogs();
        vm.prank(KEEPER);
        vault.liquidate(ALICE, 10 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_transfersTo(logs, KEEPER), 1, "one transfer for marker plus liquidator");
        assertEq(imd.balanceOf(KEEPER) - before, 10.8 ether, "seized minus the protocol cut");
        assertEq(imd.balanceOf(FEE_RECIPIENT) - protocolBefore, 0.2 ether);
    }

    /// @dev The three roles are addresses, not slots: when the protocol recipient is also the marker
    /// or the liquidator it must receive exactly the sum of the shares it plays, and the sum of all
    /// three deltas must still be exactly the seized amount. A share paid twice or dropped when two
    /// roles coincide would show up here and nowhere else.
    function test_sharesConserveSeizedWhenTheRecipientIsAlsoMarkerOrLiquidator() public {
        // The recipient liquidates a position a separate keeper marked: liquidator remainder plus protocol cut.
        _deploy(500, 1000, 0, 2000);
        _fund(FEE_RECIPIENT);
        _open(ALICE, 150 ether, 100 ether);
        _work(FEE_RECIPIENT, 100 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        uint256 recipientBefore = imd.balanceOf(FEE_RECIPIENT);
        uint256 keeperBefore = imd.balanceOf(KEEPER);
        vm.prank(FEE_RECIPIENT);
        vault.liquidate(ALICE, 10 ether);
        assertEq(imd.balanceOf(KEEPER) - keeperBefore, 0.1 ether, "the separate marker keeps its share");
        assertEq(imd.balanceOf(FEE_RECIPIENT) - recipientBefore, 10.9 ether, "liquidator 10.7 plus protocol 0.2");

        // The recipient marks and a separate liquidator liquidates: marker cut plus protocol cut.
        nhi.setValue(0.85 ether);
        _deploy(500, 1000, 0, 2000);
        _fund(FEE_RECIPIENT);
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 100 ether);
        nhi.setValue(0.6 ether);
        _mark(FEE_RECIPIENT, ALICE);
        recipientBefore = imd.balanceOf(FEE_RECIPIENT);
        uint256 bobBefore = imd.balanceOf(BOB);
        vm.prank(BOB);
        vault.liquidate(ALICE, 10 ether);
        assertEq(imd.balanceOf(BOB) - bobBefore, 10.7 ether, "the liquidator is unaffected by who marked");
        assertEq(imd.balanceOf(FEE_RECIPIENT) - recipientBefore, 0.3 ether, "marker 0.1 plus protocol 0.2");

        // The recipient plays all three roles: the combined transfer plus the protocol cut equals seized.
        nhi.setValue(0.85 ether);
        _deploy(500, 1000, 0, 2000);
        _fund(FEE_RECIPIENT);
        _open(ALICE, 150 ether, 100 ether);
        _work(FEE_RECIPIENT, 100 ether);
        nhi.setValue(0.6 ether);
        _mark(FEE_RECIPIENT, ALICE);
        recipientBefore = imd.balanceOf(FEE_RECIPIENT);
        uint256 vaultBefore = imd.balanceOf(address(vault));
        vm.prank(FEE_RECIPIENT);
        vault.liquidate(ALICE, 10 ether);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - recipientBefore, 11 ether, "every share lands on the one address");
        assertEq(vaultBefore - imd.balanceOf(address(vault)), 11 ether, "and nothing more than seized leaves");
        (uint256 collateral, uint256 debt) = vault.positions(ALICE);
        assertEq(collateral, 139 ether, "the borrower loses exactly seized in every configuration");
        assertEq(debt, 90 ether);
    }

    function test_borrowerLossIsIdenticalWithAndWithoutShares() public {
        _deploy(500, 1000, 0, 2000);
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 100 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        vm.prank(BOB);
        vault.liquidate(ALICE, 37 ether);
        (uint256 collateralWithShares, uint256 debtWithShares) = vault.positions(ALICE);

        nhi.setValue(0.85 ether);
        _deploy(500, 0, 0, 0);
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 100 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        uint256 keeperBefore = imd.balanceOf(KEEPER);
        uint256 protocolBefore = imd.balanceOf(FEE_RECIPIENT);
        vm.prank(BOB);
        vault.liquidate(ALICE, 37 ether);
        (uint256 collateralNoShares, uint256 debtNoShares) = vault.positions(ALICE);

        assertEq(collateralWithShares, collateralNoShares, "collateral loss");
        assertEq(debtWithShares, debtNoShares, "debt reduction");
        assertEq(imd.balanceOf(KEEPER), keeperBefore, "zero marker share pays nothing");
        assertEq(imd.balanceOf(FEE_RECIPIENT), protocolBefore, "zero protocol share pays nothing");
    }

    function test_defaultProtocolShareLeavesMarkerAndLiquidatorOnly() public {
        // The production hook returns zero; only the marker word moves value away from the liquidator.
        CDPVault plain = new CDPVault(
            address(imd), address(0), address(0), address(primary), address(nhi), address(spot), 500, 1000, 0
        );
        MockWorkOracle plainOracle = MockWorkOracle(address(plain.oracle()));
        vm.startPrank(ALICE);
        imd.approve(address(plain), type(uint256).max);
        plain.depositCollateral(150 ether);
        plain.mintCOMP(100 ether);
        vm.stopPrank();
        vm.prank(APPROVED_OPERATOR);
        plainOracle.grantRights(BOB, 100 ether);
        vm.prank(BOB);
        plain.mintFromWork(100 ether);
        nhi.setValue(0.6 ether);
        vm.prank(KEEPER);
        plain.markUnderwater(ALICE);

        uint256 protocolBefore = imd.balanceOf(FEE_RECIPIENT);
        uint256 keeperBefore = imd.balanceOf(KEEPER);
        uint256 bobBefore = imd.balanceOf(BOB);
        vm.prank(BOB);
        plain.liquidate(ALICE, 10 ether);
        assertEq(imd.balanceOf(FEE_RECIPIENT), protocolBefore);
        assertEq(imd.balanceOf(KEEPER) - keeperBefore, 0.1 ether);
        assertEq(imd.balanceOf(BOB) - bobBefore, 10.9 ether);
    }

    function test_sharesSummingAboveTenThousandRevertAndExactlyTenThousandPayPrincipalOnly() public {
        _deploy(500, 6000, 0, 4001);
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 100 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        vm.expectRevert(CDPVault.InvalidBasisPoints.selector);
        vm.prank(BOB);
        vault.liquidate(ALICE, 10 ether);
        (uint256 collateral, uint256 debt) = vault.positions(ALICE);
        assertEq(collateral, 150 ether);
        assertEq(debt, 100 ether);

        nhi.setValue(0.85 ether);
        _deploy(500, 6000, 0, 4000);
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 100 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        uint256 bobBefore = imd.balanceOf(BOB);
        uint256 keeperBefore = imd.balanceOf(KEEPER);
        uint256 protocolBefore = imd.balanceOf(FEE_RECIPIENT);
        vm.prank(BOB);
        vault.liquidate(ALICE, 10 ether);
        assertEq(imd.balanceOf(BOB) - bobBefore, 10 ether, "liquidator keeps exactly the principal");
        assertEq(imd.balanceOf(KEEPER) - keeperBefore, 0.6 ether);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - protocolBefore, 0.4 ether);
    }

    function test_zeroBonusPaysNoMarkerShareAndSkipsTheTransfer() public {
        _deploy(500, 1000, 0, 2000);
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 100 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        uint256 keeperBefore = imd.balanceOf(KEEPER);
        uint256 bobBefore = imd.balanceOf(BOB);
        vm.recordLogs();
        vm.prank(BOB);
        vault.liquidate(ALICE, 1); // seized 1 wei, principal 1 wei, bonus 0
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_transfersTo(logs, KEEPER), 0, "no zero-value marker transfer");
        assertEq(_transfersTo(logs, FEE_RECIPIENT), 0, "no zero-value protocol transfer");
        assertEq(imd.balanceOf(KEEPER), keeperBefore);
        assertEq(imd.balanceOf(BOB) - bobBefore, 1);
    }

    function test_markRecordsItsMarkerAndKeepsItUntilExpiryOrRecovery() public {
        _open(ALICE, 150 ether, 100 ether);
        _price(0.9 ether); // CR 135 < 150, grace six hours
        _mark(KEEPER, ALICE);
        (uint256 markedAt, uint256 grace, bool marked, address marker) = vault.liquidationMarks(ALICE);
        assertTrue(marked);
        assertEq(marker, KEEPER);
        assertEq(grace, 6 hours);

        vm.warp(block.timestamp + 1 hours);
        _mark(CAROL, ALICE);
        (uint256 againAt, uint256 againGrace,, address againMarker) = vault.liquidationMarks(ALICE);
        assertEq(againAt, markedAt, "an active mark keeps its timestamp");
        assertEq(againGrace, grace, "an active mark keeps its grace");
        assertEq(againMarker, KEEPER, "an active mark keeps its marker");

        vm.warp(markedAt + grace + vault.liquidationWindow() + 1);
        _mark(CAROL, ALICE);
        (uint256 thirdAt,,, address thirdMarker) = vault.liquidationMarks(ALICE);
        assertEq(thirdAt, block.timestamp, "an expired mark is retaken");
        assertEq(thirdMarker, CAROL, "the new marker owns the retaken mark");

        vm.prank(ALICE);
        vault.depositCollateral(100 ether); // recovers to CR 225
        (,, marked, marker) = vault.liquidationMarks(ALICE);
        assertFalse(marked);
        assertEq(marker, address(0), "recovery clears the marker with the mark");
    }

    function test_expiredMarkPaysNobodyAndRetakenMarkPaysTheNewMarker() public {
        _deploy(500, 1000, 0, 0);
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 100 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        (uint256 markedAt, uint256 grace,,) = vault.liquidationMarks(ALICE);
        vm.warp(markedAt + grace + vault.liquidationWindow() + 1);
        vm.expectRevert(CDPVault.MarkExpired.selector);
        vm.prank(BOB);
        vault.liquidate(ALICE, 10 ether);

        _mark(CAROL, ALICE);
        uint256 keeperBefore = imd.balanceOf(KEEPER);
        uint256 carolBefore = imd.balanceOf(CAROL);
        vm.prank(BOB);
        vault.liquidate(ALICE, 10 ether);
        assertEq(imd.balanceOf(KEEPER), keeperBefore, "the expired marker earns nothing");
        assertEq(imd.balanceOf(CAROL) - carolBefore, 0.1 ether, "the retaking marker is paid");
    }

    // ---------------------------------------------------------------------------------------------
    // THREE. Stability fee
    // ---------------------------------------------------------------------------------------------

    function test_accruedDebtMatchesTheLinearRateExactly() public {
        _deploy(500, 0, 1000, 0);
        _open(ALICE, 1000 ether, 100 ether);
        uint256 start = block.timestamp;
        assertEq(vault.debtIndexOf(ALICE), vault.debtIndex(), "checkpointed at borrow");

        vm.warp(start + 73 days); // one fifth of a year at 10% is 2%
        assertEq(vault.feeOf(ALICE), 2 ether);
        assertEq(vault.debtOf(ALICE), 102 ether);

        vm.warp(start + 365 days);
        assertEq(vault.feeOf(ALICE), 10 ether);
        assertEq(vault.debtOf(ALICE), 110 ether);
        (, uint256 debt) = vault.positions(ALICE);
        assertEq(debt, 110 ether, "the public position view includes the fee");

        vm.warp(start + 3 * 365 days);
        assertEq(vault.debtOf(ALICE), 130 ether, "linear, never compounding");
        assertEq(vault.totalDebt(), 100 ether, "principal is unchanged until paid");
        assertEq(comp.totalSupply(), 100 ether, "nothing is minted until the fee is paid");
        assertEq(vault.totalFeesMinted(), 0);
    }

    function test_positionThatNeverChangesStillAccrues() public {
        _deploy(500, 0, 1000, 0);
        _open(ALICE, 1000 ether, 100 ether);
        uint256 lastDebt = vault.debtOf(ALICE);
        uint256 lastRatio = vault.collateralRatio(ALICE);
        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + 30 days);
            uint256 debt = vault.debtOf(ALICE);
            uint256 ratio = vault.collateralRatio(ALICE);
            assertGt(debt, lastDebt, "debt grows with no transaction");
            assertLt(ratio, lastRatio, "health worsens with no transaction");
            lastDebt = debt;
            lastRatio = ratio;
        }
        assertEq(vault.debtIndexOf(ALICE), 1e18, "no call touched the checkpoint");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_accrualMatchesTheIndexFormulaAndTheLinearRate(
        uint256 rate,
        uint256 principal,
        uint256 delay,
        uint256 elapsed
    ) public {
        rate = bound(rate, 1, 10_000);
        principal = bound(principal, 1, 1e24);
        delay = bound(delay, 0, 365 days);
        elapsed = bound(elapsed, 0, 10 * 365 days);
        _deploy(500, 0, rate, 0);
        vm.warp(block.timestamp + delay);
        _open(ALICE, 1e26, principal);
        uint256 indexAtBorrow = vault.debtIndexOf(ALICE);
        assertEq(indexAtBorrow, vault.debtIndex());
        assertEq(indexAtBorrow, 1e18 + Math.mulDiv(delay, rate * 1e18, 365 days * 10_000));

        vm.warp(block.timestamp + elapsed);
        uint256 expectedFee = Math.mulDiv(principal, vault.debtIndex() - indexAtBorrow, 1e18);
        assertEq(vault.feeOf(ALICE), expectedFee, "index formula");
        assertEq(vault.debtOf(ALICE), principal + expectedFee);
        // The global index is floored once per read, so the elapsed-time delta between two reads can
        // differ from floor(elapsed * rate) by at most one index unit: 1e-18 of the principal.
        uint256 linear = Math.mulDiv(principal * elapsed, rate, 365 days * 10_000);
        assertApproxEqAbs(expectedFee, linear, principal / 1e18 + 1, "linear rate up to index quantisation");
    }

    /// @dev 365 days * 10_000 = 2^11 * 3^3 * 5^7 * 73 and the 1e18 scale supplies every factor except
    /// 3^3 * 73 = 1971. Elapsed times that are multiples of 1971 seconds therefore produce an exact
    /// index delta, and the accrued fee must equal the pure linear formula floor(P * t * r / Y) to the
    /// wei, for any rate, principal and borrowing delay.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_accrualIsExactlyLinearWhenTheIndexDividesEvenly(
        uint256 rate,
        uint256 principal,
        uint256 delay,
        uint256 steps
    ) public {
        rate = bound(rate, 1, 10_000);
        principal = bound(principal, 1, 1e24);
        delay = bound(delay, 0, 3 * 365 days);
        steps = bound(steps, 0, 160_000); // up to about ten years
        uint256 elapsed = steps * 1971;
        _deploy(500, 0, rate, 0);
        vm.warp(block.timestamp + delay);
        _open(ALICE, 1e26, principal);
        vm.warp(block.timestamp + elapsed);

        uint256 expected = principal * elapsed * rate / (365 days * 10_000);
        assertEq(vault.feeOf(ALICE), expected, "fee equals the linear rate exactly");
        assertEq(vault.debtOf(ALICE), principal + expected);
        assertEq(vault.totalDebt(), principal, "principal is untouched by accrual");
        assertEq(comp.totalSupply(), principal, "accrual mints nothing");
    }

    /// @dev Every checkpoint carries its sub-wei remainder forward, so an account that is touched
    /// repeatedly at irregular intervals owes exactly what an untouched twin owes: fee-only payments
    /// leave the principal alone and the two accrual paths agree to the wei after two years.
    function test_feeCheckpointsCarryFractionsSoTouchedAndUntouchedTwinsOweTheSame() public {
        _deploy(500, 0, 1000, 0);
        uint256 principal = 123_456_789_012_345_678_901; // about 123.46 COMP, nothing divides cleanly
        _open(ALICE, 1e24, principal);
        _open(BOB, 1e24, principal);
        _work(ALICE, 1 ether);
        uint256 paid;
        for (uint256 i = 1; i <= 24; ++i) {
            vm.warp(block.timestamp + 20 days + i * 1234);
            assertGt(vault.feeOf(ALICE), 0, "an interval of three weeks accrues more than a wei");
            vm.prank(ALICE);
            vault.repayCOMP(1); // a fee-only payment that checkpoints the account
            ++paid;
            assertEq(vault.totalDebt(), 2 * principal, "fee-only payments leave both principals alone");
            assertEq(vault.debtIndexOf(ALICE), vault.debtIndex(), "the account is checkpointed now");
        }
        assertEq(vault.debtIndexOf(BOB), 1e18, "the twin was never checkpointed");
        assertEq(vault.feeOf(ALICE) + paid, vault.feeOf(BOB), "no fraction is lost across 24 checkpoints");
        assertEq(vault.debtOf(ALICE) + paid, vault.debtOf(BOB));
        assertEq(vault.totalFeesMinted(), paid);
        assertEq(comp.balanceOf(FEE_RECIPIENT), paid);
        _assertPrincipalSupply();
    }

    function test_lateBorrowerOwesOnlyItsOwnElapsedTime() public {
        _deploy(500, 0, 1000, 0);
        _open(ALICE, 1000 ether, 100 ether);
        vm.warp(block.timestamp + 365 days);
        _open(BOB, 1000 ether, 100 ether);
        assertEq(vault.debtOf(BOB), 100 ether, "indexed from deployment, charged from borrowing");
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.debtOf(ALICE), 120 ether);
        assertEq(vault.debtOf(BOB), 110 ether);
    }

    function test_feeIsMintedToTheRecipientOnlyWhenPaid() public {
        _deploy(500, 0, 1000, 0);
        _open(ALICE, 1000 ether, 100 ether);
        _work(ALICE, 10 ether);
        vm.warp(block.timestamp + 365 days);

        // A payment smaller than the fee pays fee only: principal and headroom are untouched.
        vm.expectEmit(true, false, false, true, address(vault));
        emit CDPVault.StabilityFeePaid(ALICE, 4 ether);
        vm.prank(ALICE);
        vault.repayCOMP(4 ether);
        assertEq(vault.feeOf(ALICE), 6 ether);
        assertEq(vault.totalDebt(), 100 ether);
        assertEq(comp.balanceOf(FEE_RECIPIENT), 4 ether);
        assertEq(vault.totalFeesMinted(), 4 ether);
        assertEq(comp.totalSupply(), 110 ether, "burn and fee mint cancel");

        // The rest of the fee, then principal.
        vm.prank(ALICE);
        vault.repayCOMP(16 ether);
        assertEq(vault.feeOf(ALICE), 0);
        assertEq(vault.debtOf(ALICE), 90 ether);
        assertEq(vault.totalDebt(), 90 ether);
        assertEq(comp.balanceOf(FEE_RECIPIENT), 10 ether);
        assertEq(vault.totalFeesMinted(), 10 ether);
        _assertPrincipalSupply();
    }

    function test_repaymentOneWeiBeyondAccruedDebtRevertsAndExactDebtClears() public {
        _deploy(500, 0, 1000, 0);
        _open(ALICE, 1000 ether, 100 ether);
        _work(ALICE, 20 ether);
        vm.warp(block.timestamp + 365 days);
        uint256 owed = vault.debtOf(ALICE);
        assertEq(owed, 110 ether);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vm.prank(ALICE);
        vault.repayCOMP(owed + 1);
        assertEq(vault.debtOf(ALICE), owed, "a rejected repayment leaves the accrual untouched");
        vm.prank(ALICE);
        vault.repayCOMP(owed);
        assertEq(vault.debtOf(ALICE), 0);
        assertEq(vault.feeOf(ALICE), 0);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.debtOf(ALICE), 0, "a closed position accrues nothing");
    }

    function test_healthLiquidationAndRepaymentSeeTheSameAccruedFigure() public {
        _deploy(500, 1000, 1000, 0);
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 110 ether);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.collateralRatio(ALICE), 136, "150 / 110");

        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vm.prank(ALICE);
        vault.withdrawCollateral(1);
        _expectMintRevert(ALICE, 1, CDPVault.UnsafeCollateralRatio.selector);

        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        uint256 keeperBefore = imd.balanceOf(KEEPER);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vm.prank(BOB);
        vault.liquidate(ALICE, 110 ether + 1);
        vm.prank(BOB);
        vault.liquidate(ALICE, 110 ether);
        (uint256 collateral, uint256 debt) = vault.positions(ALICE);
        assertEq(collateral, 150 ether - 121 ether);
        assertEq(debt, 0);
        assertEq(vault.totalFeesMinted(), 10 ether, "the liquidator paid the fee");
        assertEq(comp.balanceOf(FEE_RECIPIENT), 10 ether);
        assertEq(imd.balanceOf(KEEPER) - keeperBefore, 1.1 ether, "marker share of the whole bonus");
        _assertPrincipalSupply();
    }

    function test_maximumRateDoublesDebtInOneYearAndStillAccruesLinearly() public {
        _deploy(500, 0, 10_000, 0);
        _open(ALICE, 1000 ether, 100 ether);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.debtOf(ALICE), 200 ether);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.debtOf(ALICE), 300 ether, "simple interest on principal only");
    }

    function test_zeroRateMintsNoFeeAndOriginalSupplyIdentityHolds() public {
        // The shipped deployment word: nothing fee-related may move.
        _open(ALICE, 300 ether, 100 ether);
        _work(BOB, 100 ether);
        assertEq(vault.stabilityFeeBps(), 0);
        vm.warp(block.timestamp + 50 * 365 days);
        assertEq(vault.debtIndex(), 1e18);
        assertEq(vault.debtIndexOf(ALICE), 0, "no checkpoint is ever written");
        assertEq(vault.feeOf(ALICE), 0);
        assertEq(vault.debtOf(ALICE), 100 ether);
        assertEq(comp.totalSupply(), vault.debtOf(ALICE) + vault.totalWorkMinted(), "original identity");

        vm.recordLogs();
        vm.prank(ALICE);
        vault.repayCOMP(40 ether);
        _price(0.3 ether); // 300 IMD against 60 COMP: CR 150, under the 200 floor at NHI .60
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        vm.prank(BOB);
        vault.liquidate(ALICE, 20 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != CDPVault.StabilityFeePaid.selector, "no fee event at zero rate");
        }
        assertEq(vault.totalFeesMinted(), 0);
        assertEq(comp.balanceOf(FEE_RECIPIENT), 0);
        assertEq(vault.debtOf(ALICE), 40 ether);
        assertEq(comp.totalSupply(), vault.debtOf(ALICE) + vault.totalWorkMinted(), "original identity");
        assertEq(comp.totalSupply(), vault.totalDebt() + vault.totalWorkMinted(), "restated identity agrees");
    }

    function test_smallestRateAccruesAfterAYearOnLargePrincipal() public {
        _deploy(500, 0, 1, 0);
        _open(ALICE, 1e26, 1e22);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.feeOf(ALICE), 1e18, "one basis point of 10,000 COMP");
    }

    // ---------------------------------------------------------------------------------------------
    // FOUR. Bad debt
    // ---------------------------------------------------------------------------------------------

    function test_liquidationExhaustingCollateralRecordsExactlyTheShortfall() public {
        _open(ALICE, 220 ether, 100 ether);
        _work(BOB, 100 ether);
        _price(0.25 ether);
        nhi.setValue(0.6 ether);
        assertEq(vault.badDebtOf(ALICE), 50 ether, "220 IMD at 0.25 covers a 50 COMP payout");
        assertEq(vault.totalBadDebt(), 0, "the view is not the accumulator");
        _mark(KEEPER, ALICE);

        vm.expectEmit(true, false, false, true, address(vault));
        emit CDPVault.BadDebtRecorded(ALICE, 50 ether);
        vm.prank(BOB);
        vault.liquidate(ALICE, 50 ether);
        (uint256 collateral, uint256 debt) = vault.positions(ALICE);
        assertEq(collateral, 0);
        assertEq(debt, 50 ether);
        assertEq(vault.totalBadDebt(), 50 ether);
        assertEq(vault.recordedBadDebtOf(ALICE), 50 ether);
        assertEq(vault.badDebtOf(ALICE), 50 ether, "with no collateral the whole debt is uncovered");
        _assertPrincipalSupply();
    }

    /// @dev At a primary of 0.25 a repayment of 5k COMP seizes exactly 22k wei of IMD, so a position
    /// holding 22k wei against 5k plus a random shortfall is exhausted by one liquidation. With another
    /// account's record already in the accumulator, the delta must be the shortfall to the wei, and it
    /// must equal what badDebtOf predicted before the liquidation.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_exhaustingLiquidationMovesTheAccumulatorByExactlyThePredictedShortfall(
        uint256 k,
        uint256 shortfall
    ) public {
        k = bound(k, 1e17, 2e19);
        shortfall = bound(shortfall, 1, 1e20);
        uint256 repayable = 5 * k;
        uint256 collateral = 22 * k;
        uint256 debt = repayable + shortfall;

        // CAROL seeds the accumulator so the delta, not the absolute value, is what the test measures.
        _open(CAROL, 220 ether, 100 ether);
        _work(BOB, 100 ether + debt);
        _price(Math.mulDiv(2e18, debt, collateral) + 1); // ALICE opens healthy at this price
        _open(ALICE, collateral, debt);
        _price(0.25 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, CAROL);
        vm.prank(BOB);
        vault.liquidate(CAROL, 50 ether);
        assertEq(vault.totalBadDebt(), 50 ether, "seeded accumulator");

        assertEq(vault.badDebtOf(ALICE), shortfall, "the view predicts the shortfall");
        _mark(KEEPER, ALICE);
        uint256 before = vault.totalBadDebt();
        vm.expectEmit(true, false, false, true, address(vault));
        emit CDPVault.BadDebtRecorded(ALICE, shortfall);
        vm.prank(BOB);
        vault.liquidate(ALICE, repayable);

        (uint256 collateralLeft, uint256 debtLeft) = vault.positions(ALICE);
        assertEq(collateralLeft, 0, "exactly exhausted");
        assertEq(debtLeft, shortfall);
        assertEq(vault.totalBadDebt() - before, shortfall, "the accumulator moves by exactly the shortfall");
        assertEq(vault.recordedBadDebtOf(ALICE), shortfall);
        assertEq(vault.badDebtOf(ALICE), shortfall, "the view and the record agree once nothing is left");
        assertEq(vault.totalBadDebt(), vault.recordedBadDebtOf(ALICE) + vault.recordedBadDebtOf(CAROL));
        _assertPrincipalSupply();
    }

    function test_shortfallIncludesAccruedFeesAtTheMomentOfLiquidation() public {
        _deploy(500, 1000, 1000, 0);
        _open(ALICE, 220 ether, 100 ether);
        _work(BOB, 100 ether);
        vm.warp(block.timestamp + 365 days);
        _price(0.25 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        vm.prank(BOB);
        vault.liquidate(ALICE, 50 ether);
        assertEq(vault.debtOf(ALICE), 60 ether, "110 owed, 50 paid");
        assertEq(vault.totalBadDebt(), 60 ether);
        assertEq(vault.totalFeesMinted(), 10 ether, "the fee portion was paid by the liquidator first");
    }

    function test_liquidationLeavingCollateralRecordsNothingEvenWhenShort() public {
        _open(ALICE, 220 ether, 100 ether);
        _work(BOB, 100 ether);
        _price(0.25 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        vm.prank(BOB);
        vault.liquidate(ALICE, 40 ether); // seizes 176, leaves 44 IMD against 60 COMP
        (uint256 collateral, uint256 debt) = vault.positions(ALICE);
        assertEq(collateral, 44 ether);
        assertEq(debt, 60 ether);
        assertEq(vault.badDebtOf(ALICE), 50 ether, "44 IMD covers 10 COMP of payout");
        assertEq(vault.totalBadDebt(), 0, "only an exhausting liquidation checkpoints");
        assertEq(vault.recordedBadDebtOf(ALICE), 0);

        vm.prank(BOB);
        vault.liquidate(ALICE, 10 ether);
        assertEq(vault.totalBadDebt(), 50 ether, "the exhausting follow-up records the remainder");
    }

    function test_cleanLiquidationsRecordNoBadDebt() public {
        _price(2 ether);
        _open(ALICE, 110 ether, 100 ether);
        _work(BOB, 100 ether);
        _price(1 ether); // CR 110 exactly
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        vm.recordLogs();
        vm.prank(BOB);
        vault.liquidate(ALICE, 100 ether); // seizes exactly 110: no collateral, no debt
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != CDPVault.BadDebtRecorded.selector, "nothing to record");
        }
        (uint256 collateral, uint256 debt) = vault.positions(ALICE);
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(vault.totalBadDebt(), 0);
        assertEq(vault.badDebtOf(ALICE), 0);
    }

    function test_badDebtViewBoundaries() public {
        assertEq(vault.badDebtOf(ALICE), 0, "no position");
        _price(2 ether);
        _open(ALICE, 110 ether, 100 ether);
        _work(BOB, 100 ether);
        _price(1 ether);
        assertEq(vault.collateralRatio(ALICE), 110);
        assertEq(vault.badDebtOf(ALICE), 0, "exactly 110% is fully coverable");
        _price(1 ether - 1);
        assertGt(vault.badDebtOf(ALICE), 0, "one wei below 110% is not");
        _price(1 ether);

        _open(CAROL, 1000 ether, 1);
        assertEq(vault.badDebtOf(CAROL), 0, "one-wei debt with plenty of collateral");
        _price(1); // one wei price: CR saturates far above 110
        assertEq(vault.badDebtOf(CAROL), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_badDebtViewMatchesTheLargestExecutablePayout(uint256 collateral, uint256 debt, uint256 price)
        public
    {
        collateral = bound(collateral, 1, 1e24);
        debt = bound(debt, 1, 1e24);
        price = bound(price, 1, 1e24);
        // Open at a price that makes the position safe, then move the primary to the fuzzed price.
        _price(Math.mulDiv(2e18, debt, collateral) + 1);
        _open(ALICE, collateral, debt);
        _price(price);

        uint256 shortfall = vault.badDebtOf(ALICE);
        assertLe(shortfall, debt);
        uint256 repayable = debt - shortfall;
        if (repayable != 0) {
            assertLe(Math.mulDiv(repayable, PAYOUT_SCALE, price), collateral, "the reported coverage is executable");
        }
        if (shortfall != 0) {
            assertGt(Math.mulDiv(repayable + 1, PAYOUT_SCALE, price), collateral, "one more wei would not fit");
        }
        // A ratio at or above the payout always covers the whole debt. The converse does not hold at
        // wei scale: the floored payout can make a one-wei position fully liquidatable below 110%.
        if (vault.collateralRatio(ALICE) >= 110) assertEq(shortfall, 0, "110% covers everything");
    }

    function test_badDebtRecordShrinksOnlyByRepaymentNotDepositPriceOrTime() public {
        _deploy(500, 1000, 1000, 0);
        _open(ALICE, 220 ether, 100 ether);
        _work(BOB, 100 ether);
        _work(ALICE, 100 ether);
        _price(0.25 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        vm.prank(BOB);
        vault.liquidate(ALICE, 50 ether);
        assertEq(vault.totalBadDebt(), 50 ether);

        vm.warp(block.timestamp + 365 days);
        assertEq(vault.badDebtOf(ALICE), 55 ether, "the view is live");
        assertEq(vault.totalBadDebt(), 50 ether, "the accumulator moves only at checkpoints");

        _price(100 ether);
        assertEq(vault.totalBadDebt(), 50 ether, "a price recovery is not a payment");
        vm.prank(ALICE);
        vault.depositCollateral(1000 ether);
        assertEq(vault.badDebtOf(ALICE), 0, "fresh collateral covers the live view");
        assertEq(vault.totalBadDebt(), 50 ether, "but does not erase the record");

        vm.prank(ALICE);
        vault.repayCOMP(15 ether);
        assertEq(vault.totalBadDebt(), 40 ether, "accrued 5 joined the record, 15 paid left it");
        assertEq(vault.debtOf(ALICE), 40 ether);
        vm.prank(ALICE);
        vault.repayCOMP(40 ether);
        assertEq(vault.totalBadDebt(), 0);
        assertEq(vault.recordedBadDebtOf(ALICE), 0);
    }

    function test_totalBadDebtSumsAcrossAccounts() public {
        _open(ALICE, 220 ether, 100 ether);
        _open(CAROL, 440 ether, 200 ether);
        _work(BOB, 300 ether);
        _price(0.25 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        _mark(KEEPER, CAROL);
        vm.prank(BOB);
        vault.liquidate(ALICE, 50 ether);
        assertEq(vault.totalBadDebt(), 50 ether);
        vm.prank(BOB);
        vault.liquidate(CAROL, 100 ether);
        assertEq(vault.totalBadDebt(), 150 ether);
        assertEq(vault.recordedBadDebtOf(ALICE) + vault.recordedBadDebtOf(CAROL), vault.totalBadDebt());

        // An account with no collateral cannot be liquidated further; the record is final until paid.
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vm.prank(BOB);
        vault.liquidate(ALICE, 1 ether);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vm.prank(ALICE);
        vault.withdrawCollateral(1);
    }

    function test_oversizedLiquidationRevertsInsteadOfClampingOrForgiving() public {
        _open(ALICE, 220 ether, 100 ether);
        _work(BOB, 100 ether);
        _price(0.25 ether);
        nhi.setValue(0.6 ether);
        _mark(KEEPER, ALICE);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vm.prank(BOB);
        vault.liquidate(ALICE, 50 ether + 1);
        assertEq(vault.totalBadDebt(), 0);
        assertEq(vault.debtOf(ALICE), 100 ether);
        assertEq(comp.balanceOf(BOB), 100 ether, "nothing burned");
    }
}
