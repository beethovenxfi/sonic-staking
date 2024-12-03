// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

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
        uint256 depositAssetAmount = 100_000 ether;

        address user = makeDeposit(depositAssetAmount);
        assertEq(sonicStaking.totalPool(), depositAssetAmount);
        assertEq(sonicStaking.totalAssets(), depositAssetAmount);

        assertEq(sonicStaking.getRate(), 1 ether);
        // user gets the same amount of shares because rate is 1.
        assertEq(sonicStaking.balanceOf(user), depositAssetAmount);
    }

    function testDelegate() public {
        uint256 depositAssetAmount = 100_000 ether;
        uint256 delegateAssetAmount = 1_000 ether;
        uint256 toValidatorId = 1;

        uint256 rateBefore = sonicStaking.getRate();

        makeDeposit(depositAssetAmount);
        delegate(delegateAssetAmount, toValidatorId);

        assertEq(sonicStaking.totalPool(), depositAssetAmount - delegateAssetAmount);
        assertEq(sonicStaking.totalDelegated(), delegateAssetAmount);
        assertEq(sonicStaking.totalAssets(), depositAssetAmount);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId), delegateAssetAmount);

        // No rate change as there is no reward claimed yet
        assertEq(sonicStaking.getRate(), rateBefore);
    }

    function testMultipleDelegateToSameValidator() public {
        uint256 depositAssetAmount = 100_000 ether;
        uint256 delegateAssetAmount = 1_000 ether;
        uint256 toValidatorId = 1;

        makeDeposit(depositAssetAmount);
        delegate(delegateAssetAmount, toValidatorId);

        // need to increase time to allow for another delegation
        vm.warp(block.timestamp + 1 hours);

        // second delegation to the same validator
        delegate(delegateAssetAmount, toValidatorId);

        assertEq(sonicStaking.totalDelegated(), delegateAssetAmount * 2);
        assertEq(sonicStaking.totalAssets(), depositAssetAmount);
        assertEq(sonicStaking.totalPool(), depositAssetAmount - delegateAssetAmount * 2);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId), delegateAssetAmount * 2);
    }

    function testMultipleDelegateToDifferentValidator() public {
        uint256 depositAssetAmount = 100_000 ether;
        uint256 delegateAssetAmount1 = 1_000 ether;
        uint256 delegateAssetAmount2 = 5_000 ether;
        uint256 toValidatorId1 = 1;
        uint256 toValidatorId2 = 2;

        makeDeposit(depositAssetAmount);
        delegate(delegateAssetAmount1, toValidatorId1);

        // need to increase time to allow for another delegation
        vm.warp(block.timestamp + 1 hours);

        // second delegation to a different validator
        delegate(delegateAssetAmount2, toValidatorId2);

        assertEq(sonicStaking.totalDelegated(), delegateAssetAmount1 + delegateAssetAmount2);
        assertEq(sonicStaking.totalAssets(), depositAssetAmount);
        assertEq(sonicStaking.totalPool(), depositAssetAmount - delegateAssetAmount1 - delegateAssetAmount2);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId1), delegateAssetAmount1);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId2), delegateAssetAmount2);
    }

    function testUndelegateFromPool() public {
        uint256 depositAssetAmount = 100_000 ether;
        uint256 undelegateSharesAmount = 10_000 ether;

        address user = makeDeposit(depositAssetAmount);

        uint256 userSharesBefore = sonicStaking.balanceOf(user);

        uint256 assetsToReceive = sonicStaking.convertToAssets(undelegateSharesAmount);
        vm.prank(user);
        sonicStaking.undelegateFromPool(undelegateSharesAmount);

        (, uint256 validatorId, uint256 amountS, bool isWithdrawn, uint256 requestTimestamp, address userAddress) =
            sonicStaking.allWithdrawRequests(sonicStaking.withdrawCounter());
        assertEq(validatorId, 0);
        assertEq(requestTimestamp, block.timestamp);
        assertEq(userAddress, user);
        assertEq(isWithdrawn, false);
        assertEq(amountS, undelegateSharesAmount);

        assertEq(sonicStaking.totalPool(), depositAssetAmount - assetsToReceive);
        assertEq(sonicStaking.balanceOf(user), userSharesBefore - undelegateSharesAmount);
    }

    function testUndelegateTooMuchFromValidator() public {
        uint256 depositAssetAmount = 10_000 ether;
        uint256 delegateAssetAmount1 = 5_000 ether;
        uint256 delegateAssetAmount2 = 3_000 ether;
        uint256 undelegateSharesAmount = 6_000 ether;
        uint256 toValidatorId1 = 1;
        uint256 toValidatorId2 = 2;

        address user = makeDeposit(depositAssetAmount);

        delegate(delegateAssetAmount1, toValidatorId1);
        delegate(delegateAssetAmount2, toValidatorId2);

        // only provide validator2, which doesnt have sufficient S to undelegate
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = 2;

        SonicStaking.UndelegateRequest[] memory requests = new SonicStaking.UndelegateRequest[](1);
        requests[0] = createUndelegateRequest(undelegateSharesAmount, toValidatorId2);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.UndelegateAmountExceedsDelegated.selector));
        sonicStaking.undelegate(requests);
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
        // This should already be tested somewhere else
        uint256 amountShares = sonicStaking.convertToShares(amount);
        uint256 validatorId = 1;

        address user = makeDeposit(amount);

        //we dont need to test the deposit, we've already tested this somewhere else

        delegate(amount, validatorId);

        //we dont need to test the delegate, we've already tested this somewhere else

        SonicStaking.UndelegateRequest[] memory requests = new SonicStaking.UndelegateRequest[](1);
        requests[0] = createUndelegateRequest(amountShares, validatorId);

        uint256 userSharesBefore = sonicStaking.balanceOf(user);

        vm.prank(user);
        uint256[] memory withdrawIds = sonicStaking.undelegate(requests);

        assertEq(sonicStaking.balanceOf(user), userSharesBefore - amountShares);

        // do not explode this struct, if we add a new var in the struct, everything breaks
        (, uint256 valId, uint256 assetAmount, bool isWithdrawn,, address userAddress) =
            sonicStaking.allWithdrawRequests(withdrawIds[0]);

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

        SonicStaking.UndelegateRequest[] memory requests = new SonicStaking.UndelegateRequest[](1);
        requests[0] = createUndelegateRequest(undelegateAmountShares, validatorId);

        uint256 userSharesBefore = sonicStaking.balanceOf(user);

        vm.prank(user);
        uint256[] memory withdrawIds = sonicStaking.undelegate(requests);

        assertEq(sonicStaking.balanceOf(user), userSharesBefore - undelegateAmountShares);

        // do not explode this struct, if we add a new var in the struct, everything breaks
        (,, uint256 assetAmount,,,) = sonicStaking.allWithdrawRequests(withdrawIds[0]);
        console.log("withdrawIds[0]", withdrawIds[0]);

        assertEq(assetAmount, undelegateAmount);
    }
}
