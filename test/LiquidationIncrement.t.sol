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
