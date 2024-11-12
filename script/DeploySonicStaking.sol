// SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

import {SonicStaking} from "src/SonicStaking.sol";
import {StakedS} from "src/StakedS.sol";
import {ISFC} from "src/interfaces/ISFC.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import "forge-std/Script.sol";

contract DeploySonicStaking is Script {
    address sonicStaking;
    ISFC SFC = ISFC(0xFC00FACE00000000000000000000000000000000);
    address TREASURY_ADDRESS = 0xa1E849B1d6c2Fd31c63EEf7822e9E0632411ada7;

    function run() public {
        vm.startBroadcast();
        StakedS stakedS = new StakedS();
        sonicStaking = Upgrades.deployUUPSProxy(
            "SonicStaking.sol", abi.encodeCall(SonicStaking.initialize, (stakedS, SFC, TREASURY_ADDRESS))
        );
        vm.stopBroadcast();
    }
}
