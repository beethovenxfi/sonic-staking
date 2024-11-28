// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import {Test, console} from "forge-std/Test.sol";
import {DeploySonicStaking} from "script/DeploySonicStaking.sol";
import {SonicStaking} from "src/SonicStaking.sol";
import {ISFC} from "src/interfaces/ISFC.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {SonicStakingTest} from "./SonicStakingTest.t.sol";

contract SonicStakingRevertTest is Test, SonicStakingTest {
    function testDelegateRevert() public {
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.DelegateAmountCannotBeZero.selector));
        delegate(0, 1);

        vm.expectRevert(abi.encodeWithSelector(SonicStaking.DelegateAmountLargerThanPool.selector));
        delegate(100 ether, 1);

        makeDeposit(100 ether);
        delegate(10 ether, 1);

        // vm.expectRevert("ERR_WAIT_FOR_NEXT_EPOCH");
        delegate(10 ether, 1);
    }

    function testUndelegateToPoolRevert() public {
        vm.prank(SONIC_STAKING_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.UndelegateAmountCannotBeZero.selector));
        sonicStaking.operatorUndelegateToPool(0, 1);

        makeDeposit(100 ether);
        delegate(100 ether, 1);

        vm.prank(SONIC_STAKING_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.NoDelegationForValidator.selector, 2));
        sonicStaking.operatorUndelegateToPool(100 ether, 2);

        vm.prank(SONIC_STAKING_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.UndelegateAmountExceedsDelegated.selector));
        sonicStaking.operatorUndelegateToPool(1000 ether, 1);
    }
}
