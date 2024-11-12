// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {SonicStaking} from "../src/SonicStaking.sol";

contract DeployCampaign {
    address private s_deployedCampaigns;

    function createCampaign(uint minimum) public {
        address campaign = address(new SonicStaking(minimum, msg.sender));
        s_deployedCampaigns.push(campaign);
    }

    function getDeployedCampaigns() public view returns (address[] memory) {
        return s_deployedCampaigns;
    }
}
