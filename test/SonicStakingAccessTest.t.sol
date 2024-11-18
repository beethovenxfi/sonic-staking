// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import {Test, console} from "forge-std/Test.sol";
import {DeploySonicStaking} from "script/DeploySonicStaking.sol";
import {SonicStaking} from "src/SonicStaking.sol";
import {StakedS} from "src/StakedS.sol";
import {ISFC} from "src/interfaces/ISFC.sol";

contract SonicStakingTest is Test {
    address TREASURY_ADDRESS = 0xa1E849B1d6c2Fd31c63EEf7822e9E0632411ada7;
    address SONIC_STAKING_OPERATOR;
    address SONIC_STAKING_OWNER;
    ISFC SFC = ISFC(0xFC00FACE00000000000000000000000000000000);
    SonicStaking sonicStaking;
    StakedS stakedS;

    string FANTOM_FORK_URL = "https://rpc.fantom.network";
    uint256 INITIAL_FORK_BLOCK_NUMBER = 97094615;

    uint256 fantomFork;

    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    // function beforeTestSetup(bytes4 testSelector) public pure returns (bytes[] memory beforeTestCalldata) {
    //     // always deploy the contract
    //     beforeTestCalldata = new bytes[](2);
    //     beforeTestCalldata[0] = abi.encodePacked(this.testDeploySonicStaking.selector);

    //     if (testSelector == this.testDelegate.selector) {
    //         beforeTestCalldata[1] = abi.encodePacked(this.testDeposit.selector);
    //     }
    // }

    function setUp() public {
        // deploy the contract
        fantomFork = vm.createSelectFork(FANTOM_FORK_URL, INITIAL_FORK_BLOCK_NUMBER);

        SONIC_STAKING_OPERATOR = vm.addr(1);
        SONIC_STAKING_OWNER = vm.addr(2);

        DeploySonicStaking sonicStakingDeploy = new DeploySonicStaking();
        sonicStaking =
            sonicStakingDeploy.run(address(SFC), TREASURY_ADDRESS, SONIC_STAKING_OWNER, SONIC_STAKING_OPERATOR);

        stakedS = sonicStaking.stkS();

        try stakedS.renounceRole(stakedS.MINTER_ROLE(), address(this)) {
            console.log("renounce minter role");
        } catch (bytes memory) {
            console.log("fail renounce minter role");
        }
        try stakedS.renounceRole(stakedS.DEFAULT_ADMIN_ROLE(), address(this)) {
            console.log("renounce admin role");
        } catch (bytes memory) {
            console.log("fail renounce admin role");
        }
        try sonicStaking.renounceRole(sonicStaking.DEFAULT_ADMIN_ROLE(), address(this)) {
            console.log("renounce admin role from staking contract");
        } catch (bytes memory) {
            console.log("fail renounce admin role from staking contract");
        }
    }

    function testInitialization() public view {
        assertEq(sonicStaking.owner(), SONIC_STAKING_OWNER);
        assertTrue(sonicStaking.hasRole(sonicStaking.OPERATOR_ROLE(), SONIC_STAKING_OPERATOR));
        assertTrue(sonicStaking.hasRole(sonicStaking.DEFAULT_ADMIN_ROLE(), SONIC_STAKING_OWNER));
        assertFalse(sonicStaking.hasRole(sonicStaking.OPERATOR_ROLE(), address(this)));
        assertFalse(sonicStaking.hasRole(sonicStaking.DEFAULT_ADMIN_ROLE(), address(this)));

        assertEq(address(sonicStaking.SFC()), address(SFC));
        assertEq(address(sonicStaking.stkS()), address(stakedS));

        assertEq(sonicStaking.treasury(), TREASURY_ADDRESS);
        assertEq(sonicStaking.protocolFeeBIPS(), 1000);
        assertEq(sonicStaking.minDeposit(), 1 ether);
        assertEq(sonicStaking.maxDeposit(), 1_000_000 ether);
        assertEq(sonicStaking.withdrawalDelay(), 14 * 24 * 60 * 60);
        assertFalse(sonicStaking.undelegatePaused());
        assertFalse(sonicStaking.withdrawPaused());
        assertFalse(sonicStaking.rewardClaimPaused());
        assertEq(sonicStaking.totalDelegated(), 0);
        assertEq(sonicStaking.totalPool(), 0);
        assertEq(sonicStaking.totalSWorth(), 0);
        assertEq(sonicStaking.getRate(), 1 ether);
        assertEq(sonicStaking.getStkSAmountForS(1 ether), 1 ether);
    }

    function testOperatorRole() public {
        assertTrue(sonicStaking.hasRole(sonicStaking.OPERATOR_ROLE(), SONIC_STAKING_OPERATOR));
        assertFalse(sonicStaking.hasRole(sonicStaking.OPERATOR_ROLE(), address(this)));

        address user = vm.addr(200);

        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, user, sonicStaking.OPERATOR_ROLE())
        );
        sonicStaking.delegate(1 ether, 1);

        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, user, sonicStaking.OPERATOR_ROLE())
        );
        sonicStaking.undelegateToPool(1 ether, 1);

        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, user, sonicStaking.OPERATOR_ROLE())
        );
        sonicStaking.withdrawToPool(1);

        vm.expectRevert(
            abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, user, sonicStaking.OPERATOR_ROLE())
        );
        sonicStaking.setWithdrawalDelay(1);

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
