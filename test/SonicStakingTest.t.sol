// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SonicStaking} from "src/SonicStaking.sol";
import {SonicStakingTestSetup} from "./SonicStakingTestSetup.sol";

import {ISFC} from "src/interfaces/ISFC.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

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
        uint256 depositAmountAsset = 100_000 ether;

        address user = makeDeposit(depositAmountAsset);
        assertEq(sonicStaking.totalPool(), depositAmountAsset);
        assertEq(sonicStaking.totalAssets(), depositAmountAsset);

        assertEq(sonicStaking.getRate(), 1 ether);
        // user gets the same amount of shares because rate is 1.
        assertEq(sonicStaking.balanceOf(user), depositAmountAsset);
    }

    function testDelegate() public {
        uint256 depositAmountAsset = 100_000 ether;
        uint256 delegateAssetAmount = 1_000 ether;
        uint256 toValidatorId = 2;

        uint256 rateBefore = sonicStaking.getRate();

        makeDeposit(depositAmountAsset);
        delegate(delegateAssetAmount, toValidatorId);

        assertEq(sonicStaking.totalPool(), depositAmountAsset - delegateAssetAmount);
        assertEq(sonicStaking.totalDelegated(), delegateAssetAmount);
        assertEq(sonicStaking.totalAssets(), depositAmountAsset);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId), delegateAssetAmount);

        // No rate change as there is no reward claimed yet
        assertEq(sonicStaking.getRate(), rateBefore);
    }

    function testMultipleDelegateToSameValidator() public {
        uint256 depositAmountAsset = 100_000 ether;
        uint256 delegateAssetAmount = 1_000 ether;
        uint256 toValidatorId = 1;

        makeDeposit(depositAmountAsset);
        delegate(delegateAssetAmount, toValidatorId);

        // need to increase time to allow for another delegation
        vm.warp(block.timestamp + 1 hours);

        // second delegation to the same validator
        delegate(delegateAssetAmount, toValidatorId);

        assertEq(sonicStaking.totalDelegated(), delegateAssetAmount * 2);
        assertEq(sonicStaking.totalAssets(), depositAmountAsset);
        assertEq(sonicStaking.totalPool(), depositAmountAsset - delegateAssetAmount * 2);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId), delegateAssetAmount * 2);
    }

    function testMultipleDelegateToDifferentValidator() public {
        uint256 depositAmountAsset = 100_000 ether;
        uint256 delegateAmountAsset1 = 1_000 ether;
        uint256 delegateAmountAsset2 = 5_000 ether;
        uint256 toValidatorId1 = 1;
        uint256 toValidatorId2 = 2;

        makeDeposit(depositAmountAsset);
        delegate(delegateAmountAsset1, toValidatorId1);

        // need to increase time to allow for another delegation
        vm.warp(block.timestamp + 1 hours);

        // second delegation to a different validator
        delegate(delegateAmountAsset2, toValidatorId2);

        assertEq(sonicStaking.totalDelegated(), delegateAmountAsset1 + delegateAmountAsset2);
        assertEq(sonicStaking.totalAssets(), depositAmountAsset);
        assertEq(sonicStaking.totalPool(), depositAmountAsset - delegateAmountAsset1 - delegateAmountAsset2);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId1), delegateAmountAsset1);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId2), delegateAmountAsset2);
    }

    function testUndelegateFromPool() public {
        uint256 depositAmountAsset = 100_000 ether;
        uint256 undelegateAmountShares = 10_000 ether;

        address user = makeDeposit(depositAmountAsset);

        uint256 userSharesBefore = sonicStaking.balanceOf(user);

        uint256 assetsToReceive = sonicStaking.convertToAssets(undelegateAmountShares);
        vm.prank(user);
        sonicStaking.undelegateFromPool(undelegateAmountShares);

        (, uint256 validatorId, uint256 amountS, bool isWithdrawn, uint256 requestTimestamp, address userAddress) =
            sonicStaking.allWithdrawRequests(sonicStaking.withdrawCounter());
        assertEq(validatorId, 0);
        assertEq(requestTimestamp, block.timestamp);
        assertEq(userAddress, user);
        assertEq(isWithdrawn, false);
        assertEq(amountS, undelegateAmountShares);

        assertEq(sonicStaking.totalPool(), depositAmountAsset - assetsToReceive);
        assertEq(sonicStaking.balanceOf(user), userSharesBefore - undelegateAmountShares);
    }

    function testUndelegateTooMuchFromValidator() public {
        uint256 depositAmountAsset = 10_000 ether;
        uint256 delegateAmountAsset1 = 5_000 ether;
        uint256 delegateAmountAsset2 = 3_000 ether;
        uint256 undelegateAmountShares = 6_000 ether;
        uint256 toValidatorId1 = 1;
        uint256 toValidatorId2 = 2;

        address user = makeDeposit(depositAmountAsset);

        delegate(delegateAmountAsset1, toValidatorId1);
        delegate(delegateAmountAsset2, toValidatorId2);

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

    function testUndelegateFromValidator() public {
        uint256 amount = 1000 ether;
        uint256 amountShares = sonicStaking.convertToShares(amount);
        uint256 validatorId = 1;

        address user = makeDeposit(amount);
        delegate(amount, validatorId);

        uint256 userSharesBefore = sonicStaking.balanceOf(user);

        vm.prank(user);
        uint256 withdrawId = sonicStaking.undelegate(validatorId, amountShares);

        assertEq(sonicStaking.balanceOf(user), userSharesBefore - amountShares);
        assertEq(sonicStaking.totalDelegated(), 0);
        assertEq(sonicStaking.totalAssets(), 0);
        assertEq(sonicStaking.totalPool(), 0);

        // do not explode this struct, if we add a new var in the struct, everything breaks
        (, uint256 valId, uint256 assetAmount, bool isWithdrawn,, address userAddress) =
            sonicStaking.allWithdrawRequests(withdrawId);

        assertEq(assetAmount, amount);
        assertEq(isWithdrawn, false);
        assertEq(userAddress, user);
        // assertEq(kind, SonicStaking.WithdrawKind.VALIDATOR);
        assertEq(valId, validatorId);
    }

    function testPartialUndelegateFromValidator() public {
        uint256 amount = 1000 ether;
        // we undelegate 250 of the 1000 deposited
        uint256 undelegateAmount = 250 ether;
        uint256 undelegateAmountShares = sonicStaking.convertToShares(undelegateAmount);
        uint256 undelegateAmountAssets = sonicStaking.convertToAssets(undelegateAmountShares);
        console.log("undelegateAmountShares", undelegateAmountShares);
        console.log("undelegateAmountAssets", undelegateAmountAssets);
        uint256 validatorId = 1;

        address user = makeDeposit(amount);

        delegate(amount, validatorId);

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

    function testUserWithdraws() public {
        uint256 amount = 1000 ether;
        uint256 validatorId = 1;
        uint256 undelegateAmount1 = 100 ether;
        uint256 undelegateAmount2 = 200 ether;
        uint256 undelegateAmount3 = 300 ether;
        address user = makeDeposit(amount);

        delegate(amount, validatorId);

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
