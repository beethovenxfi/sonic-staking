// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import {Test, console} from "forge-std/Test.sol";
import {DeploySonicStaking} from "script/DeploySonicStaking.sol";
import {SonicStaking} from "src/SonicStaking.sol";
import {ISFC} from "src/interfaces/ISFC.sol";
import {SonicStakingTestSetup} from "./SonicStakingTestSetup.sol";

contract SonicStakingAccessTest is Test, SonicStakingTestSetup {
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    function testOperatorRole() public {
        assertTrue(sonicStaking.hasRole(sonicStaking.OPERATOR_ROLE(), SONIC_STAKING_OPERATOR));

        address user = vm.addr(200);
        assertFalse(sonicStaking.hasRole(sonicStaking.OPERATOR_ROLE(), address(user)));

        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, user, sonicStaking.OPERATOR_ROLE())
        );
        sonicStaking.delegate(1 ether, 1);

        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, user, sonicStaking.OPERATOR_ROLE())
        );
        sonicStaking.operatorUndelegateToPool(1 ether, 1);

        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, user, sonicStaking.OPERATOR_ROLE())
        );
        sonicStaking.operatorWithdrawToPool(1);

        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, user, sonicStaking.OPERATOR_ROLE())
        );
        sonicStaking.setWithdrawDelay(1);

        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, user, sonicStaking.OPERATOR_ROLE())
        );
        sonicStaking.setUndelegatePaused(true);

        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, user, sonicStaking.OPERATOR_ROLE())
        );
        sonicStaking.setWithdrawPaused(true);

        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, user, sonicStaking.OPERATOR_ROLE())
        );
        sonicStaking.setRewardClaimPaused(true);

        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, user, sonicStaking.OPERATOR_ROLE())
        );
        sonicStaking.setDepositLimits(1, 100);

        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, user, sonicStaking.OPERATOR_ROLE())
        );
        sonicStaking.setTreasury(user);

        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, user, sonicStaking.OPERATOR_ROLE())
        );
        sonicStaking.setProtocolFeeBIPS(0);
    }
}
