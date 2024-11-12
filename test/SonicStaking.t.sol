// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";

contract SonicStakingTest is Test {
    uint256 a;
    uint256 b;

    address TREASURY_ADDRESS = 0xa1E849B1d6c2Fd31c63EEf7822e9E0632411ada7;
    address SFC = 0xFC00FACE00000000000000000000000000000000;

    // use fork testing as we need SFC to test against
    // forge test --fork-url https://rpc.fantom.network --fork-block-number 97094615

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
        
    }

    function setB(uint256 value) public {
        b = value;
    }

    function testDeposit() public {
        assertEq(a, 1);
        assertEq(b, 1);
    }

    function testDelegate() public {
        assertEq(a, 1);
        assertEq(b, 1);
    }
}
