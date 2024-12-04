// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {DeploySonicStaking} from "script/DeploySonicStaking.sol";
import {SonicStaking} from "src/SonicStaking.sol";
import {ISFC} from "src/interfaces/ISFC.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {SonicStakingTestSetup} from "./SonicStakingTestSetup.sol";

contract SonicStakingRevertTest is Test, SonicStakingTestSetup {
    function testDelegateRevert() public {
        vm.expectRevert(abi.encodeWithSelector(SonicStaking.DelegateAmountCannotBeZero.selector));
        delegate(1, 0);

        vm.expectRevert(abi.encodeWithSelector(SonicStaking.DelegateAmountLargerThanPool.selector));
        delegate(1, 100 ether);

        makeDeposit(100 ether);
        delegate(1, 10 ether);

        // vm.expectRevert("ERR_WAIT_FOR_NEXT_EPOCH");
        delegate(1, 10 ether);
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
