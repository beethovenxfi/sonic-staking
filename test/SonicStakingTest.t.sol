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
    SonicStaking sonicStaking;
    StakedS stakedS;

    ISFC SFC;

    string FANTOM_FORK_URL = "https://rpc.fantom.network";
    uint256 INITIAL_FORK_BLOCK_NUMBER = 97094615;

    uint256 fantomFork;

    enum WithdrawalKind {
        POOL,
        VALIDATOR
    }

    function setUp() public {
        deploySonicStaking();
    }

    function deploySonicStaking() public virtual {
        // deploy the contract
        fantomFork = vm.createSelectFork(FANTOM_FORK_URL, INITIAL_FORK_BLOCK_NUMBER);

        SONIC_STAKING_OPERATOR = vm.addr(1);
        SONIC_STAKING_OWNER = vm.addr(2);

        SFC = ISFC(0xFC00FACE00000000000000000000000000000000);

        DeploySonicStaking sonicStakingDeploy = new DeploySonicStaking();
        sonicStaking =
            sonicStakingDeploy.run(address(SFC), TREASURY_ADDRESS, SONIC_STAKING_OWNER, SONIC_STAKING_OPERATOR);

        stakedS = sonicStaking.stkS();

        // somehow the renouncing in the DeploySonicStaking script doesn't work when called from the test, so we renounce here
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
        // make sure roles are set properly
        assertEq(sonicStaking.owner(), SONIC_STAKING_OWNER);
        assertTrue(sonicStaking.hasRole(sonicStaking.OPERATOR_ROLE(), SONIC_STAKING_OPERATOR));
        assertTrue(sonicStaking.hasRole(sonicStaking.DEFAULT_ADMIN_ROLE(), SONIC_STAKING_OWNER));
        assertFalse(sonicStaking.hasRole(sonicStaking.OPERATOR_ROLE(), address(this)));
        assertFalse(sonicStaking.hasRole(sonicStaking.DEFAULT_ADMIN_ROLE(), address(this)));

        // make sure addresses are set properly
        assertEq(address(sonicStaking.SFC()), address(SFC));
        assertEq(address(sonicStaking.stkS()), address(stakedS));

        // make sure initital set is set properly
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

    function testDeposit() public {
        uint256 depositAmount = 100000 ether;

        ERC20 stkS = sonicStaking.stkS();
        address user = makeDeposit(depositAmount);
        assertEq(sonicStaking.totalPool(), depositAmount);
        assertEq(sonicStaking.totalSWorth(), depositAmount);

        assertEq(sonicStaking.getRate(), 1 ether);
        // user gets the same amount of stkS because rate is 1.
        assertEq(stkS.balanceOf(user), depositAmount);
    }

    function testDelegate() public {
        uint256 depositAmount = 100000 ether;
        uint256 delegateAmount = 1000 ether;
        uint256 toValidatorId = 1;

        // make sure we have a deposit
        makeDeposit(depositAmount);

        uint256 rateBefore = sonicStaking.getRate();
        // delegate
        delegate(delegateAmount, toValidatorId);

        // assert
        assertEq(sonicStaking.totalPool(), depositAmount - delegateAmount);
        assertEq(sonicStaking.totalDelegated(), delegateAmount);
        assertEq(sonicStaking.totalSWorth(), depositAmount);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId), delegateAmount);

        assertEq(sonicStaking.getRate(), rateBefore);
    }

    function testMultipleDelegateToSameValidator() public {
        uint256 depositAmount = 100000 ether;
        uint256 delegateAmount = 1000 ether;
        uint256 toValidatorId = 1;

        // make sure we have a deposit
        makeDeposit(depositAmount);

        delegate(delegateAmount, toValidatorId);

        assertEq(sonicStaking.totalDelegated(), delegateAmount);
        assertEq(sonicStaking.totalSWorth(), depositAmount);
        assertEq(sonicStaking.totalPool(), depositAmount - delegateAmount);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId), delegateAmount);

        // need to increase time to allow for another delegation
        vm.warp(block.timestamp + 1 hours);

        delegate(delegateAmount, toValidatorId);

        assertEq(sonicStaking.totalDelegated(), delegateAmount * 2);
        assertEq(sonicStaking.totalSWorth(), depositAmount);
        assertEq(sonicStaking.totalPool(), depositAmount - delegateAmount * 2);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId), delegateAmount * 2);
    }

    function testMultipleDelegateToDifferentValidator() public {
        uint256 depositAmount = 100000 ether;
        uint256 delegateAmount1 = 1000 ether;
        uint256 delegateAmount2 = 5000 ether;
        uint256 toValidatorId1 = 1;
        uint256 toValidatorId2 = 2;

        // make sure we have a deposit
        makeDeposit(depositAmount);

        delegate(delegateAmount1, toValidatorId1);

        assertEq(sonicStaking.totalDelegated(), delegateAmount1);
        assertEq(sonicStaking.totalSWorth(), depositAmount);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId1), delegateAmount1);

        // need to increase time to allow for another delegation
        vm.warp(block.timestamp + 1 hours);

        delegate(delegateAmount2, toValidatorId2);

        assertEq(sonicStaking.totalDelegated(), delegateAmount1 + delegateAmount2);
        assertEq(sonicStaking.totalSWorth(), depositAmount);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId1), delegateAmount1);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId2), delegateAmount2);
    }

    function testUndelegateFromPool() public {
        uint256 depositAmount = 100000 ether;
        uint256 delegateAmount1 = 1000 ether;
        uint256 delegateAmount2 = 5000 ether;
        uint256 undelegateAmount = 10000 ether;
        uint256 toValidatorId1 = 1;
        uint256 toValidatorId2 = 2;

        // make sure we have a deposit
        address user = makeDeposit(depositAmount);

        delegate(delegateAmount1, toValidatorId1);

        // need to increase time to allow for another delegation
        vm.warp(block.timestamp + 1 hours);

        delegate(delegateAmount2, toValidatorId2);

        uint256[] memory validatorIds = new uint256[](0);

        vm.prank(user);
        sonicStaking.undelegate(undelegateAmount, validatorIds);

        assertEq(sonicStaking.totalDelegated(), delegateAmount1 + delegateAmount2);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId1), delegateAmount1);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId2), delegateAmount2);
        assertEq(sonicStaking.totalPool(), depositAmount - delegateAmount1 - delegateAmount2 - undelegateAmount);
        assertEq(sonicStaking.stkS().balanceOf(user), depositAmount - undelegateAmount);

        (, uint256 validatorId, uint256 amountS, bool isWithdrawn, uint256 requestTimestamp, address userAddress) =
            sonicStaking.allWithdrawalRequests(sonicStaking.lastUsedWrId());
        assertEq(validatorId, 0);
        assertEq(requestTimestamp, block.timestamp);
        assertEq(userAddress, user);
        assertEq(isWithdrawn, false);
        assertEq(amountS, undelegateAmount);
    }

    function testUndelegateFromValidatorAndPool() public {
        uint256 depositAmount = 10000 ether;
        uint256 delegateAmount1 = 1000 ether;
        uint256 delegateAmount2 = 5000 ether;
        uint256 undelegateAmount = 8000 ether;
        uint256 toValidatorId1 = 1;
        uint256 toValidatorId2 = 2;

        uint256 undelegatedFromPool = undelegateAmount - (depositAmount - delegateAmount1 - delegateAmount2);

        // make sure we have a deposit
        address user = makeDeposit(depositAmount);

        delegate(delegateAmount1, toValidatorId1);

        // need to increase time to allow for another delegation
        vm.warp(block.timestamp + 1 hours);

        delegate(delegateAmount2, toValidatorId2);

        uint256[] memory validatorIds = new uint256[](2);
        validatorIds[0] = 1;
        validatorIds[1] = 2;

        vm.prank(user);
        sonicStaking.undelegate(undelegateAmount, validatorIds);

        assertEq(
            sonicStaking.totalDelegated(), delegateAmount1 + delegateAmount2 - (undelegateAmount - undelegatedFromPool)
        );
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId1), 0);
        assertEq(SFC.getStake(address(sonicStaking), toValidatorId2), 2000 ether);
        assertEq(sonicStaking.totalPool(), 0);
        assertEq(sonicStaking.stkS().balanceOf(user), depositAmount - undelegateAmount);

        assertEq(sonicStaking.lastUsedWrId(), 103);

        (, uint256 validatorId, uint256 amountS, bool isWithdrawn, uint256 requestTimestamp, address userAddress) =
            sonicStaking.allWithdrawalRequests(sonicStaking.lastUsedWrId() - 2);
        assertEq(validatorId, 0);
        assertEq(requestTimestamp, block.timestamp);
        assertEq(userAddress, user);
        assertEq(isWithdrawn, false);
        assertEq(amountS, undelegatedFromPool);

        (, validatorId, amountS, isWithdrawn, requestTimestamp, userAddress) =
            sonicStaking.allWithdrawalRequests(sonicStaking.lastUsedWrId() - 1);
        assertEq(validatorId, 1);
        assertEq(requestTimestamp, block.timestamp);
        assertEq(userAddress, user);
        assertEq(isWithdrawn, false);
        assertEq(amountS, 1000 ether);

        (, validatorId, amountS, isWithdrawn, requestTimestamp, userAddress) =
            sonicStaking.allWithdrawalRequests(sonicStaking.lastUsedWrId());
        assertEq(validatorId, 2);
        assertEq(requestTimestamp, block.timestamp);
        assertEq(userAddress, user);
        assertEq(isWithdrawn, false);
        assertEq(amountS, 3000 ether);
    }

    function testUndelegateAndWithdrawFromPoolOnly() public {
        uint256 depositAmount = 10000 ether;
        uint256 delegateAmount1 = 1000 ether;
        uint256 undelegateAmount = 1000 ether;
        uint256 toValidatorId1 = 1;

        (
            uint256 totalDelegatedStart,
            uint256 totalPoolStart,
            uint256 totalSWorthStart,
            uint256 rateStart,
            uint256 lastUsedWrIdStart
        ) = getAmounts();

        // make sure we have a deposit
        address user = makeDeposit(depositAmount);

        assertEq(totalDelegatedStart, sonicStaking.totalDelegated());
        assertEq(totalPoolStart + depositAmount, sonicStaking.totalPool());
        assertEq(totalSWorthStart + depositAmount, sonicStaking.totalSWorth());
        assertEq(rateStart, sonicStaking.getRate());
        assertEq(lastUsedWrIdStart, sonicStaking.lastUsedWrId());
        assertEq(sonicStaking.stkS().balanceOf(user), depositAmount);

        delegate(delegateAmount1, toValidatorId1);

        assertEq(totalDelegatedStart + delegateAmount1, sonicStaking.totalDelegated());
        assertEq(totalPoolStart + depositAmount - delegateAmount1, sonicStaking.totalPool());
        assertEq(totalSWorthStart + depositAmount, sonicStaking.totalSWorth());
        assertEq(rateStart, sonicStaking.getRate());
        assertEq(lastUsedWrIdStart, sonicStaking.lastUsedWrId());
        assertEq(sonicStaking.stkS().balanceOf(user), depositAmount);

        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = 1;

        vm.prank(user);
        sonicStaking.undelegate(undelegateAmount, validatorIds);
        assertEq(sonicStaking.lastUsedWrId(), 101);

        assertEq(totalDelegatedStart + delegateAmount1, sonicStaking.totalDelegated());
        assertEq(totalPoolStart + depositAmount - delegateAmount1 - undelegateAmount, sonicStaking.totalPool());
        assertEq(totalSWorthStart + depositAmount - undelegateAmount, sonicStaking.totalSWorth());
        assertEq(rateStart, sonicStaking.getRate());
        assertEq(lastUsedWrIdStart + 1, sonicStaking.lastUsedWrId());
        assertEq(sonicStaking.stkS().balanceOf(user), depositAmount - undelegateAmount);

        // need to increase time to allow for withdrawal
        vm.warp(block.timestamp + 14 days);

        uint256 balanceBefore = address(user).balance;
        vm.prank(user);
        sonicStaking.withdraw(101, false);
        assertEq(address(user).balance, balanceBefore + 1000 ether);

        assertEq(totalDelegatedStart + delegateAmount1, sonicStaking.totalDelegated());
        assertEq(totalPoolStart + depositAmount - delegateAmount1 - undelegateAmount, sonicStaking.totalPool());
        assertEq(totalSWorthStart + depositAmount - undelegateAmount, sonicStaking.totalSWorth());
        assertEq(rateStart, sonicStaking.getRate());
        assertEq(lastUsedWrIdStart + 1, sonicStaking.lastUsedWrId());
        assertEq(sonicStaking.stkS().balanceOf(user), depositAmount - undelegateAmount);

        (,,, bool isWithdrawn,,) = sonicStaking.allWithdrawalRequests(101);
        assertEq(isWithdrawn, true);
    }

    function testUndelegateWithTooLittleValidatorsProvided() public {
        uint256 depositAmount = 10000 ether;
        uint256 delegateAmount1 = 5000 ether;
        uint256 delegateAmount2 = 3000 ether;
        uint256 undelegateAmount = 6000 ether;
        uint256 toValidatorId1 = 1;
        uint256 toValidatorId2 = 2;

        (, uint256 totalPoolStart,,,) = getAmounts();

        // make sure we have a deposit
        address user = makeDeposit(depositAmount);

        delegate(delegateAmount1, toValidatorId1);
        delegate(delegateAmount2, toValidatorId2);

        assertEq(delegateAmount2 + delegateAmount1, sonicStaking.totalDelegated());
        assertEq(totalPoolStart + depositAmount - delegateAmount1 - delegateAmount2, sonicStaking.totalPool());

        // only provide validator2, which doesnt have sufficient S to undelegate
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = 2;

        vm.prank(user);
        vm.expectRevert("ERR_NOT_FULLY_UNDELEGATED");
        sonicStaking.undelegate(undelegateAmount, validatorIds);
    }

    function testStateSetters() public {
        vm.startPrank(SONIC_STAKING_OPERATOR);

        sonicStaking.setWithdrawalDelay(1);
        assertEq(sonicStaking.withdrawalDelay(), 1);

        sonicStaking.setUndelegatePaused(true);
        assertTrue(sonicStaking.undelegatePaused());

        sonicStaking.setWithdrawPaused(true);
        assertTrue(sonicStaking.withdrawPaused());

        sonicStaking.setRewardClaimPaused(true);
        assertTrue(sonicStaking.rewardClaimPaused());

        sonicStaking.setDepositLimits(1, 100);
        assertEq(sonicStaking.minDeposit(), 1);
        assertEq(sonicStaking.maxDeposit(), 100);

        sonicStaking.setProtocolFeeBIPS(100);
        assertEq(sonicStaking.protocolFeeBIPS(), 100);

        sonicStaking.setTreasury(address(this));
        assertEq(sonicStaking.treasury(), address(this));
    }

    function testStateSettersRevert() public {
        vm.startPrank(SONIC_STAKING_OPERATOR);

        vm.expectRevert("ERR_ALREADY_DESIRED_VALUE");
        sonicStaking.setUndelegatePaused(false);

        vm.expectRevert("ERR_ALREADY_DESIRED_VALUE");
        sonicStaking.setUndelegatePaused(false);

        vm.expectRevert("ERR_ALREADY_DESIRED_VALUE");
        sonicStaking.setWithdrawPaused(false);

        vm.expectRevert("ERR_ALREADY_DESIRED_VALUE");
        sonicStaking.setRewardClaimPaused(false);

        vm.expectRevert("ERR_INVALID_VALUE");
        sonicStaking.setProtocolFeeBIPS(10001);

        vm.expectRevert("ERR_INVALID_VALUE");
        sonicStaking.setTreasury(address(0));
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
        totalSWorth = sonicStaking.totalSWorth();
        rate = sonicStaking.getRate();
        lastUsedWrId = sonicStaking.lastUsedWrId();
    }
}
