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
        uint256 depositAmount = 100000 ether;

        address user = makeDeposit(depositAmount);
        assertEq(sonicStaking.totalPool(), depositAmount);
        assertEq(sonicStaking.totalAssets(), depositAmount);

        assertEq(sonicStaking.getRate(), 1 ether);
        // user gets the same amount of stkS because rate is 1.
        assertEq(sonicStaking.balanceOf(user), depositAmount);
    }

    function testDelegate() public {
        uint256 depositAmount = 100000 ether;
        uint256 delegateAmount = 1000 ether;
        uint256 toValidatorId = 1;

        // make sure we have a deposit
        makeDeposit(depositAmount);

        uint256 rateBefore = sonicStaking.getRate();
        // delegate
        delegate(delegateAmount, toValidatorId);

        // assert
        assertEq(sonicStaking.totalPool(), depositAmount - delegateAmount);
        assertEq(sonicStaking.totalDelegated(), delegateAmount);
        assertEq(sonicStaking.totalAssets(), depositAmount);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId), delegateAmount);

        assertEq(sonicStaking.getRate(), rateBefore);
    }

    function testMultipleDelegateToSameValidator() public {
        uint256 depositAmount = 100000 ether;
        uint256 delegateAmount = 1000 ether;
        uint256 toValidatorId = 1;

        // make sure we have a deposit
        makeDeposit(depositAmount);

        delegate(delegateAmount, toValidatorId);

        assertEq(sonicStaking.totalDelegated(), delegateAmount);
        assertEq(sonicStaking.totalAssets(), depositAmount);
        assertEq(sonicStaking.totalPool(), depositAmount - delegateAmount);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId), delegateAmount);

        // need to increase time to allow for another delegation
        vm.warp(block.timestamp + 1 hours);

        delegate(delegateAmount, toValidatorId);

        assertEq(sonicStaking.totalDelegated(), delegateAmount * 2);
        assertEq(sonicStaking.totalAssets(), depositAmount);
        assertEq(sonicStaking.totalPool(), depositAmount - delegateAmount * 2);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId), delegateAmount * 2);
    }

    function testMultipleDelegateToDifferentValidator() public {
        uint256 depositAmount = 100000 ether;
        uint256 delegateAmount1 = 1000 ether;
        uint256 delegateAmount2 = 5000 ether;
        uint256 toValidatorId1 = 1;
        uint256 toValidatorId2 = 2;

        // make sure we have a deposit
        makeDeposit(depositAmount);

        delegate(delegateAmount1, toValidatorId1);

        assertEq(sonicStaking.totalDelegated(), delegateAmount1);
        assertEq(sonicStaking.totalAssets(), depositAmount);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId1), delegateAmount1);

        // need to increase time to allow for another delegation
        vm.warp(block.timestamp + 1 hours);

        delegate(delegateAmount2, toValidatorId2);

        assertEq(sonicStaking.totalDelegated(), delegateAmount1 + delegateAmount2);
        assertEq(sonicStaking.totalAssets(), depositAmount);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId1), delegateAmount1);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId2), delegateAmount2);
    }

    function testUndelegateFromPool() public {
        uint256 depositAmount = 100000 ether;
        uint256 delegateAmount1 = 1000 ether;
        uint256 delegateAmount2 = 5000 ether;
        uint256 undelegateAmount = 10000 ether;
        uint256 toValidatorId1 = 1;
        uint256 toValidatorId2 = 2;

        // make sure we have a deposit
        address user = makeDeposit(depositAmount);

        delegate(delegateAmount1, toValidatorId1);

        // need to increase time to allow for another delegation
        vm.warp(block.timestamp + 1 hours);

        delegate(delegateAmount2, toValidatorId2);

        uint256[] memory validatorIds = new uint256[](0);

        vm.prank(user);
        sonicStaking.undelegate(undelegateAmount, validatorIds);

        assertEq(sonicStaking.totalDelegated(), delegateAmount1 + delegateAmount2);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId1), delegateAmount1);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId2), delegateAmount2);
        assertEq(sonicStaking.totalPool(), depositAmount - delegateAmount1 - delegateAmount2 - undelegateAmount);
        assertEq(sonicStaking.balanceOf(user), depositAmount - undelegateAmount);

        (, uint256 validatorId, uint256 amountS, bool isWithdrawn, uint256 requestTimestamp, address userAddress) =
            sonicStaking.allWithdrawRequests(sonicStaking.withdrawCounter());
        assertEq(validatorId, 0);
        assertEq(requestTimestamp, block.timestamp);
        assertEq(userAddress, user);
        assertEq(isWithdrawn, false);
        assertEq(amountS, undelegateAmount);
    }

    function testUndelegateFromValidatorAndPool() public {
        uint256 depositAmount = 10000 ether;
        uint256 delegateAmount1 = 1000 ether;
        uint256 delegateAmount2 = 5000 ether;
        uint256 undelegateAmount = 8000 ether;
        uint256 toValidatorId1 = 1;
        uint256 toValidatorId2 = 2;

        uint256 undelegatedFromPool = undelegateAmount - (depositAmount - delegateAmount1 - delegateAmount2);

        // make sure we have a deposit
        address user = makeDeposit(depositAmount);

        delegate(delegateAmount1, toValidatorId1);

        // need to increase time to allow for another delegation
        vm.warp(block.timestamp + 1 hours);

        delegate(delegateAmount2, toValidatorId2);

        uint256[] memory validatorIds = new uint256[](2);
        validatorIds[0] = 1;
        validatorIds[1] = 2;

        vm.prank(user);
        sonicStaking.undelegate(undelegateAmount, validatorIds);

        assertEq(
            sonicStaking.totalDelegated(), delegateAmount1 + delegateAmount2 - (undelegateAmount - undelegatedFromPool)
        );
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId1), 0);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId2), 2000 ether);
        assertEq(sonicStaking.totalPool(), 0);
        assertEq(sonicStaking.balanceOf(user), depositAmount - undelegateAmount);

        assertEq(sonicStaking.withdrawCounter(), 103);

        (, uint256 validatorId, uint256 amountS, bool isWithdrawn, uint256 requestTimestamp, address userAddress) =
            sonicStaking.allWithdrawRequests(sonicStaking.withdrawCounter() - 2);
        assertEq(validatorId, 0);
        assertEq(requestTimestamp, block.timestamp);
        assertEq(userAddress, user);
        assertEq(isWithdrawn, false);
        assertEq(amountS, undelegatedFromPool);

        (, validatorId, amountS, isWithdrawn, requestTimestamp, userAddress) =
            sonicStaking.allWithdrawRequests(sonicStaking.withdrawCounter() - 1);
        assertEq(validatorId, 1);
        assertEq(requestTimestamp, block.timestamp);
        assertEq(userAddress, user);
        assertEq(isWithdrawn, false);
        assertEq(amountS, 1000 ether);

        (, validatorId, amountS, isWithdrawn, requestTimestamp, userAddress) =
            sonicStaking.allWithdrawRequests(sonicStaking.withdrawCounter());
        assertEq(validatorId, 2);
        assertEq(requestTimestamp, block.timestamp);
        assertEq(userAddress, user);
        assertEq(isWithdrawn, false);
        assertEq(amountS, 3000 ether);
    }

    function testUndelegateAndWithdrawFromPoolOnly() public {
        uint256 depositAmount = 10000 ether;
        uint256 delegateAmount1 = 1000 ether;
        uint256 undelegateAmount = 1000 ether;
        uint256 toValidatorId1 = 1;

        (
            uint256 totalDelegatedStart,
            uint256 totalPoolStart,
            uint256 totalSWorthStart,
            uint256 rateStart,
            uint256 lastUsedWrIdStart
        ) = getAmounts();

        // make sure we have a deposit
        address user = makeDeposit(depositAmount);

        assertEq(totalDelegatedStart, sonicStaking.totalDelegated());
        assertEq(totalPoolStart + depositAmount, sonicStaking.totalPool());
        assertEq(totalSWorthStart + depositAmount, sonicStaking.totalAssets());
        assertEq(rateStart, sonicStaking.getRate());
        assertEq(lastUsedWrIdStart, sonicStaking.withdrawCounter());
        assertEq(sonicStaking.balanceOf(user), depositAmount);

        delegate(delegateAmount1, toValidatorId1);

        assertEq(totalDelegatedStart + delegateAmount1, sonicStaking.totalDelegated());
        assertEq(totalPoolStart + depositAmount - delegateAmount1, sonicStaking.totalPool());
        assertEq(totalSWorthStart + depositAmount, sonicStaking.totalAssets());
        assertEq(rateStart, sonicStaking.getRate());
        assertEq(lastUsedWrIdStart, sonicStaking.withdrawCounter());
        assertEq(sonicStaking.balanceOf(user), depositAmount);

        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = 1;

        vm.prank(user);
        sonicStaking.undelegate(undelegateAmount, validatorIds);
        assertEq(sonicStaking.withdrawCounter(), 101);

        assertEq(totalDelegatedStart + delegateAmount1, sonicStaking.totalDelegated());
        assertEq(totalPoolStart + depositAmount - delegateAmount1 - undelegateAmount, sonicStaking.totalPool());
        assertEq(totalSWorthStart + depositAmount - undelegateAmount, sonicStaking.totalAssets());
        assertEq(rateStart, sonicStaking.getRate());
        assertEq(lastUsedWrIdStart + 1, sonicStaking.withdrawCounter());
        assertEq(sonicStaking.balanceOf(user), depositAmount - undelegateAmount);

        // need to increase time to allow for withdraw
        vm.warp(block.timestamp + 14 days);

        uint256 balanceBefore = address(user).balance;
        vm.prank(user);
        sonicStaking.withdraw(101, false);
        assertEq(address(user).balance, balanceBefore + 1000 ether);

        assertEq(totalDelegatedStart + delegateAmount1, sonicStaking.totalDelegated());
        assertEq(totalPoolStart + depositAmount - delegateAmount1 - undelegateAmount, sonicStaking.totalPool());
        assertEq(totalSWorthStart + depositAmount - undelegateAmount, sonicStaking.totalAssets());
        assertEq(rateStart, sonicStaking.getRate());
        assertEq(lastUsedWrIdStart + 1, sonicStaking.withdrawCounter());
        assertEq(sonicStaking.balanceOf(user), depositAmount - undelegateAmount);

        (,,, bool isWithdrawn,,) = sonicStaking.allWithdrawRequests(101);
        assertEq(isWithdrawn, true);
    }

    function testUndelegateWithTooLittleValidatorsProvided() public {
        uint256 depositAmount = 10000 ether;
        uint256 delegateAmount1 = 5000 ether;
        uint256 delegateAmount2 = 3000 ether;
        uint256 undelegateAmount = 6000 ether;
        uint256 toValidatorId1 = 1;
        uint256 toValidatorId2 = 2;

        (, uint256 totalPoolStart,,,) = getAmounts();

        // make sure we have a deposit
        address user = makeDeposit(depositAmount);

        delegate(delegateAmount1, toValidatorId1);
        delegate(delegateAmount2, toValidatorId2);

        assertEq(delegateAmount2 + delegateAmount1, sonicStaking.totalDelegated());
        assertEq(totalPoolStart + depositAmount - delegateAmount1 - delegateAmount2, sonicStaking.totalPool());

        // only provide validator2, which doesnt have sufficient S to undelegate
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = 2;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(SonicStaking.UnableToUndelegateFullAmountFromSpecifiedValidators.selector)
        );
        sonicStaking.undelegate(undelegateAmount, validatorIds);
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
}
