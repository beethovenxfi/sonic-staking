// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import {Test, console} from "forge-std/Test.sol";
import {DeploySonicStaking} from "script/DeploySonicStaking.sol";
import {SonicStaking} from "src/SonicStaking.sol";
import {StakedS} from "src/StakedS.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {SFCMock} from "src/mock/SFCMock.sol";
import {SonicStakingTest} from "./SonicStakingTest.t.sol";
import {ISFC} from "src/interfaces/ISFC.sol";

contract SonicStakingMockTest is Test, SonicStakingTest {
    SFCMock sfcMock;

    // we inherit from SonicStakingTest and override the getSFC function to return a mock SFC contract
    // we then inherit from SonicStakingTest so we can run all tests defined there also with the mock SFC
    function getSFC() public override returns (ISFC) {
        sfcMock = new SFCMock();
        SFC = ISFC(address(sfcMock));
        return ISFC(sfcMock);
    }

    function testRewardAccumulation() public {
        // reward accumulation cant be tested in a fork test, as an epoch needs to be sealed by the node driver to accumulate rewards
        // hence we are using a mock SFC contract where we can set pending rewards.
        // make sure we have a delegation that accumulates rewards
        uint256 depositAmount = 100000 ether;
        uint256 delegateAmount = 1000 ether;
        uint256 toValidatorId = 1;
        makeDeposit(depositAmount);
        delegate(delegateAmount, toValidatorId);

        SFCMock(sfcMock).setPendingRewards{value: 100 ether}(address(sonicStaking), 1, 100 ether);
        assertEq(sfcMock.pendingRewards(address(sonicStaking), 1), 100 ether);
    }

    // when rewards are claimed, a few things happen
    // 1. a protocol fee (sonicStaking.protocolFeeBIPS) is taken and sent to TREAUSRY_ADDRESS
    // 2. the total pool increases by the remaining rewards (and totalSWorth by the same amount)
    // 3. Because the total pool increases, the rate of stakedS increases
    function testClaimReward() public {
        // make sure we have a delegation that accumulates rewards and pending rewards set
        uint256 depositAmount = 100000 ether;
        uint256 delegateAmount = 1000 ether;
        uint256 toValidatorId = 1;
        makeDeposit(depositAmount);
        delegate(delegateAmount, toValidatorId);

        SFCMock(sfcMock).setPendingRewards{value: 100 ether}(address(sonicStaking), 1, 100 ether);
        assertEq(sfcMock.pendingRewards(address(sonicStaking), 1), 100 ether);

        // increasing epoch to make pass require statement in claimRewards. Can only claim once per epoch as per SFC.
        sfcMock.setCurrentEpoch(sfcMock.currentEpoch() + 1);

        uint256 treasuryBalanceBefore = TREASURY_ADDRESS.balance;
        uint256 rateBefore = sonicStaking.getRate();
        uint256 poolBefore = sonicStaking.totalPool();
        uint256 totalSWorthBefore = sonicStaking.totalSWorth();

        assertEq(rateBefore, 1 ether);

        // claim the rewards
        uint256[] memory delegationIds = new uint256[](1);
        delegationIds[0] = 1;
        sonicStaking.claimRewards(delegationIds);
        assertEq(sfcMock.pendingRewards(address(sonicStaking), 1), 0);

        uint256 protocolFee = 100 ether * sonicStaking.protocolFeeBIPS() / 10_000;
        assertEq(TREASURY_ADDRESS.balance - treasuryBalanceBefore, protocolFee);

        assertEq(sonicStaking.totalPool(), poolBefore + (100 ether - protocolFee));
        assertEq(sonicStaking.totalSWorth(), totalSWorthBefore + (100 ether - protocolFee));

        assertGt(sonicStaking.getRate(), rateBefore);
    }

    // withdraw from delegator does not work on fork as it needs to increase the epoch
    function testUndelegateAndWithdrawFromDelegator() public {
        uint256 depositAmount = 10000 ether;
        uint256 delegateAmount1 = 1000 ether;
        uint256 undelegateAmount = 10000 ether;
        uint256 toValidatorId1 = 1;

        // make sure we have a deposit
        address user = makeDeposit(depositAmount);

        delegate(delegateAmount1, toValidatorId1);

        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = 1;

        vm.prank(user);
        sonicStaking.undelegate(undelegateAmount, validatorIds);
        assertEq(sonicStaking.wrIdCounter(), 102);

        // need to increase time to allow for withdrawal
        vm.warp(block.timestamp + 14 days);

        (uint256 validatorId, uint256 amountS, bool isWithdrawn, uint256 requestTimestamp, address userAddress) =
            sonicStaking.allWithdrawalRequests(100);

        assertEq(validatorId, 0);

        uint256 balanceBefore = address(user).balance;
        vm.prank(user);
        sonicStaking.withdraw(100, false);
        assertEq(address(user).balance, balanceBefore + 9000 ether);

        (validatorId, amountS, isWithdrawn, requestTimestamp, userAddress) = sonicStaking.allWithdrawalRequests(101);
        assertEq(validatorId, 1);

        vm.prank(user);
        sonicStaking.withdraw(101, false);
        assertEq(address(user).balance, balanceBefore + 10000 ether);
    }

    // withdraw from delegator does not work on fork as it needs to increase the epoch
    function testUndelegateAndWithdrawFromDelegatorToPool() public {
        uint256 depositAmount = 10000 ether;
        uint256 delegateAmount = 1000 ether;
        uint256 undelegateAmount = 1000 ether;
        uint256 toValidatorId = 1;

        (
            uint256 totalDelegatedStart,
            uint256 totalPoolStart,
            uint256 totalSWorthStart,
            uint256 rateStart,
            uint256 wrIdCounterStart
        ) = getState();

        // make sure we have a deposit
        makeDeposit(depositAmount);

        delegate(delegateAmount, toValidatorId);

        vm.prank(SONIC_STAKING_OPERATOR);
        sonicStaking.undelegateToPool(undelegateAmount, 1);

        assertEq(totalDelegatedStart + delegateAmount, sonicStaking.totalDelegated());
        assertEq(totalPoolStart + depositAmount - delegateAmount, sonicStaking.totalPool());
        assertEq(totalSWorthStart + depositAmount, sonicStaking.totalSWorth());
        assertEq(rateStart, sonicStaking.getRate());
        assertEq(wrIdCounterStart + 1, sonicStaking.wrIdCounter());

        // need to increase time to allow for withdrawal
        vm.warp(block.timestamp + 14 days);

        vm.prank(SONIC_STAKING_OPERATOR);
        sonicStaking.withdrawToPool(100);

        assertEq(totalDelegatedStart, sonicStaking.totalDelegated());
        assertEq(totalPoolStart + depositAmount, sonicStaking.totalPool());
        assertEq(totalSWorthStart + depositAmount, sonicStaking.totalSWorth());
        assertEq(rateStart, sonicStaking.getRate());
        assertEq(wrIdCounterStart + 1, sonicStaking.wrIdCounter());
    }

    function testConversionRate() public {
        // make sure we have a delegation that accumulates rewards and pending rewards set
        uint256 depositAmount = 1000 ether;
        uint256 delegateAmount = 1000 ether;
        uint256 toValidatorId = 1;
        uint256 pendingRewards = 1 ether;
        address user = makeDeposit(depositAmount);
        delegate(delegateAmount, toValidatorId);

        SFCMock(sfcMock).setPendingRewards{value: pendingRewards}(address(sonicStaking), 1, pendingRewards);
        assertEq(sfcMock.pendingRewards(address(sonicStaking), 1), pendingRewards);

        // increasing epoch to make pass require statement in claimRewards. Can only claim once per epoch as per SFC.
        sfcMock.setCurrentEpoch(sfcMock.currentEpoch() + 1);

        uint256 treasuryBalanceBefore = TREASURY_ADDRESS.balance;
        uint256 rateBefore = sonicStaking.getRate();
        uint256 poolBefore = sonicStaking.totalPool();
        uint256 totalSWorthBefore = sonicStaking.totalSWorth();
        assertEq(stakedS.balanceOf(user), depositAmount); // minted 1:1

        assertEq(rateBefore, 1 ether);

        // claim the rewards
        uint256[] memory delegationIds = new uint256[](1);
        delegationIds[0] = 1;
        sonicStaking.claimRewards(delegationIds);
        assertEq(sfcMock.pendingRewards(address(sonicStaking), 1), 0);

        uint256 protocolFee = pendingRewards * sonicStaking.protocolFeeBIPS() / 10_000;
        assertEq(TREASURY_ADDRESS.balance - treasuryBalanceBefore, protocolFee);

        assertEq(sonicStaking.totalPool(), poolBefore + (pendingRewards - protocolFee));
        assertEq(sonicStaking.totalSWorth(), totalSWorthBefore + (pendingRewards - protocolFee));

        assertGt(sonicStaking.getRate(), rateBefore);

        // check that the conversion rate is applied for new deposits
        address newUser = vm.addr(201);
        uint256 newUserDepositAmount = 100 ether;
        makeDepositFromSpecifcUser(newUserDepositAmount, newUser);
        assertLt(stakedS.balanceOf(newUser), newUserDepositAmount); // got less stkS than S (rate is <1)
        assertApproxEqAbs(stakedS.balanceOf(newUser) * sonicStaking.getRate() / 1e18, newUserDepositAmount, 1); // balance multiplied by rate should be equal to deposit amount
    }

    function getState()
        public
        view
        returns (uint256 totalDelegated, uint256 totalPool, uint256 totalSWorth, uint256 rate, uint256 wrIdCounter)
    {
        totalDelegated = sonicStaking.totalDelegated();
        totalPool = sonicStaking.totalPool();
        totalSWorth = sonicStaking.totalSWorth();
        rate = sonicStaking.getRate();
        wrIdCounter = sonicStaking.wrIdCounter();
    }
}
