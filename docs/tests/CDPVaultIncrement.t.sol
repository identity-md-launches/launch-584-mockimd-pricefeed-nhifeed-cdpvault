// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CDPVault} from "../../src/CDPVault.sol";
import {CompToken} from "../../src/CompToken.sol";
import {MockIMD} from "../../src/MockIMD.sol";
import {MockWorkOracle} from "../../src/MockWorkOracle.sol";
import {ISwarmFeed} from "../../src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, FEE_RECIPIENT} from "../../src/DeploymentConfig.sol";

contract IncrementFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 internal value;
    bool internal stale;

    constructor(uint256 value_) {
        value = value_;
    }

    function setValue(uint256 value_) external {
        value = value_;
    }

    function setStale(bool stale_) external {
        stale = stale_;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, uint64(block.timestamp));
    }

    function isStale() external view returns (bool) {
        return stale;
    }
}

contract IncrementVault is CDPVault {
    uint256 private immutable protocolShare;
    uint256 private immutable ceiling;

    constructor(
        address imd,
        address primary,
        address nhi,
        address spot,
        uint256 marker,
        uint256 rate,
        uint256 protocolShare_,
        uint256 ceiling_
    ) CDPVault(imd, address(0), address(0), primary, nhi, spot, 500, marker, rate) {
        protocolShare = protocolShare_;
        ceiling = ceiling_;
    }

    function protocolBonusShareBps() public view override returns (uint256) {
        return protocolShare;
    }

    function debtCeiling() public view override returns (uint256) {
        return ceiling;
    }
}

