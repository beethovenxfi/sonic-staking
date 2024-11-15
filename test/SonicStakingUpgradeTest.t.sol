// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import {Test, console} from "forge-std/Test.sol";
import {DeploySonicStaking} from "script/DeploySonicStaking.sol";
import {SonicStaking} from "src/SonicStaking.sol";
import {StakedS} from "src/StakedS.sol";
import {ISFC} from "src/interfaces/ISFC.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

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
        } catch (bytes memory reason) {
            console.log("fail renounce minter role");
        }
        try stakedS.renounceRole(stakedS.DEFAULT_ADMIN_ROLE(), address(this)) {
            console.log("renounce admin role");
        } catch (bytes memory reason) {
            console.log("fail renounce admin role");
        }
        try sonicStaking.renounceRole(sonicStaking.DEFAULT_ADMIN_ROLE(), address(this)) {
            console.log("renounce admin role from staking contract");
        } catch (bytes memory reason) {
            console.log("fail renounce admin role from staking contract");
        }
    }

    function makeDeposit(uint256 amount) public returns (address) {
        address user = vm.addr(200);
        vm.prank(user);
        vm.deal(user, amount);
        sonicStaking.deposit{value: amount}();
        return user;
    }

    function delegate(uint256 amount, uint256 validatorId) public {
        vm.prank(SONIC_STAKING_OPERATOR);
        sonicStaking.delegate(amount, validatorId);
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
