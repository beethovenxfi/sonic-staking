// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import {Test, console} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SonicStaking} from "src/SonicStaking.sol";

import {ISFC} from "src/interfaces/ISFC.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

contract SonicStakingTestSetup is Test {
    address TREASURY_ADDRESS = 0xa1E849B1d6c2Fd31c63EEf7822e9E0632411ada7;
    address SONIC_STAKING_CLAIMOR;
    address SONIC_STAKING_OPERATOR;
    address SONIC_STAKING_OWNER;
    SonicStaking sonicStaking;

    ISFC SFC;

    string FANTOM_FORK_URL = "https://rpc.fantom.network";
    uint256 INITIAL_FORK_BLOCK_NUMBER = 97094615;

    uint256 fantomFork;

    enum WithdrawKind {
        POOL,
        VALIDATOR
    }

    function setUp() public {
        fantomFork = vm.createSelectFork(FANTOM_FORK_URL, INITIAL_FORK_BLOCK_NUMBER);
        setSFCAddress();

        // deploy Sonic Staking
        SONIC_STAKING_OPERATOR = vm.addr(1);
        SONIC_STAKING_OWNER = vm.addr(2);
        SONIC_STAKING_CLAIMOR = vm.addr(3);

        address sonicStakingAddress = Upgrades.deployUUPSProxy(
            "SonicStaking.sol:SonicStaking", abi.encodeCall(SonicStaking.initialize, (SFC, TREASURY_ADDRESS))
        );
        sonicStaking = SonicStaking(payable(sonicStakingAddress));

        // setup sonicStaking access control
        sonicStaking.transferOwnership(SONIC_STAKING_OWNER);
        sonicStaking.grantRole(sonicStaking.OPERATOR_ROLE(), SONIC_STAKING_OPERATOR);
        sonicStaking.grantRole(sonicStaking.CLAIM_ROLE(), SONIC_STAKING_CLAIMOR);
        sonicStaking.grantRole(sonicStaking.DEFAULT_ADMIN_ROLE(), SONIC_STAKING_OWNER);
        sonicStaking.renounceRole(sonicStaking.DEFAULT_ADMIN_ROLE(), address(this));
    }

    function setSFCAddress() public virtual {
        SFC = ISFC(0xFC00FACE00000000000000000000000000000000);
    }

    function makeDepositFromSpecifcUser(uint256 amount, address user) public {
        vm.prank(user);
        vm.deal(user, amount);
        sonicStaking.deposit{value: amount}();
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

    function getAmounts()
        public
        view
        returns (uint256 totalDelegated, uint256 totalPool, uint256 totalSWorth, uint256 rate, uint256 lastUsedWrId)
    {
        totalDelegated = sonicStaking.totalDelegated();
        totalPool = sonicStaking.totalPool();
        totalSWorth = sonicStaking.totalAssets();
        rate = sonicStaking.getRate();
        lastUsedWrId = sonicStaking.withdrawCounter();
    }

    function createUndelegateRequest(uint256 amount, uint256 validatorId)
        public
        returns (SonicStaking.UndelegateRequest memory)
    {
        return SonicStaking.UndelegateRequest({validatorId: validatorId, amountShares: amount});
    }
}
