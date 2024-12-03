// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {DeploySonicStaking} from "script/DeploySonicStaking.sol";
import {SonicStaking} from "src/SonicStaking.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {SFCMock} from "src/mock/SFCMock.sol";
import {SonicStakingTest} from "./SonicStakingTest.t.sol";
import {ISFC} from "src/interfaces/ISFC.sol";

contract SonicStakingMockTest is Test, SonicStakingTest {
    SFCMock sfcMock;

    // we inherit from SonicStakingTest and override the setSFCAddress function to setup the SonicStaking contract with the mock SFC.
    // we do that so we can run all tests defined there with the mock SFC also to make sure the mock doesnt do something funky.
    function setSFCAddress() public virtual override {
        // deploy the contract
        sfcMock = new SFCMock();
        SFC = ISFC(address(sfcMock));
    }

    function testRewardAccumulationInMock() public {
        // reward accumulation cant be tested in a fork test, as an epoch needs to be sealed by the node driver to accumulate rewards
        // hence we are using a mock SFC contract where we can set pending rewards.
        // make sure we have a delegation that accumulates rewards
        uint256 depositAssetAmount = 100_000 ether;
        uint256 delegateAssetAmount = 1_000 ether;
        uint256 toValidatorId = 1;
        makeDeposit(depositAssetAmount);
        delegate(delegateAssetAmount, toValidatorId);

        SFCMock(sfcMock).setPendingRewards{value: 100 ether}(address(sonicStaking), 1, 100 ether);
        assertEq(sfcMock.pendingRewards(address(sonicStaking), 1), 100 ether);
    }

    // when rewards are claimed, a few things happen
    // 1. a protocol fee (sonicStaking.protocolFeeBIPS) is taken and sent to TREAUSRY_ADDRESS
    // 2. the total pool increases by the remaining rewards
    // 3. Because the total pool increases, the rate of shares increases
    function testClaimReward() public {
        uint256 depositAssetAmount = 100_000 ether;
        uint256 delegateAssetAmount = 1_000 ether;
        uint256 toValidatorId = 1;
        uint256 pendingRewards = 100 ether;
        makeDeposit(depositAssetAmount);
        delegate(delegateAssetAmount, toValidatorId);

        SFCMock(sfcMock).setPendingRewards{value: pendingRewards}(address(sonicStaking), 1, pendingRewards);
        assertEq(sfcMock.pendingRewards(address(sonicStaking), 1), pendingRewards);

        uint256 treasuryBalanceBefore = TREASURY_ADDRESS.balance;
        uint256 rateBefore = sonicStaking.getRate();
        uint256 poolBefore = sonicStaking.totalPool();
        uint256 totalAssets = sonicStaking.totalAssets();

        assertEq(rateBefore, 1 ether);

        uint256[] memory delegationIds = new uint256[](1);
        delegationIds[0] = 1;
        vm.prank(SONIC_STAKING_CLAIMOR);
        sonicStaking.claimRewards(delegationIds);
        assertEq(sfcMock.pendingRewards(address(sonicStaking), 1), 0);

        uint256 protocolFee = pendingRewards * sonicStaking.protocolFeeBIPS() / sonicStaking.MAX_PROTOCOL_FEE_BIPS();
        assertEq(TREASURY_ADDRESS.balance, treasuryBalanceBefore + protocolFee);

        assertEq(sonicStaking.totalPool(), poolBefore + (pendingRewards - protocolFee));
        assertEq(sonicStaking.totalAssets(), totalAssets + (pendingRewards - protocolFee));

        assertGt(sonicStaking.getRate(), rateBefore);
    }

    // withdraw from delegator does not work on fork as it needs to increase the epoch
    function testUndelegateAndWithdraw() public {
        uint256 depositAssetAmount = 10_000 ether;
        uint256 delegateAssetAmount = 10_000 ether;
        uint256 undelegateSharesAmount = 10_000 ether;
        uint256 validatorId = 1;

        address user = makeDeposit(depositAssetAmount);

        delegate(delegateAssetAmount, validatorId);

        SonicStaking.UndelegateRequest[] memory requests = new SonicStaking.UndelegateRequest[](1);
        requests[0] = createUndelegateRequest(undelegateSharesAmount, validatorId);

        vm.prank(user);
        sonicStaking.undelegate(requests);
        assertEq(sonicStaking.withdrawCounter(), 101);

        // need to increase time to allow for withdraw
        vm.warp(block.timestamp + 14 days);

        (, uint256 validatorIdWithdrawal, uint256 amountAssets, bool isWithdrawn,, address userAddress) =
            sonicStaking.allWithdrawRequests(101);

        assertEq(validatorIdWithdrawal, validatorId);
        assertEq(amountAssets, undelegateSharesAmount);
        assertEq(userAddress, user);
        assertEq(isWithdrawn, false);

        uint256 balanceBefore = address(user).balance;

        vm.prank(user);
        sonicStaking.withdraw(101, false);
        assertEq(address(user).balance, balanceBefore + undelegateSharesAmount);

        (,,, isWithdrawn,,) = sonicStaking.allWithdrawRequests(101);

        assertEq(isWithdrawn, true);
    }

    // withdraw from delegator does not work on fork as it needs to increase the epoch
    function testUndelegateAndWithdrawWithIncreasedRate() public {
        uint256 depositAssetAmount = 10_000 ether;
        uint256 delegateAssetAmount = 10_000 ether;
        uint256 undelegateSharesAmount = 5_000 ether;
        uint256 pendingRewards = 100 ether;
        uint256 validatorId = 1;

        address user = makeDeposit(depositAssetAmount);
        uint256 userBalanceBefore = address(user).balance;

        delegate(delegateAssetAmount, validatorId);

        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = 1;

        SFCMock(sfcMock).setPendingRewards{value: pendingRewards}(address(sonicStaking), 1, pendingRewards);
        uint256[] memory delegationIds = new uint256[](1);
        delegationIds[0] = 1;
        vm.prank(SONIC_STAKING_CLAIMOR);
        sonicStaking.claimRewards(delegationIds);

        uint256 assetsToReceive = sonicStaking.convertToAssets(undelegateSharesAmount);

        SonicStaking.UndelegateRequest[] memory requests = new SonicStaking.UndelegateRequest[](1);
        requests[0] = createUndelegateRequest(undelegateSharesAmount, validatorId);

        vm.prank(user);
        sonicStaking.undelegate(requests);

        // need to increase time to allow for withdraw
        vm.warp(block.timestamp + 14 days);

        (, uint256 validatorIdWithdrawal, uint256 assetAmount, bool isWithdrawn,, address userAddress) =
            sonicStaking.allWithdrawRequests(101);

        assertEq(validatorIdWithdrawal, validatorId);
        assertEq(assetAmount, assetsToReceive);
        assertEq(userAddress, user);
        assertEq(isWithdrawn, false);

        uint256 balanceBefore = address(user).balance;

        vm.prank(user);
        sonicStaking.withdraw(101, false);
        assertEq(address(user).balance, balanceBefore + assetsToReceive);
        assertGt(address(user).balance, userBalanceBefore);
    }

    function testOperatorUndelegateAndWithdrawToPool() public {
        uint256 depositAssetAmount = 10_000 ether;
        uint256 delegateAssetAmount = 1_000 ether;
        uint256 undelegateSharesAmount = 1_000 ether;
        uint256 toValidatorId = 1;

        (,,,, uint256 withdrawCounterStart) = getState();

        makeDeposit(depositAssetAmount);
        delegate(delegateAssetAmount, toValidatorId);

        vm.prank(SONIC_STAKING_OPERATOR);
        sonicStaking.operatorUndelegateToPool(undelegateSharesAmount, 1);

        assertEq(0, sonicStaking.totalDelegated());
        assertEq(depositAssetAmount - delegateAssetAmount, sonicStaking.totalPool());
        assertEq(depositAssetAmount, sonicStaking.totalAssets());
        assertEq(1 ether, sonicStaking.getRate());
        assertEq(withdrawCounterStart + 1, sonicStaking.withdrawCounter());

        // need to increase time to allow for withdraw
        vm.warp(block.timestamp + 14 days);

        vm.prank(SONIC_STAKING_OPERATOR);
        sonicStaking.operatorWithdrawToPool(101, false);

        assertEq(0, sonicStaking.totalDelegated());
        assertEq(depositAssetAmount, sonicStaking.totalPool());
        assertEq(depositAssetAmount, sonicStaking.totalAssets());
        assertEq(1 ether, sonicStaking.getRate());
        assertEq(withdrawCounterStart + 1, sonicStaking.withdrawCounter());
    }

    function testConversionRate() public {
        uint256 depositAssetAmount = 1_000 ether;
        uint256 delegateAssetAmount = 1_000 ether;
        uint256 toValidatorId = 1;
        uint256 pendingRewards = 1 ether;
        address user = makeDeposit(depositAssetAmount);
        delegate(delegateAssetAmount, toValidatorId);

        SFCMock(sfcMock).setPendingRewards{value: pendingRewards}(address(sonicStaking), 1, pendingRewards);

        uint256 rateBefore = sonicStaking.getRate();
        assertEq(sonicStaking.balanceOf(user), depositAssetAmount); // minted 1:1

        assertEq(rateBefore, 1 ether);

        uint256[] memory delegationIds = new uint256[](1);
        delegationIds[0] = 1;
        vm.prank(SONIC_STAKING_CLAIMOR);
        sonicStaking.claimRewards(delegationIds);

        uint256 protocolFee = pendingRewards * sonicStaking.protocolFeeBIPS() / sonicStaking.MAX_PROTOCOL_FEE_BIPS();

        uint256 assetIncrease = pendingRewards - protocolFee;
        uint256 newRate = (1 ether * (depositAssetAmount + assetIncrease)) / depositAssetAmount;

        assertGt(sonicStaking.getRate(), rateBefore);
        assertEq(sonicStaking.getRate(), newRate);

        // check that the conversion rate is applied for new deposits
        address newUser = vm.addr(201);
        uint256 newUserDepositAmount = 100 ether;
        makeDepositFromSpecifcUser(newUserDepositAmount, newUser);
        assertLt(sonicStaking.balanceOf(newUser), newUserDepositAmount); // got less shares than assets deposited (rate is >1)
        assertApproxEqAbs(sonicStaking.balanceOf(newUser) * sonicStaking.getRate() / 1e18, newUserDepositAmount, 1); // balance multiplied by rate should be equal to deposit amount
    }

    function testEmergencyWithdraw() public {
        uint256 depositAssetAmount = 1_000 ether;
        uint256 delegateAssetAmount = 1_000 ether;
        uint256 validatorId = 1;
        address user = makeDeposit(depositAssetAmount);
        delegate(delegateAssetAmount, validatorId);

        // slash the validator (slash half of the stake)
        sfcMock.setCheater(validatorId, true);
        sfcMock.setSlashRefundRatio(validatorId, 5 * 1e17);

        SonicStaking.UndelegateRequest[] memory requests = new SonicStaking.UndelegateRequest[](1);
        requests[0] = createUndelegateRequest(delegateAssetAmount, validatorId);

        vm.prank(user);
        sonicStaking.undelegate(requests);
        assertEq(sonicStaking.withdrawCounter(), 101);

        vm.warp(block.timestamp + 14 days);

        uint256 balanceBefore = address(user).balance;

        // do not emergency withdraw, will revert
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.WithdrawnAmountTooLow.selector));
        sonicStaking.withdraw(101, false);

        // emergency withdraw
        vm.prank(user);
        sonicStaking.withdraw(101, true);
        assertApproxEqAbs(address(user).balance, balanceBefore + 500 ether, 1);
    }

    function getState()
        public
        view
        returns (uint256 totalDelegated, uint256 totalPool, uint256 totalSWorth, uint256 rate, uint256 lastUsedWrId)
    {
        totalDelegated = sonicStaking.totalDelegated();
        totalPool = sonicStaking.totalPool();
        totalSWorth = sonicStaking.totalAssets();
        rate = sonicStaking.getRate();
        lastUsedWrId = sonicStaking.withdrawCounter();
    }
}
