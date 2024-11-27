// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import {Test, console} from "forge-std/Test.sol";
import {DeploySonicStaking} from "script/DeploySonicStaking.sol";
import {SonicStaking} from "src/SonicStaking.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {SFCMock} from "src/mock/SFCMock.sol";
import {SonicStakingTest} from "./SonicStakingTest.t.sol";
import {ISFC} from "src/interfaces/ISFC.sol";

contract SonicStakingMockTest is Test, SonicStakingTest {
    SFCMock sfcMock;

    // we inherit from SonicStakingTest and override the deploySonicStaking function to setup the SonicStaking contract with the mock SFC.
    // we then inherit from SonicStakingTest so we can run all tests defined there also with the mock SFC
    function deploySonicStaking() public virtual override {
        // deploy the contract
        fantomFork = vm.createSelectFork(FANTOM_FORK_URL, INITIAL_FORK_BLOCK_NUMBER);
        sfcMock = new SFCMock();
        SFC = ISFC(address(sfcMock));

        SONIC_STAKING_OPERATOR = vm.addr(1);
        SONIC_STAKING_OWNER = vm.addr(2);

        DeploySonicStaking sonicStakingDeploy = new DeploySonicStaking();
        sonicStaking =
            sonicStakingDeploy.run(address(SFC), TREASURY_ADDRESS, SONIC_STAKING_OWNER, SONIC_STAKING_OPERATOR);

        // somehow the renouncing in the DeploySonicStaking script doesn't work when called from the test, so we renounce here
        try sonicStaking.renounceRole(sonicStaking.DEFAULT_ADMIN_ROLE(), address(this)) {
            console.log("renounce admin role from staking contract");
        } catch (bytes memory) {
            console.log("fail renounce admin role from staking contract");
        }
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
        uint256 totalSWorthBefore = sonicStaking.totalAssets();

        assertEq(rateBefore, 1 ether);

        // claim the rewards
        uint256[] memory delegationIds = new uint256[](1);
        delegationIds[0] = 1;
        sonicStaking.claimRewards(delegationIds);
        assertEq(sfcMock.pendingRewards(address(sonicStaking), 1), 0);

        uint256 protocolFee = 100 ether * sonicStaking.protocolFeeBIPS() / 10_000;
        assertEq(TREASURY_ADDRESS.balance - treasuryBalanceBefore, protocolFee);

        assertEq(sonicStaking.totalPool(), poolBefore + (100 ether - protocolFee));
        assertEq(sonicStaking.totalAssets(), totalSWorthBefore + (100 ether - protocolFee));

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
        assertEq(sonicStaking.withdrawCounter(), 102);

        // need to increase time to allow for withdraw
        vm.warp(block.timestamp + 14 days);

        (, uint256 validatorId, uint256 amountS, bool isWithdrawn, uint256 requestTimestamp, address userAddress) =
            sonicStaking.allWithdrawRequests(101);

        assertEq(validatorId, 0);

        uint256 balanceBefore = address(user).balance;
        vm.prank(user);
        sonicStaking.withdraw(101, false);
        assertEq(address(user).balance, balanceBefore + 9000 ether);

        (, validatorId, amountS, isWithdrawn, requestTimestamp, userAddress) = sonicStaking.allWithdrawRequests(102);
        assertEq(validatorId, 1);

        vm.prank(user);
        sonicStaking.withdraw(102, false);
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
            uint256 lastUsedWrIdStart
        ) = getState();

        // make sure we have a deposit
        makeDeposit(depositAmount);

        delegate(delegateAmount, toValidatorId);

        vm.prank(SONIC_STAKING_OPERATOR);
        sonicStaking.operatorUndelegateToPool(undelegateAmount, 1);

        assertEq(totalDelegatedStart, sonicStaking.totalDelegated());
        assertEq(totalPoolStart + depositAmount - delegateAmount, sonicStaking.totalPool());
        assertEq(totalSWorthStart + depositAmount, sonicStaking.totalAssets());
        assertEq(rateStart, sonicStaking.getRate());
        assertEq(lastUsedWrIdStart + 1, sonicStaking.withdrawCounter());

        // need to increase time to allow for withdraw
        vm.warp(block.timestamp + 14 days);

        vm.prank(SONIC_STAKING_OPERATOR);
        sonicStaking.operatorWithdrawToPool(101);

        assertEq(totalDelegatedStart, sonicStaking.totalDelegated());
        assertEq(totalPoolStart + depositAmount, sonicStaking.totalPool());
        assertEq(totalSWorthStart + depositAmount, sonicStaking.totalAssets());
        assertEq(rateStart, sonicStaking.getRate());
        assertEq(lastUsedWrIdStart + 1, sonicStaking.withdrawCounter());
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
        uint256 totalSWorthBefore = sonicStaking.totalAssets();
        assertEq(sonicStaking.balanceOf(user), depositAmount); // minted 1:1

        assertEq(rateBefore, 1 ether);

        // claim the rewards
        uint256[] memory delegationIds = new uint256[](1);
        delegationIds[0] = 1;
        sonicStaking.claimRewards(delegationIds);
        assertEq(sfcMock.pendingRewards(address(sonicStaking), 1), 0);

        uint256 protocolFee = pendingRewards * sonicStaking.protocolFeeBIPS() / 10_000;
        assertEq(TREASURY_ADDRESS.balance - treasuryBalanceBefore, protocolFee);

        assertEq(sonicStaking.totalPool(), poolBefore + (pendingRewards - protocolFee));
        assertEq(sonicStaking.totalAssets(), totalSWorthBefore + (pendingRewards - protocolFee));

        assertGt(sonicStaking.getRate(), rateBefore);

        // check that the conversion rate is applied for new deposits
        address newUser = vm.addr(201);
        uint256 newUserDepositAmount = 100 ether;
        makeDepositFromSpecifcUser(newUserDepositAmount, newUser);
        assertLt(sonicStaking.balanceOf(newUser), newUserDepositAmount); // got less stkS than S (rate is <1)
        assertApproxEqAbs(sonicStaking.balanceOf(newUser) * sonicStaking.getRate() / 1e18, newUserDepositAmount, 1); // balance multiplied by rate should be equal to deposit amount
    }

    function testEmergencyWithdraw() public {
        // make sure we have a delegation that can be slashed
        uint256 depositAmount = 1000 ether;
        uint256 delegateAmount = 1000 ether;
        uint256 toValidatorId = 1;
        address user = makeDeposit(depositAmount);
        delegate(delegateAmount, toValidatorId);

        // slash the validator (slash half of the stake)
        sfcMock.setCheater(toValidatorId, true);
        sfcMock.setSlashRefundRatio(toValidatorId, 5 * 1e17);

        // undelegate from slashed validator
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = 1;

        vm.prank(user);
        sonicStaking.undelegate(delegateAmount, validatorIds);
        assertEq(sonicStaking.withdrawCounter(), 101);

        // need to increase time to allow for withdraw
        vm.warp(block.timestamp + 14 days);

        uint256 balanceBefore = address(user).balance;

        // do not emergency withdraw, will revert
        vm.prank(user);
        vm.expectRevert("ERR_NOT_ENOUGH_ASSETS");
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
