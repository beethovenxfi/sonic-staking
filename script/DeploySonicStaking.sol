// SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

import {SonicStaking} from "src/SonicStaking.sol";
import {ISFC} from "src/interfaces/ISFC.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import "forge-std/Script.sol";

contract DeploySonicStaking is Script {
    function run(address sfcAddress, address treasuryAddress, address sonicStakingOwner, address sonicStakingOperator)
        public
        returns (SonicStaking)
    {
        vm.startBroadcast();
        address sonicStakingAddress = Upgrades.deployUUPSProxy(
            "SonicStaking.sol:SonicStaking",
            abi.encodeCall(SonicStaking.initialize, (ISFC(sfcAddress), treasuryAddress))
        );
        SonicStaking sonicStaking = SonicStaking(payable(sonicStakingAddress));

        // setup sonicStaking access control
        sonicStaking.transferOwnership(sonicStakingOwner);
        sonicStaking.grantRole(sonicStaking.OPERATOR_ROLE(), sonicStakingOperator);
        sonicStaking.grantRole(sonicStaking.DEFAULT_ADMIN_ROLE(), sonicStakingOwner);
        try sonicStaking.renounceRole(sonicStaking.DEFAULT_ADMIN_ROLE(), msg.sender) {
            console.log("renounce default admin role role in deployscript");
        } catch (bytes memory) {
            console.log("fail renounce default admin role in deployscript");
        }

        vm.stopBroadcast();
        return sonicStaking;
    }
}
