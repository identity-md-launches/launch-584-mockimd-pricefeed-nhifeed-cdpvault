// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {APPROVED_OPERATOR, FEE_RECIPIENT} from "../src/DeploymentConfig.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";

contract CDPVaultRevisionTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    MockIMD private imd;
    TestSwarmFeed private primary;
    TestSwarmFeed private spot;
    TestSwarmFeed private nhi;
    CDPVault private vault;
    CompToken private comp;
    MockWorkOracle private oracle;

    function setUp() public {
        vm.warp(10 days);
        imd = new MockIMD();
        primary = new TestSwarmFeed(1 ether);
        spot = new TestSwarmFeed(1 ether);
        nhi = new TestSwarmFeed(0.85 ether);
        _deploy(0);
    }

    function _deploy(uint256 rate) private {
        vault = new CDPVault(
            address(imd), address(0), address(0), address(primary), address(nhi), address(spot), 500, 1000, rate
        );
        comp = vault.compToken();
        oracle = MockWorkOracle(address(vault.oracle()));
        vm.prank(APPROVED_OPERATOR);
        imd.mint(ALICE, 1000 ether);
        vm.prank(ALICE);
        imd.approve(address(vault), type(uint256).max);
    }

    function _open(uint256 collateral, uint256 debt) private {
        vm.startPrank(ALICE);
        vault.depositCollateral(collateral);
        vault.mintCOMP(debt);
        vm.stopPrank();
    }

    function _work(address user, uint256 amount) private {
        vm.prank(APPROVED_OPERATOR);
        oracle.grantRights(user, amount);
        vm.prank(user);
        vault.mintFromWork(amount);
    }

    function _liquidate(uint256 price, uint256 repayment) private {
        primary.setValue(price);
        spot.setValue(price);
        nhi.setValue(0.6 ether);
        vault.markUnderwater(ALICE);
        vm.prank(BOB);
        vault.liquidate(ALICE, repayment);
    }

    function test_dustShortfallAccruesAndOnlyPaymentReducesRecord() public {
        _deploy(1000);
        _open(220 ether + 2, 100 ether);
        _work(BOB, 100 ether);
        _liquidate(0.25 ether, 50 ether);
        assertEq(vault.recordedBadDebtOf(ALICE), 50 ether);
        assertEq(vault.totalBadDebt(), 50 ether);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vm.prank(BOB);
        vault.liquidate(ALICE, 1);

        vm.warp(10 days + 365 days);
        assertEq(vault.badDebtOf(ALICE), 55 ether);
        assertEq(vault.totalBadDebt(), 50 ether, "time alone is not a checkpoint");
        vm.prank(ALICE);
        vault.depositCollateral(1);
        assertEq(vault.totalBadDebt(), 50 ether, "deposit cannot erase a record");
        vm.prank(ALICE);
        vault.repayCOMP(1 ether);
        assertEq(vault.totalBadDebt(), 54 ether, "checkpoint fees, then deduct payment");
        assertEq(vault.recordedBadDebtOf(ALICE), 54 ether);
        vm.prank(ALICE);
        vault.repayAllCOMP();
        assertEq(vault.totalBadDebt(), 0);
        assertEq(vault.recordedBadDebtOf(ALICE), 0);
        assertEq(vault.debtOf(ALICE), 0);
        assertEq(comp.balanceOf(FEE_RECIPIENT), 5 ether);
        assertEq(comp.totalSupply(), vault.totalDebt() + vault.totalWorkMinted());
        vm.prank(ALICE);
        vault.withdrawCollateral(3);
    }

    function test_floorPayoutBoundaryDoesNotRecognizeStillExecutableDebt() public {
        _open(220 ether + 4, 100 ether);
        _work(BOB, 100 ether);
        _liquidate(0.25 ether, 50 ether);
        (uint256 collateral,) = vault.positions(ALICE);
        assertEq(collateral, 4);
        assertEq(vault.recordedBadDebtOf(ALICE), 0, "floor payout of four still fits");
        assertEq(vault.totalBadDebt(), 0);
        vm.prank(BOB);
        vault.liquidate(ALICE, 1);
        assertEq(vault.recordedBadDebtOf(ALICE), 50 ether - 1);
        assertEq(vault.totalBadDebt(), 50 ether - 1);
    }

    function testFuzz_maximumExecutableLiquidationRecordsRemainder(uint64 priceSeed, uint64 dustSeed) public {
        uint256 price = bound(priceSeed, 1, 0.5 ether);
        uint256 collateral = 300 ether + bound(dustSeed, 0, 1 ether);
        uint256 repayment = Math.mulDiv(collateral + 1, price, 1.1 ether, Math.Rounding.Ceil) - 1;
        _open(collateral, 200 ether);
        _work(BOB, 200 ether);
        _liquidate(price, repayment);
        (uint256 remaining, uint256 debt) = vault.positions(ALICE);
        assertEq(debt, 200 ether - repayment);
        assertEq(remaining, collateral - Math.mulDiv(repayment, 1.1 ether, price));
        // Flooring is not additive: a maximum first repayment can leave enough dust for another
        // one-wei repayment. Recognize only once the actual remaining payout no longer fits.
        if (remaining >= 1.1 ether / price) {
            vm.prank(BOB);
            vault.liquidate(ALICE, 1);
            debt -= 1;
        }
        assertEq(vault.badDebtOf(ALICE), debt);
        assertEq(vault.recordedBadDebtOf(ALICE), debt);
        assertEq(vault.totalBadDebt(), debt);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vm.prank(BOB);
        vault.liquidate(ALICE, 1);
    }

    function test_repayAllUsesExecutionTimeDebtAndAllowsExitDuringDivergence() public {
        _deploy(1000);
        _open(300 ether, 100 ether);
        _work(ALICE, 11 ether);
        vm.warp(10 days + 365 days);
        uint256 quote = vault.debtOf(ALICE);
        vm.warp(10 days + 365 days + 12);
        uint256 liveDebt = vault.debtOf(ALICE);
        assertGt(liveDebt, quote);
        spot.setValue(2 ether);
        uint256 before = comp.balanceOf(ALICE);
        vm.prank(ALICE);
        vault.repayAllCOMP();
        assertEq(before - comp.balanceOf(ALICE), liveDebt);
        assertEq(vault.debtOf(ALICE), 0);
        assertEq(vault.feeOf(ALICE), 0);
        assertEq(comp.balanceOf(FEE_RECIPIENT), liveDebt - 100 ether);
        assertEq(comp.totalSupply(), vault.totalWorkMinted());
        vm.prank(ALICE);
        vault.withdrawCollateral(300 ether);
        vm.warp(10 days + 2 * 365 days);
        assertEq(vault.debtOf(ALICE), 0);
    }

    function test_repayAllWithStaleFeedsAndZeroRate() public {
        _open(300 ether, 100 ether);
        primary.setStale(true);
        spot.setStale(true);
        nhi.setStale(true);
        vm.prank(ALICE);
        vault.repayAllCOMP();
        assertEq(vault.debtOf(ALICE), 0);
        assertEq(comp.balanceOf(ALICE), 0);
        assertEq(vault.totalFeesMinted(), 0);
        vm.prank(ALICE);
        vault.withdrawCollateral(300 ether);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vm.prank(ALICE);
        vault.repayAllCOMP();
    }

    function test_failedRepayAllRollsBackFeeAndPrincipal() public {
        _deploy(1000);
        _open(300 ether, 100 ether);
        vm.warp(10 days + 365 days);
        uint256 index = vault.debtIndexOf(ALICE);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", ALICE, 100 ether, 110 ether)
        );
        vm.prank(ALICE);
        vault.repayAllCOMP();
        assertEq(vault.debtOf(ALICE), 110 ether);
        assertEq(vault.feeOf(ALICE), 10 ether);
        assertEq(vault.totalDebt(), 100 ether);
        assertEq(vault.debtIndexOf(ALICE), index);
        assertEq(vault.totalFeesMinted(), 0);
        assertEq(comp.totalSupply(), 100 ether);
    }

    function test_explicitRepaymentStillRejectsExcess() public {
        _deploy(1000);
        _open(300 ether, 100 ether);
        _work(ALICE, 11 ether);
        vm.warp(10 days + 365 days + 12);
        uint256 debt = vault.debtOf(ALICE);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vm.prank(ALICE);
        vault.repayCOMP(debt + 1);
        assertEq(vault.debtOf(ALICE), debt);
    }
}
