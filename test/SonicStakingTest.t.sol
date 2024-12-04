// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SonicStaking} from "src/SonicStaking.sol";
import {SonicStakingTestSetup} from "./SonicStakingTestSetup.sol";

import {ISFC} from "src/interfaces/ISFC.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract SonicStakingTest is Test, SonicStakingTestSetup {
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

    function testUndelegateFromValidator() public {
        uint256 amount = 1000 ether;
        uint256 amountShares = sonicStaking.convertToShares(amount);
        uint256 validatorId = 1;

        address user = makeDeposit(amount);
        delegate(validatorId, amount);

        uint256 userSharesBefore = sonicStaking.balanceOf(user);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(user, address(0), amountShares);

        // TODO: come back to this, can't get it to work
        //vm.expectEmit(false, false, false, true);
        //emit SonicStaking.Undelegated(user, 0, validatorId, amount, SonicStaking.WithdrawKind.VALIDATOR);

        vm.prank(user);
        uint256 withdrawId = sonicStaking.undelegate(validatorId, amountShares);

        assertEq(sonicStaking.balanceOf(user), userSharesBefore - amountShares);
        assertEq(sonicStaking.totalDelegated(), 0);
        assertEq(sonicStaking.totalAssets(), 0);

        (, uint256 valId, uint256 assetAmount, bool isWithdrawn,, address userAddress) =
            sonicStaking.allWithdrawRequests(withdrawId);

        assertEq(assetAmount, amount);
        assertEq(isWithdrawn, false);
        assertEq(userAddress, user);
        assertEq(valId, validatorId);
    }

    function testPartialUndelegateFromValidator() public {
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

        // do not explode this struct, if we add a new var in the struct, everything breaks
        (,, uint256 assetAmount,,,) = sonicStaking.allWithdrawRequests(withdrawId);

        assertEq(assetAmount, undelegateAmount);
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

    function testUndelegateFromPool() public {
        uint256 depositAmountAsset = 100_000 ether;
        uint256 undelegateAmountShares = 10_000 ether;
        uint256 undelegateAmountAssets = sonicStaking.convertToAssets(undelegateAmountShares);

        address user = makeDeposit(depositAmountAsset);

        uint256 userSharesBefore = sonicStaking.balanceOf(user);

        vm.prank(user);
        sonicStaking.undelegateFromPool(undelegateAmountShares);

        (, uint256 validatorId, uint256 amount, bool isWithdrawn, uint256 requestTimestamp, address userAddress) =
            sonicStaking.allWithdrawRequests(sonicStaking.withdrawCounter());
        assertEq(validatorId, 0);
        assertEq(requestTimestamp, block.timestamp);
        assertEq(userAddress, user);
        assertEq(isWithdrawn, false);
        assertEq(amount, undelegateAmountAssets);

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
}
