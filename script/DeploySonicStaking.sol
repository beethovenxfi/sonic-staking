// SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

import {SonicStaking} from "src/SonicStaking.sol";
import {ISFC} from "src/interfaces/ISFC.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {TimelockController} from "openzeppelin-contracts/governance/TimelockController.sol";

import "forge-std/Script.sol";

contract DeploySonicStaking is Script {
    function run(
        address sfcAddress,
        address treasuryAddress,
        address sonicStakingOwner,
        address sonicStakingAdmin,
        address sonicStakingOperator,
        address sonicStakingClaimor
    ) public returns (SonicStaking) {
        vm.startBroadcast();

        address sonicStakingAddress = Upgrades.deployUUPSProxy(
            "SonicStaking.sol:SonicStaking",
            abi.encodeCall(SonicStaking.initialize, (ISFC(sfcAddress), treasuryAddress))
        );
        SonicStaking sonicStaking = SonicStaking(payable(sonicStakingAddress));

        // grant initial roles
        sonicStaking.grantRole(sonicStaking.OPERATOR_ROLE(), sonicStakingOperator);
        sonicStaking.grantRole(sonicStaking.CLAIM_ROLE(), sonicStakingClaimor);

        // Deploy owner timelock (three week delay) that becomes owner of sonicStaking and can upgrade the contract
        address[] memory ownerProposers = new address[](0);
        ownerProposers[0] = sonicStakingOwner;
        TimelockController ownerTimelock = new TimelockController(21 days, ownerProposers, ownerProposers, address(0));

        // Deploy admin timelock (1 day delay) that can administer the protocol and roles on the staking contract
        address[] memory adminProposers = new address[](0);
        adminProposers[0] = sonicStakingAdmin;
        TimelockController adminTimelock = new TimelockController(1 days, adminProposers, adminProposers, address(0));

        // setup sonicStaking access control
        sonicStaking.transferOwnership(address(ownerTimelock));
        sonicStaking.grantRole(sonicStaking.DEFAULT_ADMIN_ROLE(), address(adminTimelock));
        sonicStaking.renounceRole(sonicStaking.DEFAULT_ADMIN_ROLE(), msg.sender);

        vm.stopBroadcast();
        return sonicStaking;
    }
}