/// @notice Offline regression tests for the fifth vault increment. Copy into test/scratch to run.
contract CDPVaultIncrementTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant MARKER = address(0xCA11);
    address private constant OTHER = address(0xCA12);
    MockIMD private imd;
    IncrementFeed private primary;
    IncrementFeed private spot;
    IncrementFeed private nhi;
    CDPVault private vault;
    CompToken private comp;

    function setUp() public {
        vm.warp(10 days);
        imd = new MockIMD();
        primary = new IncrementFeed(1 ether);
        spot = new IncrementFeed(1 ether);
        nhi = new IncrementFeed(0.85 ether);
        _deploy(0, 0, 0, type(uint256).max);
    }

    function _deploy(uint256 marker, uint256 rate, uint256 protocol, uint256 ceiling) private {
        vault = new IncrementVault(
            address(imd), address(primary), address(nhi), address(spot), marker, rate, protocol, ceiling
        );
        comp = vault.compToken();
        _fund(ALICE, 100_000 ether);
        _fund(BOB, 100_000 ether);
    }

    function _fund(address user, uint256 amount) private {
        vm.prank(APPROVED_OPERATOR);
        imd.mint(user, amount);
        vm.prank(user);
        imd.approve(address(vault), type(uint256).max);
    }

    function _open(address user, uint256 collateral, uint256 debt) private {
        vm.startPrank(user);
        vault.depositCollateral(collateral);
        if (debt != 0) vault.mintCOMP(debt);
        vm.stopPrank();
    }

    function _work(address user, uint256 amount) private {
        MockWorkOracle workOracle = MockWorkOracle(address(vault.oracle()));
        vm.prank(APPROVED_OPERATOR);
        workOracle.grantRights(user, amount);
        vm.prank(user);
        vault.mintFromWork(amount);
    }

    function _price(uint256 price) private {
        primary.setValue(price);
        spot.setValue(price);
    }

    function _mark() private {
        vm.prank(MARKER);
        vault.markUnderwater(ALICE);
    }

    function _assertSupply() private view {
        assertEq(comp.totalSupply(), vault.totalDebt() + vault.totalWorkMinted(), "supply and principal");
        assertEq(
            vault.totalDebt(),
            vault.debtOf(ALICE) - vault.feeOf(ALICE) + vault.debtOf(BOB) - vault.feeOf(BOB),
            "principal sum"
        );
    }

    function test_divergenceBoundaryIncludesBothDirections() public {
        _open(ALICE, 300 ether, 100 ether);
        spot.setValue(1.05 ether);
        vm.prank(ALICE);
        vault.mintCOMP(1 ether);
        spot.setValue(0.95 ether);
        vm.prank(ALICE);
        vault.mintCOMP(1 ether);
        spot.setValue(1.05 ether + 1);
        vm.expectRevert();
        vm.prank(ALICE);
        vault.mintCOMP(1);
        spot.setValue(0.95 ether - 1);
        vm.expectRevert();
        vm.prank(ALICE);
        vault.mintCOMP(1);
    }

    function test_divergenceDenominatorIsPrimaryAndFractionRoundsSafely() public {
        _open(ALICE, 1000 ether, 1);
        primary.setValue(101);
        spot.setValue(106); // floor(101 * 5%) == 5.
        vm.prank(ALICE);
        vault.mintCOMP(1);
        spot.setValue(107);
        vm.expectRevert();
        vm.prank(ALICE);
        vault.mintCOMP(1);
        spot.setValue(95);
        vm.expectRevert();
        vm.prank(ALICE);
        vault.mintCOMP(1);
    }

    function test_divergenceBlocksMarkAndLiquidation() public {
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 100 ether);
        nhi.setValue(0.6 ether);
        spot.setValue(0.9 ether);
        vm.expectRevert();
        vault.markUnderwater(ALICE);
        spot.setValue(1 ether);
        _mark();
        spot.setValue(1.1 ether);
        vm.expectRevert();
        vm.prank(BOB);
        vault.liquidate(ALICE, 10 ether);
        // A pushed primary the spot contradicts cannot be used to discard the live mark either.
        primary.setValue(2 ether);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vault.clearRecoveredMark(ALICE);
        primary.setValue(1 ether);
        assertEq(vault.debtOf(ALICE), 100 ether);
    }

    function test_zeroAndStaleSpotBlockOnlyGuardedActions() public {
        _open(ALICE, 150 ether, 100 ether);
        nhi.setValue(0.6 ether);
        spot.setStale(true);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.markUnderwater(ALICE);
        spot.setStale(false);
        spot.setValue(0);
        vm.expectRevert(CDPVault.InvalidPrice.selector);
        vault.markUnderwater(ALICE);
        vm.prank(ALICE);
        vault.repayCOMP(100 ether);
        vm.prank(ALICE);
        vault.withdrawCollateral(150 ether);
        (uint256 collateral, uint256 debt) = vault.positions(ALICE);
        assertEq(collateral, 0);
        assertEq(debt, 0);
    }

    function test_repaymentAndDebtFreeWithdrawalIgnoreAllStaleFeeds() public {
        _open(ALICE, 150 ether, 100 ether);
        primary.setStale(true);
        nhi.setStale(true);
        spot.setStale(true);
        spot.setValue(100 ether);
        vm.prank(ALICE);
        vault.repayCOMP(100 ether);
        vm.prank(ALICE);
        vault.withdrawCollateral(150 ether);
        _assertSupply();
    }

    function test_debtBearingWithdrawalIsPriceDependentAndGuarded() public {
        _open(ALICE, 300 ether, 100 ether);
        // A debt-bearing withdrawal is allowed only because the primary says the remainder is healthy,
        // so a primary the spot contradicts must not release collateral against open debt.
        spot.setValue(100 ether);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(ALICE);
        vault.withdrawCollateral(1 ether);
        spot.setValue(1 ether);
        vm.prank(ALICE);
        vault.withdrawCollateral(1 ether);
        primary.setStale(true);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vm.prank(ALICE);
        vault.withdrawCollateral(1 ether);
    }

    function test_markerAndProtocolSplitSameBonusWithoutIncreasingLoss() public {
        _deploy(1000, 0, 2000, type(uint256).max);
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 100 ether);
        nhi.setValue(0.6 ether);
        _mark();
        uint256 bobBefore = imd.balanceOf(BOB);
        uint256 protocolBefore = imd.balanceOf(FEE_RECIPIENT);
        vm.prank(BOB);
        vault.liquidate(ALICE, 10 ether);
        (uint256 collateral, uint256 debt) = vault.positions(ALICE);
        assertEq(collateral, 139 ether);
        assertEq(debt, 90 ether);
        assertEq(imd.balanceOf(MARKER), 0.1 ether);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - protocolBefore, 0.2 ether);
        assertEq(imd.balanceOf(BOB) - bobBefore, 10.7 ether);

        _deploy(0, 0, 0, type(uint256).max);
        nhi.setValue(0.85 ether);
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 100 ether);
        nhi.setValue(0.6 ether);
        _mark();
        vm.prank(BOB);
        vault.liquidate(ALICE, 10 ether);
        (uint256 baselineCollateral, uint256 baselineDebt) = vault.positions(ALICE);
        assertEq(collateral, baselineCollateral);
        assertEq(debt, baselineDebt);
    }

    function test_markerAsLiquidatorGetsCombinedPayment() public {
        _deploy(1000, 0, 2000, type(uint256).max);
        _open(ALICE, 150 ether, 100 ether);
        _work(MARKER, 10 ether);
        nhi.setValue(0.6 ether);
        _mark();
        vm.recordLogs();
        vm.prank(MARKER);
        vault.liquidate(ALICE, 10 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 transfers;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(imd) && logs[i].topics.length == 3
                    && logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")
                    && logs[i].topics[2] == bytes32(uint256(uint160(MARKER)))
            ) ++transfers;
        }
        assertEq(transfers, 1, "combined marker/liquidator transfer");
        assertEq(imd.balanceOf(MARKER), 10.8 ether);
    }

    function test_markPreservesMarkerAndGraceUntilExpiry() public {
        _open(ALICE, 150 ether, 100 ether);
        _price(0.9 ether);
        _mark();
        (uint256 firstAt, uint256 firstGrace, bool marked, address marker) = vault.liquidationMarks(ALICE);
        assertTrue(marked);
        assertEq(firstGrace, 6 hours);
        assertEq(marker, MARKER);
        vm.warp(block.timestamp + 1 hours);
        nhi.setValue(0.6 ether);
        vm.prank(OTHER);
        vault.markUnderwater(ALICE);
        (uint256 secondAt, uint256 secondGrace,, address secondMarker) = vault.liquidationMarks(ALICE);
        assertEq(secondAt, firstAt);
        assertEq(secondGrace, firstGrace);
        assertEq(secondMarker, MARKER);
        vm.warp(firstAt + firstGrace + vault.liquidationWindow() + 1);
        vm.prank(OTHER);
        vault.markUnderwater(ALICE);
        (uint256 thirdAt, uint256 thirdGrace,, address thirdMarker) = vault.liquidationMarks(ALICE);
        assertEq(thirdAt, block.timestamp);
        assertEq(thirdGrace, 0);
        assertEq(thirdMarker, OTHER);
    }

    function test_recoveryClearsMarkerAndNextMarkHasNewOwner() public {
        _open(ALICE, 150 ether, 100 ether);
        _price(0.9 ether);
        _mark();
        vm.prank(ALICE);
        vault.depositCollateral(100 ether);
        (,, bool marked, address marker) = vault.liquidationMarks(ALICE);
        assertFalse(marked);
        assertEq(marker, address(0));
        _price(0.5 ether);
        vm.prank(OTHER);
        vault.markUnderwater(ALICE);
        (,,, marker) = vault.liquidationMarks(ALICE);
        assertEq(marker, OTHER);
    }

    function test_stabilityFeeIsLinearAndLateBorrowerOwesOnlyElapsedTime() public {
        _deploy(0, 1000, 0, type(uint256).max);
        _open(ALICE, 1000 ether, 100 ether);
        uint256 start = block.timestamp;
        vm.warp(start + 365 days);
        assertEq(vault.debtOf(ALICE), 110 ether);
        assertEq(vault.feeOf(ALICE), 10 ether);
        _open(BOB, 1000 ether, 100 ether);
        assertEq(vault.debtOf(BOB), 100 ether);
        vm.warp(start + 2 * 365 days);
        assertEq(vault.debtOf(ALICE), 120 ether);
        assertEq(vault.debtOf(BOB), 110 ether);
        (, uint256 debt) = vault.positions(ALICE);
        assertEq(debt, 120 ether, "public position debt accrues too");
        assertEq(vault.totalDebt(), 200 ether, "ceiling principal remains unchanged");
        _assertSupply();
    }

    function test_collateralChangesDoNotResetFeeIndex() public {
        _deploy(0, 1000, 0, type(uint256).max);
        _open(ALICE, 1000 ether, 100 ether);
        uint256 originalIndex = vault.debtIndexOf(ALICE);
        uint256 start = block.timestamp;
        vm.warp(start + 365 days / 2);
        vm.prank(ALICE);
        vault.depositCollateral(1 ether);
        vm.prank(ALICE);
        vault.withdrawCollateral(1 ether);
        assertEq(vault.debtIndexOf(ALICE), originalIndex);
        vm.warp(start + 365 days);
        assertEq(vault.debtOf(ALICE), 110 ether);
    }

    function test_partialRepaymentPaysFeesFirstAndDoesNotCompound() public {
        _deploy(0, 1000, 0, type(uint256).max);
        _open(ALICE, 1000 ether, 100 ether);
        uint256 start = block.timestamp;
        vm.warp(start + 365 days);
        vm.prank(ALICE);
        vault.repayCOMP(5 ether);
        assertEq(vault.debtOf(ALICE), 105 ether);
        assertEq(vault.feeOf(ALICE), 5 ether);
        assertEq(vault.totalDebt(), 100 ether);
        assertEq(comp.balanceOf(FEE_RECIPIENT), 5 ether);
        assertEq(vault.totalFeesMinted(), 5 ether);
        vm.warp(start + 2 * 365 days);
        assertEq(vault.debtOf(ALICE), 115 ether, "unpaid fees earn no fees");
        vm.prank(ALICE);
        vault.repayCOMP(25 ether);
        assertEq(vault.debtOf(ALICE), 90 ether);
        assertEq(vault.feeOf(ALICE), 0);
        assertEq(vault.totalDebt(), 90 ether);
        assertEq(vault.totalFeesMinted(), 20 ether);
        _assertSupply();
    }

    function test_fullyRepaidPositionStopsAccruingAndReopenStartsFresh() public {
        _deploy(0, 1000, 0, type(uint256).max);
        _open(ALICE, 1000 ether, 100 ether);
        _work(ALICE, 10 ether);
        vm.warp(block.timestamp + 365 days);
        vm.prank(ALICE);
        vault.repayCOMP(110 ether);
        assertEq(vault.debtOf(ALICE), 0);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.debtOf(ALICE), 0);
        assertEq(vault.feeOf(ALICE), 0);
        vm.prank(ALICE);
        vault.mintCOMP(10 ether);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.debtOf(ALICE), 11 ether);
        _assertSupply();
    }

    function test_mintPreservesAccruedFeesAndOnlyNewPrincipalAccruesLater() public {
        _deploy(0, 1000, 0, type(uint256).max);
        _open(ALICE, 1000 ether, 100 ether);
        vm.warp(block.timestamp + 365 days);
        vm.prank(ALICE);
        vault.mintCOMP(100 ether);
        assertEq(vault.debtOf(ALICE), 210 ether);
        assertEq(vault.feeOf(ALICE), 10 ether);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.debtOf(ALICE), 230 ether);
        _assertSupply();
    }

    function test_healthWithdrawalAndLiquidationReadAccruedDebt() public {
        _deploy(1000, 1000, 0, type(uint256).max);
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 110 ether);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.collateralRatio(ALICE), 136);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vm.prank(ALICE);
        vault.withdrawCollateral(1);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vm.prank(ALICE);
        vault.mintCOMP(1);
        nhi.setValue(0.6 ether);
        _mark();
        vm.prank(BOB);
        vault.liquidate(ALICE, 110 ether);
        (uint256 collateral, uint256 debt) = vault.positions(ALICE);
        assertEq(collateral, 29 ether);
        assertEq(debt, 0);
        assertEq(vault.totalFeesMinted(), 10 ether);
        assertEq(comp.balanceOf(FEE_RECIPIENT), 10 ether);
        assertEq(imd.balanceOf(MARKER), 1.1 ether);
        _assertSupply();
    }

    function test_zeroRateAccruesNothingAfterLongDelay() public {
        _open(ALICE, 300 ether, 100 ether);
        vm.warp(block.timestamp + 100 * 365 days);
        assertEq(vault.debtOf(ALICE), 100 ether);
        assertEq(vault.feeOf(ALICE), 0);
        assertEq(vault.debtIndex(), 1 ether);
        vm.prank(ALICE);
        vault.repayCOMP(100 ether);
        assertEq(vault.totalFeesMinted(), 0);
        assertEq(comp.balanceOf(FEE_RECIPIENT), 0);
        _assertSupply();
    }

    function test_debtCeilingStillCountsPrincipalAndWorkIsIndependent() public {
        _deploy(0, 1000, 0, 100 ether);
        _open(ALICE, 1000 ether, 100 ether);
        _work(BOB, 200 ether);
        vm.warp(block.timestamp + 365 days);
        vm.prank(ALICE);
        vault.repayCOMP(10 ether);
        assertEq(vault.totalDebt(), 100 ether, "fees do not restore borrowing headroom");
        vm.expectRevert(CDPVault.DebtCeilingReached.selector);
        vm.prank(ALICE);
        vault.mintCOMP(1);
        vm.prank(ALICE);
        vault.repayCOMP(1 ether);
        vm.prank(ALICE);
        vault.mintCOMP(1 ether);
        _assertSupply();
    }

    function test_badDebtReports110PercentCoverageAndTracksResidual() public {
        _open(ALICE, 220 ether, 100 ether);
        _work(BOB, 100 ether);
        _price(0.25 ether);
        nhi.setValue(0.6 ether);
        assertEq(vault.badDebtOf(ALICE), 50 ether);
        assertEq(vault.totalBadDebt(), 0, "view shortfall is not a liquidation checkpoint");
        _mark();
        vm.prank(BOB);
        vault.liquidate(ALICE, 50 ether);
        (uint256 collateral, uint256 debt) = vault.positions(ALICE);
        assertEq(collateral, 0);
        assertEq(debt, 50 ether);
        assertEq(vault.badDebtOf(ALICE), 50 ether);
        assertEq(vault.totalBadDebt(), 50 ether);
        vm.prank(ALICE);
        vault.repayCOMP(10 ether);
        assertEq(vault.totalBadDebt(), 40 ether);
        assertEq(vault.debtOf(ALICE), 40 ether);
        _assertSupply();
    }

    function test_badDebtCannotDisappearThroughFailedLiquidationOrWithdrawal() public {
        _open(ALICE, 220 ether, 100 ether);
        _work(BOB, 100 ether);
        _price(0.25 ether);
        nhi.setValue(0.6 ether);
        _mark();
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vm.prank(BOB);
        vault.liquidate(ALICE, 100 ether);
        assertEq(vault.debtOf(ALICE), 100 ether);
        assertEq(vault.totalDebt(), 100 ether);
        vm.prank(BOB);
        vault.liquidate(ALICE, 50 ether);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vm.prank(ALICE);
        vault.withdrawCollateral(1);
        assertEq(vault.debtOf(ALICE), 50 ether);
        vm.prank(ALICE);
        vault.repayCOMP(50 ether);
        assertEq(vault.totalBadDebt(), 0);
        assertEq(vault.debtOf(ALICE), 0);
        _assertSupply();
    }

    function test_collateralDepositDoesNotEraseRecognizedBadDebt() public {
        _open(ALICE, 220 ether, 100 ether);
        _work(BOB, 100 ether);
        _price(0.25 ether);
        nhi.setValue(0.6 ether);
        _mark();
        vm.prank(BOB);
        vault.liquidate(ALICE, 50 ether);
        vm.prank(ALICE);
        vault.depositCollateral(1);
        assertEq(vault.debtOf(ALICE), 50 ether);
        assertEq(vault.totalBadDebt(), 50 ether, "a dust deposit is not a payment");
        vm.prank(ALICE);
        vault.depositCollateral(1000 ether);
        assertEq(vault.badDebtOf(ALICE), 0, "fresh coverage view reflects new collateral");
        assertEq(vault.totalBadDebt(), 50 ether, "recognized debt remains until paid");
        vm.prank(ALICE);
        vault.repayCOMP(50 ether);
        assertEq(vault.totalBadDebt(), 0);
    }

    function test_badDebtUsesExecutableFloorPayoutAtWeiBoundary() public {
        _price(10 ether);
        _open(ALICE, 3, 10);
        _work(BOB, 10);
        _price(2 ether);
        nhi.setValue(0.6 ether);
        assertEq(vault.badDebtOf(ALICE), 3, "seven wei debt seizes floor(7 * 1.1 / 2) = 3");
        _mark();
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vm.prank(BOB);
        vault.liquidate(ALICE, 8);
        vm.prank(BOB);
        vault.liquidate(ALICE, 7);
        assertEq(vault.badDebtOf(ALICE), 3);
        assertEq(vault.totalBadDebt(), 3);
    }

    function test_fractionalFeeCarriesAcrossPartialRepayments() public {
        _deploy(0, 10_000, 0, type(uint256).max);
        _open(ALICE, 1000, 100);
        for (uint256 day; day < 4; ++day) {
            vm.warp(block.timestamp + 1 days);
            vm.prank(ALICE);
            vault.repayCOMP(1);
        }
        assertEq(vault.totalFeesMinted(), 1, "fractional fees survive debt snapshots");
        assertEq(vault.totalDebt(), 97);
        assertEq(vault.debtOf(ALICE), 97);
        _assertSupply();
    }

    function test_fullRepaymentClearsFractionalFeeCarry() public {
        _deploy(0, 10_000, 0, type(uint256).max);
        _open(ALICE, 1000, 1);
        vm.warp(block.timestamp + 364 days);
        vm.prank(ALICE);
        vault.repayCOMP(1);
        vm.prank(ALICE);
        vault.mintCOMP(1);
        vm.warp(block.timestamp + 2 days);
        assertEq(vault.debtOf(ALICE), 1);
        assertEq(vault.feeOf(ALICE), 0);
    }

    function test_constructorValidatesBpsAndSpotAddress() public {
        vm.expectRevert();
        new CDPVault(address(imd), address(0), address(0), address(primary), address(nhi), address(0), 500, 0, 0);
        vm.expectRevert();
        new CDPVault(address(imd), address(0), address(0), address(primary), address(nhi), address(spot), 10_001, 0, 0);
        vm.expectRevert();
        new CDPVault(
            address(imd), address(0), address(0), address(primary), address(nhi), address(spot), 500, 10_001, 0
        );
        vm.expectRevert();
        new CDPVault(
            address(imd), address(0), address(0), address(primary), address(nhi), address(spot), 500, 0, 10_001
        );
    }

    function test_bonusSharesCannotTakeLiquidatorPrincipal() public {
        _deploy(6000, 0, 5000, type(uint256).max);
        _open(ALICE, 150 ether, 100 ether);
        _work(BOB, 100 ether);
        nhi.setValue(0.6 ether);
        _mark();
        vm.expectRevert();
        vm.prank(BOB);
        vault.liquidate(ALICE, 10 ether);
        assertEq(vault.debtOf(ALICE), 100 ether);
    }

    function test_badDebtAccrualIsLiveInViewAndCheckpointedOnRepayment() public {
        _deploy(0, 1000, 0, type(uint256).max);
        _open(ALICE, 220 ether, 100 ether);
        _work(BOB, 100 ether);
        _price(0.25 ether);
        nhi.setValue(0.6 ether);
        _mark();
        vm.prank(BOB);
        vault.liquidate(ALICE, 50 ether);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.badDebtOf(ALICE), 55 ether);
        assertEq(vault.totalBadDebt(), 50 ether, "aggregate is a liquidation/payment checkpoint");
        vm.prank(ALICE);
        vault.repayCOMP(10 ether);
        assertEq(vault.badDebtOf(ALICE), 45 ether);
        assertEq(vault.totalBadDebt(), 45 ether);
        assertEq(vault.totalFeesMinted(), 5 ether);
        _assertSupply();
    }

    function test_dustRecollateralizationCannotHideLaterFeesOrDoubleCountCheckpoints() public {
        _deploy(0, 1000, 0, type(uint256).max);
        _open(ALICE, 220 ether, 100 ether);
        _work(BOB, 100 ether);
        _price(0.25 ether);
        nhi.setValue(0.6 ether);
        _mark();
        vm.prank(BOB);
        vault.liquidate(ALICE, 50 ether);
        vm.prank(ALICE);
        vault.depositCollateral(1);
        vm.warp(block.timestamp + 365 days);
        vm.prank(ALICE);
        vault.repayCOMP(50 ether);
        assertEq(vault.debtOf(ALICE), 5 ether);
        assertEq(vault.totalBadDebt(), 5 ether, "new fees remain recognized after dust deposit");
        assertEq(vault.totalFeesMinted(), 5 ether);
        vm.prank(ALICE);
        vault.repayCOMP(1 ether);
        assertEq(vault.debtOf(ALICE), 4 ether);
        assertEq(vault.totalBadDebt(), 4 ether, "same index cannot accrue fees twice");
        assertEq(vault.totalFeesMinted(), 5 ether);
        _assertSupply();
    }

    function test_accruedFeeRepaymentAndExitSucceedDuringDivergence() public {
        _deploy(0, 1000, 0, type(uint256).max);
        _open(ALICE, 220 ether, 100 ether);
        _work(ALICE, 10 ether);
        vm.warp(block.timestamp + 365 days);
        spot.setValue(100 ether);
        vm.prank(ALICE);
        vault.repayCOMP(110 ether);
        vm.prank(ALICE);
        vault.withdrawCollateral(220 ether);
        assertEq(vault.debtOf(ALICE), 0);
        assertEq(vault.totalFeesMinted(), 10 ether);
        _assertSupply();
    }

    function test_failedRepaymentCannotEraseAccruedFeeOrPrincipal() public {
        _deploy(0, 1000, 0, type(uint256).max);
        _open(ALICE, 220 ether, 100 ether);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(); // ALICE owns 100 COMP but owes 110.
        vm.prank(ALICE);
        vault.repayCOMP(110 ether);
        assertEq(vault.debtOf(ALICE), 110 ether);
        assertEq(vault.feeOf(ALICE), 10 ether);
        assertEq(vault.totalDebt(), 100 ether);
        assertEq(vault.totalFeesMinted(), 0);
        _assertSupply();
    }

    function testFuzz_supplyConservedThroughAccrualAndRepayment(
        uint96 principalSeed,
        uint32 timeSeed,
        uint96 paymentSeed
    ) public {
        _deploy(0, 1000, 0, type(uint256).max);
        uint256 principalDebt = bound(principalSeed, 1 ether, 1000 ether);
        _open(ALICE, 10_000 ether, principalDebt);
        _work(ALICE, 1000 ether);
        vm.warp(block.timestamp + bound(timeSeed, 1, 5 * 365 days));
        uint256 debtBefore = vault.debtOf(ALICE);
        uint256 payment = bound(paymentSeed, 1, debtBefore);
        vm.prank(ALICE);
        vault.repayCOMP(payment);
        assertEq(vault.debtOf(ALICE), debtBefore - payment);
        _assertSupply();
    }
}
