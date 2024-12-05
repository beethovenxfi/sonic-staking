// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SonicStaking} from "src/SonicStaking.sol";
import {SonicStakingTestSetup} from "./SonicStakingTestSetup.sol";

import {ISFC} from "src/interfaces/ISFC.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IAccessControl} from "openzeppelin-contracts/access/IAccessControl.sol";

contract SonicStakingTest is Test, SonicStakingTestSetup {
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    function testInitialization() public view {
        // make sure roles are set properly
        assertEq(sonicStaking.owner(), SONIC_STAKING_OWNER);
        assertTrue(sonicStaking.hasRole(sonicStaking.OPERATOR_ROLE(), SONIC_STAKING_OPERATOR));
        assertTrue(sonicStaking.hasRole(sonicStaking.DEFAULT_ADMIN_ROLE(), SONIC_STAKING_OWNER));
        assertFalse(sonicStaking.hasRole(sonicStaking.OPERATOR_ROLE(), address(this)));
        assertFalse(sonicStaking.hasRole(sonicStaking.DEFAULT_ADMIN_ROLE(), address(this)));

        // make sure addresses are set properly
        assertEq(address(sonicStaking.SFC()), address(SFC));

        // make sure initital set is set properly
        assertEq(sonicStaking.treasury(), TREASURY_ADDRESS);
        assertEq(sonicStaking.protocolFeeBIPS(), 1000);
        assertEq(sonicStaking.withdrawDelay(), 14 * 24 * 60 * 60);
        assertFalse(sonicStaking.undelegatePaused());
        assertFalse(sonicStaking.withdrawPaused());
        assertFalse(sonicStaking.depositPaused());
        assertEq(sonicStaking.totalDelegated(), 0);
        assertEq(sonicStaking.totalPool(), 0);
        assertEq(sonicStaking.totalAssets(), 0);
        assertEq(sonicStaking.getRate(), 1 ether);
        assertEq(sonicStaking.convertToShares(1 ether), 1 ether);
    }

    function testDeposit() public {
        uint256 amountAssets = 100_000 ether;
        uint256 amountShares = sonicStaking.convertToShares(amountAssets);

        assertEq(sonicStaking.totalPool(), 0);
        assertEq(sonicStaking.totalAssets(), 0);
        assertEq(sonicStaking.totalSupply(), 0);

        address user = vm.addr(200);

        vm.expectEmit(true, true, true, true);
        emit SonicStaking.Deposited(user, amountAssets, amountShares);

        makeDepositFromSpecifcUser(amountAssets, user);

        assertEq(sonicStaking.totalPool(), amountAssets);
        assertEq(sonicStaking.totalAssets(), amountAssets);

        assertEq(sonicStaking.totalSupply(), amountShares);
        assertEq(sonicStaking.balanceOf(user), amountShares);
    }

    function testMinDeposit() public {
        uint256 amountAssets = 1;
        address user = vm.addr(200);
        vm.deal(user, amountAssets);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.DepositTooSmall.selector));
        sonicStaking.deposit{value: amountAssets}();
    }

    function testDepositPaused() public {
        uint256 amountAssets = 1 ether;
        address user = vm.addr(200);

        vm.prank(SONIC_STAKING_OWNER);

        vm.expectEmit(true, true, true, true);
        emit SonicStaking.DepositPausedUpdated(address(SONIC_STAKING_OWNER), true);
        sonicStaking.setDepositPaused(true);

        assertTrue(sonicStaking.depositPaused());

        vm.deal(user, amountAssets);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.DepositPaused.selector));
        sonicStaking.deposit{value: amountAssets}();
    }

    function testDelegate() public {
        uint256 depositAmountAsset = 100_000 ether;
        uint256 delegateAmountAsset = 1_000 ether;
        uint256 validatorId = 1;

        makeDeposit(depositAmountAsset);

        vm.expectEmit(true, true, true, true);
        emit SonicStaking.Delegated(validatorId, delegateAmountAsset);

        delegate(validatorId, delegateAmountAsset);

        assertEq(sonicStaking.totalPool(), depositAmountAsset - delegateAmountAsset);
        assertEq(sonicStaking.totalDelegated(), delegateAmountAsset);
        assertEq(sonicStaking.totalAssets(), depositAmountAsset);
        assertEq(SFC.getStake(address(sonicStaking), validatorId), delegateAmountAsset);
    }

    function testMultipleDelegateToSameValidator() public {
        uint256 depositAmountAsset = 100_000 ether;
        uint256 delegateAmountAsset1 = 1_000 ether;
        uint256 delegateAmountAsset2 = 2_000 ether;
        uint256 totalDelegatedAmountAsset = delegateAmountAsset1 + delegateAmountAsset2;
        uint256 validatorId = 1;

        makeDeposit(depositAmountAsset);
        delegate(validatorId, delegateAmountAsset1);

        // need to increase time to allow for another delegation
        vm.warp(block.timestamp + 1 hours);

        // second delegation to the same validator
        delegate(validatorId, delegateAmountAsset2);

        assertEq(sonicStaking.totalDelegated(), totalDelegatedAmountAsset);
        assertEq(sonicStaking.totalAssets(), depositAmountAsset);
        assertEq(sonicStaking.totalPool(), depositAmountAsset - totalDelegatedAmountAsset);
        assertEq(SFC.getStake(address(sonicStaking), validatorId), totalDelegatedAmountAsset);
    }

    function testMultipleDelegateToDifferentValidator() public {
        uint256 depositAmountAsset = 100_000 ether;
        uint256 delegateAmountAsset1 = 1_000 ether;
        uint256 delegateAmountAsset2 = 5_000 ether;
        uint256 validatorId1 = 1;
        uint256 validatorId2 = 2;

        makeDeposit(depositAmountAsset);
        delegate(validatorId1, delegateAmountAsset1);

        // need to increase time to allow for another delegation
        vm.warp(block.timestamp + 1 hours);

        // second delegation to a different validator
        delegate(validatorId2, delegateAmountAsset2);

        assertEq(sonicStaking.totalDelegated(), delegateAmountAsset1 + delegateAmountAsset2);
        assertEq(sonicStaking.totalAssets(), depositAmountAsset);
        assertEq(sonicStaking.totalPool(), depositAmountAsset - delegateAmountAsset1 - delegateAmountAsset2);
        assertEq(SFC.getStake(address(sonicStaking), validatorId1), delegateAmountAsset1);
        assertEq(SFC.getStake(address(sonicStaking), validatorId2), delegateAmountAsset2);
    }

    function testDelegateErrors() public {
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.DelegateAmountCannotBeZero.selector));
        delegate(1, 0);

        vm.expectRevert(abi.encodeWithSelector(SonicStaking.DelegateAmountLargerThanPool.selector));
        delegate(1, 100 ether);
    }

    function testUndelegate() public {
        uint256 amount = 1000 ether;
        uint256 amountShares = sonicStaking.convertToShares(amount);
        uint256 validatorId = 1;

        address user = makeDeposit(amount);
        delegate(validatorId, amount);

        uint256 userSharesBefore = sonicStaking.balanceOf(user);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(user, address(0), amountShares);

        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit SonicStaking.Undelegated(user, 101, validatorId, amount, SonicStaking.WithdrawKind.VALIDATOR);
        uint256 withdrawId = sonicStaking.undelegate(validatorId, amountShares);

        assertEq(sonicStaking.balanceOf(user), userSharesBefore - amountShares);
        assertEq(sonicStaking.totalDelegated(), 0);
        assertEq(sonicStaking.totalAssets(), 0);

        SonicStaking.WithdrawRequest memory withdrawRequest = sonicStaking.getWithdrawRequest(withdrawId);

        assertEq(withdrawRequest.assetAmount, amount);
        assertEq(withdrawRequest.isWithdrawn, false);
        assertEq(withdrawRequest.user, user);
        assertEq(withdrawRequest.validatorId, validatorId);
    }

    function testPartialUndelegate() public {
        uint256 amount = 1000 ether;
        // we undelegate 250 of the 1000 deposited
        uint256 undelegateAmount = 250 ether;
        uint256 undelegateAmountShares = sonicStaking.convertToShares(undelegateAmount);
        uint256 undelegateAmountAssets = sonicStaking.convertToAssets(undelegateAmountShares);
        uint256 validatorId = 1;

        address user = makeDeposit(amount);

        delegate(validatorId, amount);

        uint256 userSharesBefore = sonicStaking.balanceOf(user);

        vm.prank(user);
        uint256 withdrawId = sonicStaking.undelegate(validatorId, undelegateAmountShares);

        assertEq(sonicStaking.balanceOf(user), userSharesBefore - undelegateAmountShares);
        assertEq(sonicStaking.totalDelegated(), amount - undelegateAmountAssets);
        assertEq(sonicStaking.totalAssets(), amount - undelegateAmountAssets);
        assertEq(sonicStaking.totalPool(), 0);

        SonicStaking.WithdrawRequest memory withdrawRequest = sonicStaking.getWithdrawRequest(withdrawId);

        assertEq(withdrawRequest.assetAmount, undelegateAmount);
    }

    function testSeveralUndelegatesFromValidator() public {
        uint256 validatorId = 1;
        uint256 amount = 1000 ether;
        address user = makeDeposit(amount);

        delegate(validatorId, amount);

        uint256 userSharesBefore = sonicStaking.balanceOf(user);
        uint256 undelegateAmount = 20 ether;
        uint256 undelegateAmountShares = sonicStaking.convertToShares(undelegateAmount);
        uint256 totalUndelegated = 0;
        uint256 totalSharesBurned = 0;

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(user);
            sonicStaking.undelegate(validatorId, undelegateAmountShares);

            totalUndelegated += undelegateAmount;
            totalSharesBurned += undelegateAmountShares;

            assertEq(sonicStaking.totalDelegated(), amount - totalUndelegated);
            assertEq(sonicStaking.balanceOf(user), userSharesBefore - totalSharesBurned);
        }
    }

    function testUndelegatePaused() public {
        uint256 amountAssets = 1 ether;

        vm.prank(SONIC_STAKING_OWNER);

        vm.expectEmit(true, true, true, true);
        emit SonicStaking.UndelegatePausedUpdated(address(SONIC_STAKING_OWNER), true);
        sonicStaking.setUndelegatePaused(true);

        assertTrue(sonicStaking.undelegatePaused());

        vm.prank(SONIC_STAKING_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.UndelegatePaused.selector));
        sonicStaking.undelegate(1, amountAssets);
    }

    function testUndelegateFromPool() public {
        uint256 depositAmountAsset = 100_000 ether;
        uint256 undelegateAmountShares = 10_000 ether;
        uint256 undelegateAmountAssets = sonicStaking.convertToAssets(undelegateAmountShares);

        address user = makeDeposit(depositAmountAsset);

        uint256 userSharesBefore = sonicStaking.balanceOf(user);

        vm.prank(user);
        sonicStaking.undelegateFromPool(undelegateAmountShares);

        SonicStaking.WithdrawRequest memory withdraw = sonicStaking.getWithdrawRequest(sonicStaking.withdrawCounter());

        assertEq(withdraw.validatorId, 0);
        assertEq(withdraw.requestTimestamp, block.timestamp);
        assertEq(withdraw.user, user);
        assertEq(withdraw.isWithdrawn, false);
        assertEq(withdraw.assetAmount, undelegateAmountAssets);

        assertEq(sonicStaking.totalPool(), depositAmountAsset - undelegateAmountAssets);
        assertEq(sonicStaking.balanceOf(user), userSharesBefore - undelegateAmountShares);
    }

    function testUndelegateTooMuchFromValidator() public {
        uint256 depositAmountAsset = 10_000 ether;
        uint256 delegateAmountAsset1 = 5_000 ether;
        uint256 delegateAmountAsset2 = 3_000 ether;
        uint256 undelegateAmountShares = sonicStaking.convertToShares(6_000 ether);
        uint256 toValidatorId1 = 1;
        uint256 toValidatorId2 = 2;

        address user = makeDeposit(depositAmountAsset);

        delegate(toValidatorId1, delegateAmountAsset1);
        delegate(toValidatorId2, delegateAmountAsset2);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.UndelegateAmountExceedsDelegated.selector));
        sonicStaking.undelegate(toValidatorId2, undelegateAmountShares);
    }

    function testStateSetters() public {
        vm.startPrank(SONIC_STAKING_OWNER);

        sonicStaking.setWithdrawDelay(1);
        assertEq(sonicStaking.withdrawDelay(), 1);

        sonicStaking.setUndelegatePaused(true);
        assertTrue(sonicStaking.undelegatePaused());

        sonicStaking.setWithdrawPaused(true);
        assertTrue(sonicStaking.withdrawPaused());

        sonicStaking.setDepositPaused(true);
        assertTrue(sonicStaking.depositPaused());

        sonicStaking.setProtocolFeeBIPS(100);
        assertEq(sonicStaking.protocolFeeBIPS(), 100);

        sonicStaking.setTreasury(address(this));
        assertEq(sonicStaking.treasury(), address(this));
    }

    function testStateSettersRevert() public {
        vm.startPrank(SONIC_STAKING_OWNER);

        vm.expectRevert(abi.encodeWithSelector(SonicStaking.PausedValueDidNotChange.selector));
        sonicStaking.setUndelegatePaused(false);

        vm.expectRevert(abi.encodeWithSelector(SonicStaking.PausedValueDidNotChange.selector));
        sonicStaking.setUndelegatePaused(false);

        vm.expectRevert(abi.encodeWithSelector(SonicStaking.PausedValueDidNotChange.selector));
        sonicStaking.setWithdrawPaused(false);

        vm.expectRevert(abi.encodeWithSelector(SonicStaking.ProtocolFeeTooHigh.selector));
        sonicStaking.setProtocolFeeBIPS(10001);

        vm.expectRevert(abi.encodeWithSelector(SonicStaking.TreasuryAddressCannotBeZero.selector));
        sonicStaking.setTreasury(address(0));
    }

    function testUserWithdraws() public {
        uint256 amount = 1000 ether;
        uint256 validatorId = 1;
        uint256 undelegateAmount1 = 100 ether;
        uint256 undelegateAmount2 = 200 ether;
        uint256 undelegateAmount3 = 300 ether;
        address user = makeDeposit(amount);

        delegate(validatorId, amount);

        // Create 3 undelegate requests
        uint256[] memory validatorIds = new uint256[](3);
        uint256[] memory undelegateAmountShares = new uint256[](3);

        validatorIds[0] = validatorId;
        validatorIds[1] = validatorId;
        validatorIds[2] = validatorId;

        undelegateAmountShares[0] = undelegateAmount1;
        undelegateAmountShares[1] = undelegateAmount2;
        undelegateAmountShares[2] = undelegateAmount3;

        vm.prank(user);
        sonicStaking.undelegateMany(validatorIds, undelegateAmountShares);

        // Test getting all withdraws
        SonicStaking.WithdrawRequest[] memory withdraws = sonicStaking.getUserWithdraws(user, 0, 3, false);
        assertEq(withdraws.length, 3);
        assertEq(withdraws[0].assetAmount, undelegateAmount1);
        assertEq(withdraws[1].assetAmount, undelegateAmount2);
        assertEq(withdraws[2].assetAmount, undelegateAmount3);

        // Test pagination
        withdraws = sonicStaking.getUserWithdraws(user, 1, 2, false);
        assertEq(withdraws.length, 2);
        assertEq(withdraws[0].assetAmount, undelegateAmount2);
        assertEq(withdraws[1].assetAmount, undelegateAmount3);

        // Test reverse order
        withdraws = sonicStaking.getUserWithdraws(user, 0, 3, true);
        assertEq(withdraws.length, 3);
        assertEq(withdraws[0].assetAmount, undelegateAmount3);
        assertEq(withdraws[1].assetAmount, undelegateAmount2);
        assertEq(withdraws[2].assetAmount, undelegateAmount1);

        // Test reverse order with pagination
        withdraws = sonicStaking.getUserWithdraws(user, 1, 2, true);
        assertEq(withdraws.length, 2);
        assertEq(withdraws[0].assetAmount, undelegateAmount2);
        assertEq(withdraws[1].assetAmount, undelegateAmount1);
    }

    function testInvalidWithdrawId() public {
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.WithdrawIdDoesNotExist.selector));
        sonicStaking.withdraw(0, false);
    }

    function testWithdrawTooEarly() public {
        uint256 assetAmount = 10_000 ether;
        uint256 delegateAmount = 10_000 ether;
        uint256 undelegateAmount = 10_000 ether;
        uint256 validatorId = 1;

        address user = makeDeposit(assetAmount);
        delegate(validatorId, delegateAmount);

        vm.prank(user);
        sonicStaking.undelegate(validatorId, undelegateAmount);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                SonicStaking.WithdrawDelayNotElapsed.selector, block.timestamp + sonicStaking.withdrawDelay()
            )
        );
        sonicStaking.withdraw(101, false);
    }

    function testUndelegateMany() public {
        uint256 assetAmount = 10_000 ether;
        uint256 delegateAmount1 = 5_000 ether;
        uint256 delegateAmount2 = 5_000 ether;
        uint256 undelegateAmount1 = 5_000 ether;
        uint256 undelegateAmount2 = 5_000 ether;
        uint256 validatorId1 = 1;
        uint256 validatorId2 = 2;

        address user = makeDeposit(assetAmount);

        delegate(validatorId1, delegateAmount1);
        delegate(validatorId2, delegateAmount2);

        uint256 userSharesBefore = sonicStaking.balanceOf(user);

        uint256[] memory validatorIds = new uint256[](2);
        validatorIds[0] = 1;
        validatorIds[1] = 2;

        uint256[] memory amountShares = new uint256[](2);
        amountShares[0] = undelegateAmount1;
        amountShares[1] = undelegateAmount2;

        uint256 undelegateAmountAssets1 = sonicStaking.convertToAssets(undelegateAmount1);
        uint256 undelegateAmountAssets2 = sonicStaking.convertToAssets(undelegateAmount2);

        vm.prank(user);
        uint256[] memory withdrawIds = sonicStaking.undelegateMany(validatorIds, amountShares);
        assertEq(sonicStaking.withdrawCounter(), 102);

        assertEq(sonicStaking.balanceOf(user), userSharesBefore - (undelegateAmount1 + undelegateAmount2));
        assertEq(sonicStaking.totalDelegated(), 0);
        assertEq(sonicStaking.totalAssets(), 0);

        SonicStaking.WithdrawRequest memory withdraw1 = sonicStaking.getWithdrawRequest(withdrawIds[0]);

        assertEq(withdraw1.assetAmount, undelegateAmountAssets1);
        assertEq(withdraw1.isWithdrawn, false);
        assertEq(withdraw1.user, user);
        assertEq(withdraw1.validatorId, validatorId1);

        SonicStaking.WithdrawRequest memory withdraw2 = sonicStaking.getWithdrawRequest(withdrawIds[1]);

        assertEq(withdraw2.assetAmount, undelegateAmountAssets2);
        assertEq(withdraw2.isWithdrawn, false);
        assertEq(withdraw2.user, user);
        assertEq(withdraw2.validatorId, validatorId2);
    }

    function testPause() public {
        assertTrue(sonicStaking.hasRole(sonicStaking.OPERATOR_ROLE(), SONIC_STAKING_OPERATOR));

        vm.startPrank(SONIC_STAKING_OPERATOR);

        sonicStaking.pause();
        assertTrue(sonicStaking.undelegatePaused());
        assertTrue(sonicStaking.withdrawPaused());
        assertTrue(sonicStaking.depositPaused());

        vm.stopPrank();
    }

    function testDonate() public {
        uint256 assetAmount = 10_000 ether;
        uint256 donationAmount = 100 ether;

        makeDeposit(assetAmount);

        vm.deal(SONIC_STAKING_OPERATOR, donationAmount);
        vm.startPrank(SONIC_STAKING_OPERATOR);

        sonicStaking.donate{value: donationAmount}();

        assertEq(sonicStaking.totalPool(), assetAmount + donationAmount);
    }

    function testDonateError() public {
        vm.deal(SONIC_STAKING_OPERATOR, 100 ether);

        address user = makeDeposit(100 ether);
        vm.deal(user, 100 ether);

        vm.prank(SONIC_STAKING_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.DonationAmountCannotBeZero.selector));
        sonicStaking.donate{value: 0}();

        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, user, sonicStaking.OPERATOR_ROLE())
        );
        sonicStaking.donate{value: 100 ether}();
    }

    function testRateGrowth() public {
        uint256 assetAmount = 1_000 ether;

        address user = makeDeposit(assetAmount);

        assertEq(sonicStaking.getRate(), 1 ether);
        assertEq(sonicStaking.convertToAssets(1 ether), 1 ether);
        assertEq(sonicStaking.convertToShares(1 ether), 1 ether);

        donate(100 ether);
        assertEq(sonicStaking.getRate(), 1.1 ether);
        assertEq(sonicStaking.convertToAssets(1 ether), 1.1 ether);
        assertEq(sonicStaking.convertToShares(1.1 ether), 1 ether);

        donate(200 ether);
        assertEq(sonicStaking.getRate(), 1.3 ether);
        assertEq(sonicStaking.convertToAssets(1 ether), 1.3 ether);
        assertEq(sonicStaking.convertToShares(1.3 ether), 1 ether);

        uint256 finalRate = 1.8 ether;
        donate(500 ether);
        assertEq(sonicStaking.getRate(), finalRate);
        assertEq(sonicStaking.convertToAssets(1 ether), finalRate);
        assertEq(sonicStaking.convertToShares(finalRate), 1 ether);

        // delegation should not impact the rate
        delegate(1, 400 ether);
        assertEq(sonicStaking.getRate(), finalRate);
        assertEq(sonicStaking.convertToAssets(1 ether), finalRate);
        assertEq(sonicStaking.convertToShares(finalRate), 1 ether);

        // undelegation should not impact the rate
        vm.prank(user);
        sonicStaking.undelegate(1, 200 ether);
        assertEq(sonicStaking.getRate(), finalRate);
        assertEq(sonicStaking.convertToAssets(1 ether), finalRate);
        assertEq(sonicStaking.convertToShares(finalRate), 1 ether);
    }

    function testUndelegateToPoolRevert() public {
        vm.prank(SONIC_STAKING_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.UndelegateAmountCannotBeZero.selector));
        sonicStaking.operatorUndelegateToPool(1, 0);

        makeDeposit(100 ether);
        delegate(1, 100 ether);

        vm.prank(SONIC_STAKING_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.NoDelegationForValidator.selector, 2));
        sonicStaking.operatorUndelegateToPool(2, 100 ether);

        vm.prank(SONIC_STAKING_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.UndelegateAmountExceedsDelegated.selector));
        sonicStaking.operatorUndelegateToPool(1, 1000 ether);
    }
}
