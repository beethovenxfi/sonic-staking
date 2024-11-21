// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import {Test, console} from "forge-std/Test.sol";
import {DeploySonicStaking} from "script/DeploySonicStaking.sol";
import {SonicStaking} from "src/SonicStaking.sol";
import {SonicStakingUpgrade} from "src/mock/SonicStakingUpgrade.sol";
import {StakedS} from "src/StakedS.sol";
import {ISFC} from "src/interfaces/ISFC.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {SonicStakingTest} from "./SonicStakingTest.t.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

contract SonicStakingUpgradeTest is Test, SonicStakingTest {
    SonicStakingUpgrade sonicStakingUpgrade;

    // we inherit from SonicStakingTest and override the deploySonicStaking function to setup the SonicStaking contract with the mock SFC.
    // we then inherit from SonicStakingTest so we can run all tests defined there also with the mock SFC
    // we will setup and upgrade the staking contract here and make sure all previous tests pass
    function deploySonicStaking() public virtual override {
        // deploy the contract
        fantomFork = vm.createSelectFork(FANTOM_FORK_URL, INITIAL_FORK_BLOCK_NUMBER);
        SFC = ISFC(0xFC00FACE00000000000000000000000000000000);

        SONIC_STAKING_OPERATOR = vm.addr(1);
        SONIC_STAKING_OWNER = vm.addr(2);

        DeploySonicStaking sonicStakingDeploy = new DeploySonicStaking();
        sonicStaking =
            sonicStakingDeploy.run(address(SFC), TREASURY_ADDRESS, SONIC_STAKING_OWNER, SONIC_STAKING_OPERATOR);

        wrapped = sonicStaking.wrapped();

        // somehow the renouncing in the DeploySonicStaking script doesn't work when called from the test, so we renounce here
        try wrapped.renounceRole(wrapped.MINTER_ROLE(), address(this)) {
            console.log("renounce minter role");
        } catch (bytes memory) {
            console.log("fail renounce minter role");
        }
        try wrapped.renounceRole(wrapped.DEFAULT_ADMIN_ROLE(), address(this)) {
            console.log("renounce admin role");
        } catch (bytes memory) {
            console.log("fail renounce admin role");
        }
        try sonicStaking.renounceRole(sonicStaking.DEFAULT_ADMIN_ROLE(), address(this)) {
            console.log("renounce admin role from staking contract");
        } catch (bytes memory) {
            console.log("fail renounce admin role from staking contract");
        }

        // upgrade the proxy
        vm.startPrank(SONIC_STAKING_OWNER);
        Options memory opts;
        opts.referenceContract = "SonicStaking.sol:SonicStaking";
        Upgrades.upgradeProxy(address(sonicStaking), "SonicStakingUpgrade.sol:SonicStakingUpgrade", "", opts);
        sonicStakingUpgrade = SonicStakingUpgrade(payable(address(sonicStaking)));
        vm.stopPrank();
    }

    function testContractUpgraded() public {
        assertEq(sonicStakingUpgrade.testUpgrade(), 1);
    }
}
