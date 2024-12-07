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
    uint256 constant S_MAX_SUPPLY = 4e27;

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
        uint256 assetAmount = 100_000 ether;
        uint256 delegateAmount = 1_000 ether;
        uint256 toValidatorId = 1;
        makeDeposit(assetAmount);
        delegate(toValidatorId, delegateAmount);

        SFCMock(sfcMock).setPendingRewards{value: 100 ether}(address(sonicStaking), 1, 100 ether);
        assertEq(sfcMock.pendingRewards(address(sonicStaking), 1), 100 ether);
    }

    function testFuzzGetRateIncrease(
        uint256 assetAmount,
        uint256 delegateAmount,
        uint256 pendingRewards,
        uint256 newUserAssetAmount
    ) public {
        vm.assume(assetAmount >= 1 ether);
        vm.assume(assetAmount <= S_MAX_SUPPLY);
        vm.assume(newUserAssetAmount <= S_MAX_SUPPLY);
        vm.assume(newUserAssetAmount >= 1 ether);
        vm.assume(pendingRewards <= 10000 ether);
        vm.assume(pendingRewards >= 1 ether);
        delegateAmount = bound(delegateAmount, 1 ether, assetAmount);

        uint256 validatorId = 1;
        address user = makeDeposit(assetAmount);
        delegate(validatorId, delegateAmount);

        SFCMock(sfcMock).setPendingRewards{value: pendingRewards}(address(sonicStaking), validatorId, pendingRewards);

        uint256 rateBefore = sonicStaking.getRate();
        assertEq(sonicStaking.balanceOf(user), assetAmount); // minted 1:1

        assertEq(rateBefore, 1 ether);

        uint256[] memory delegationIds = new uint256[](1);
        delegationIds[0] = 1;
        vm.prank(SONIC_STAKING_CLAIMOR);
        sonicStaking.claimRewards(delegationIds);

        uint256 protocolFee = pendingRewards * sonicStaking.protocolFeeBIPS() / sonicStaking.MAX_PROTOCOL_FEE_BIPS();

        uint256 assetIncrease = pendingRewards - protocolFee;
        uint256 newRate = (1 ether * (assetAmount + assetIncrease)) / assetAmount;

        assertGt(sonicStaking.getRate(), rateBefore);
        assertEq(sonicStaking.getRate(), newRate);
        console.log("rate before", rateBefore);
        console.log("rate after", sonicStaking.getRate());

        // check that the conversion rate is applied for new deposits
        address newUser = vm.addr(201);
        makeDepositFromSpecifcUser(newUserAssetAmount, newUser);
        assertLt(sonicStaking.balanceOf(newUser), newUserAssetAmount); // got less shares than assets deposited (rate is >1)
        assertApproxEqAbs(sonicStaking.balanceOf(newUser) * sonicStaking.getRate() / 1e18, newUserAssetAmount, 1e18); // balance multiplied by rate should be equal to deposit amount
    }

    function testInvariantViolatedAtSecondDeposit() public {
        uint256 assetAmount = 1118079717148557899; // [1.118e18]
        uint256 delegateAmount = 1 ether;
        uint256 pendingRewards = 58356595683764556486; //[5.835e19]
        uint256 newUserAssetAmount = 56369801950539978978014; //[5.636e22]

        uint256 validatorId = 1;
        address user = makeDeposit(assetAmount);
        delegate(validatorId, delegateAmount);

        SFCMock(sfcMock).setPendingRewards{value: pendingRewards}(address(sonicStaking), validatorId, pendingRewards);

        uint256 rateBefore = sonicStaking.getRate();
        assertEq(sonicStaking.balanceOf(user), assetAmount); // minted 1:1

        assertEq(rateBefore, 1 ether);

        uint256[] memory delegationIds = new uint256[](1);
        delegationIds[0] = 1;
        vm.prank(SONIC_STAKING_CLAIMOR);
        sonicStaking.claimRewards(delegationIds);

        uint256 protocolFee = pendingRewards * sonicStaking.protocolFeeBIPS() / sonicStaking.MAX_PROTOCOL_FEE_BIPS();

        uint256 assetIncrease = pendingRewards - protocolFee;
        uint256 newRate = (1 ether * (assetAmount + assetIncrease)) / assetAmount;

        assertGt(sonicStaking.getRate(), rateBefore);
        assertEq(sonicStaking.getRate(), newRate);

        // check that the conversion rate is applied for new deposits
        address newUser = vm.addr(201);
        makeDepositFromSpecifcUser(newUserAssetAmount, newUser);
        assertLt(sonicStaking.balanceOf(newUser), newUserAssetAmount); // got less shares than assets deposited (rate is >1)
        assertApproxEqAbs(sonicStaking.balanceOf(newUser) * sonicStaking.getRate() / 1e18, newUserAssetAmount, 1e18); // balance multiplied by rate should be equal to deposit amount
    }
}
