// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import {Test, console} from "forge-std/Test.sol";
import {DeploySonicStaking} from "script/DeploySonicStaking.sol";
import {SonicStaking} from "src/SonicStaking.sol";
import {ISFC} from "src/interfaces/ISFC.sol";
import {SonicStakingTestSetup} from "./SonicStakingTestSetup.sol";

contract SonicStakingAccessTest is Test, SonicStakingTestSetup {
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);
    error OwnableUnauthorizedAccount(address account);

    function testOperatorRoleDeny() public {
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
        sonicStaking.pause();

        vm.stopPrank();
    }

    function testOperatorRolePass() public {
        assertTrue(sonicStaking.hasRole(sonicStaking.OPERATOR_ROLE(), SONIC_STAKING_OPERATOR));

        vm.startPrank(SONIC_STAKING_OPERATOR);

        sonicStaking.pause();
        assertTrue(sonicStaking.undelegatePaused());
        assertTrue(sonicStaking.withdrawPaused());
        assertTrue(sonicStaking.rewardClaimPaused());
        assertTrue(sonicStaking.depositPaused());

        vm.stopPrank();
    }

    function testOwnerDeny() public {
        assertEq(sonicStaking.owner(), SONIC_STAKING_OWNER);

        address user = vm.addr(200);
        assertFalse(sonicStaking.owner() == address(user));

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user));
        sonicStaking.setWithdrawDelay(7);

        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user));
        sonicStaking.setUndelegatePaused(true);

        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user));
        sonicStaking.setWithdrawPaused(true);

        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user));
        sonicStaking.setRewardClaimPaused(true);

        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user));
        sonicStaking.setDepositPaused(true);

        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user));
        sonicStaking.setTreasury(address(user));

        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user));
        sonicStaking.setProtocolFeeBIPS(9_000);

        vm.stopPrank();
    }

    function testOwnerPass() public {
        assertEq(sonicStaking.owner(), SONIC_STAKING_OWNER);

        vm.startPrank(SONIC_STAKING_OWNER);
        sonicStaking.setWithdrawDelay(7);
        assertEq(sonicStaking.withdrawDelay(), 7);

        sonicStaking.setUndelegatePaused(true);
        assertTrue(sonicStaking.undelegatePaused());

        sonicStaking.setWithdrawPaused(true);
        assertTrue(sonicStaking.withdrawPaused());

        sonicStaking.setRewardClaimPaused(true);
        assertTrue(sonicStaking.rewardClaimPaused());

        sonicStaking.setDepositPaused(true);
        assertTrue(sonicStaking.depositPaused());

        sonicStaking.setTreasury(SONIC_STAKING_OWNER);
        assertEq(sonicStaking.treasury(), SONIC_STAKING_OWNER);

        sonicStaking.setProtocolFeeBIPS(9_000);
        assertEq(sonicStaking.protocolFeeBIPS(), 9_000);

        vm.stopPrank();
    }
}
