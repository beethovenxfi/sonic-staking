// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "./interfaces/ISFC.sol";
import "./StakedS.sol";

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {console} from "forge-std/console.sol";

interface IRateProvider {
    function getRate() external view returns (uint256 _rate);
}

/**
 * @title Sonic Staking Contract
 * @author Beets
 * @notice Main point of interaction with Beets liquid staking for Sonic
 */
contract SonicStaking is IRateProvider, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    // These constants have been taken from the SFC contract
    uint256 public constant DECIMAL_UNIT = 1e18;

    struct WithdrawalRequest {
        uint256 validatorId;
        uint256 amountS;
        bool isWithdrawn;
        uint256 requestTimestamp;
        address user;
    }

    mapping(uint256 => WithdrawalRequest) public allWithdrawalRequests;

    mapping(uint256 => uint256) public currentDelegations;

    /**
     * @dev A reference to the StkS ERC20 token contract
     */
    StakedS public stkS;

    /**
     * @dev A reference to the SFC contract
     */
    ISFC public SFC;

    /**
     * @dev A reference to the treasury address
     */
    address public treasury;

    /**
     * @dev The protocol fee in basis points (BIPS)
     */
    uint256 public protocolFeeBIPS;

    /**
     * @dev The last known epoch to prevent wasting gas during reward claim process
     */
    uint256 public lastKnownEpoch;

    /**
     * The duration of an epoch between two successive locks
     */
    uint256 public epochDuration;

    /**
     * The delay between undelegation & withdrawal
     */
    uint256 public withdrawalDelay;

    uint256 public minDeposit;

    uint256 public maxDeposit;

    bool public undelegatePaused;

    bool public withdrawPaused;

    bool public maintenancePaused;

    /**
     * The next timestamp eligible for locking
     */
    uint256 public nextEligibleTimestamp;

    /**
     * The total Ss staked and locked
     */
    uint256 public totalSStaked;

    /**
     * The total S that is in the pool and to be staked/locked
     */
    uint256 public totalPool;

    event LogEpochDurationSet(address indexed owner, uint256 duration);
    event LogWithdrawalDelaySet(address indexed owner, uint256 delay);
    event LogUndelegatePausedUpdated(address indexed owner, bool newValue);
    event LogWithdrawPausedUpdated(address indexed owner, bool newValue);
    event LogMaintenancePausedUpdated(address indexed owner, bool newValue);
    event LogDepositLimitUpdated(address indexed owner, uint256 low, uint256 high);

    event LogDeposited(address indexed user, uint256 amount, uint256 stkSAmount);
    event LogDelegated(uint256 indexed toValidator, uint256 amount);
    event LogUndelegated(address indexed user, uint256 wrID, uint256 amountS, uint256 fromValidator);
    event LogWithdrawn(address indexed user, uint256 wrID, uint256 totalAmount, bool emergency);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /**
     * @notice Initializer
     * @param _stks_ the address of the FTM token contract (is NOT modifiable)
     * @param _sfc_ the address of the SFC contract (is NOT modifiable)
     * @param _treasury_ The address of the treasury where fees are sent to (is modifiable)
     */
    function initialize(StakedS _stks_, ISFC _sfc_, address _treasury_) public initializer {
        stkS = _stks_;
        SFC = _sfc_;
        treasury = _treasury_;
        epochDuration = 3600; // one hour
        withdrawalDelay = 604800 * 2; // 14 days
        minDeposit = 1 ether;
        maxDeposit = 100 ether;
        undelegatePaused = false;
        withdrawPaused = false;
        maintenancePaused = false;
        protocolFeeBIPS = 1000;
    }

    /*******************************
     * Getter & helper functions   *
     *******************************/

    /**
     * @notice Retruns the amount of delegated S to a specific validator.
     * @param validatorId the id of the validator
     */
    function getDelegationAmount(uint256 validatorId) external view returns (uint256) {
        return currentDelegations[validatorId];
    }

    /**
     * @notice Returns the current S worth of the protocol
     *
     * Considers:
     *  - current staked S
     *  - current unstaked S
     */
    function totalSWorth() public view returns (uint256) {
        return totalPool + totalSStaked;
    }

    /**
     * @notice Returns the amount of S equivalent 1 StkS (with 18 decimals)
     */
    function getExchangeRate() public view returns (uint256) {
        uint256 totalS = totalSWorth();
        uint256 totalStkS = stkS.totalSupply();

        if (totalS == 0 || totalStkS == 0) {
            return 1 * DECIMAL_UNIT;
        }
        return (totalS * DECIMAL_UNIT) / totalStkS;
    }

    function getRate() public view override returns (uint256) {
        return getExchangeRate();
    }

    /**
     * @notice Returns the amount of StkS equivalent to the provided S
     * @param sAmount the amount of S
     */
    function getStkSAmountForS(uint256 sAmount) public view returns (uint256) {
        uint256 totalS = totalSWorth();
        uint256 totalStkS = stkS.totalSupply();

        if (totalS == 0 || totalStkS == 0) {
            return sAmount;
        }
        return (sAmount * totalStkS) / totalS;
    }

    /**********************
     * Admin functions   *
     **********************/

    /**
     * @notice Delegate from the pool to a specific validator for MAX_LOCKUP_DURATION
     * @param amount the amount to lock
     * @param toValidatorId the ID of the validator to delegate to
     */
    function delegate(uint256 amount, uint256 toValidatorId) external onlyOwner {
        require(_now() >= nextEligibleTimestamp, "ERR_WAIT_FOR_NEXT_EPOCH");
        require(amount > 0 && amount <= totalPool, "ERR_INVALID_AMOUNT");

        nextEligibleTimestamp += epochDuration;

        SFC.delegate{value: amount}(toValidatorId);

        currentDelegations[toValidatorId] += amount;

        totalSStaked += amount;
        totalPool -= amount;

        emit LogDelegated(toValidatorId, amount);
    }

    /**
     * @notice Undelegate StkS, corresponding S can then be withdrawn to the pool after `withdrawalDelay`
     * @param amountToUndelegate the amount of S to undelegate from given validator
     * @param fromValidator the validator to undelegate from
     */
    function undelegateToPool(uint256 amountToUndelegate, uint256 fromValidator) external onlyOwner {
        require(amountToUndelegate > 0, "ERR_ZERO_AMOUNT");

        uint256 delegatedAmount = currentDelegations[fromValidator];
        require(delegatedAmount > 0, "ERR_NO_DELEGATION");

        uint256 wrId = block.timestamp + block.number; // TODO does that number become too big at some point?
        _undelegateFromValidator(fromValidator, wrId, amountToUndelegate);
    }

    /**
     * @notice Withdraw undelegated S to the pool
     * @param wrId the unique wrID for the undelegation request
     */
    function withdrawToPool(uint256 wrId) external onlyOwner {
        WithdrawalRequest storage request = allWithdrawalRequests[wrId];

        require(request.requestTimestamp > 0, "ERR_WRID_INVALID");
        require(_now() >= request.requestTimestamp + withdrawalDelay, "ERR_NOT_ENOUGH_TIME_PASSED");
        require(!request.isWithdrawn, "ERR_ALREADY_WITHDRAWN");
        request.isWithdrawn = true;

        address user = request.user;
        require(msg.sender == user, "ERR_UNAUTHORIZED");

        uint256 balanceBefore = address(this).balance;

        SFC.withdraw(request.validatorId, wrId);

        uint256 withdrawnAmount = address(this).balance - balanceBefore;

        totalSStaked -= withdrawnAmount;
        totalPool += withdrawnAmount;

        emit LogWithdrawn(user, wrId, request.amountS, false);
    }

    /**
     * @notice Set epoch duration (onlyOwner)
     * @param duration the new epoch duration
     */
    function setEpochDuration(uint256 duration) external onlyOwner {
        epochDuration = duration;
        emit LogEpochDurationSet(msg.sender, duration);
    }

    /**
     * @notice Set withdrawal delay (onlyOwner)
     * @param delay the new delay
     */
    function setWithdrawalDelay(uint256 delay) external onlyOwner {
        withdrawalDelay = delay;
        emit LogWithdrawalDelaySet(msg.sender, delay);
    }

    /**
     * @notice Pause/unpause user undelegations (onlyOwner)
     * @param desiredValue the desired value of the switch
     */
    function setUndelegatePaused(bool desiredValue) external onlyOwner {
        require(undelegatePaused != desiredValue, "ERR_ALREADY_DESIRED_VALUE");
        undelegatePaused = desiredValue;
        emit LogUndelegatePausedUpdated(msg.sender, desiredValue);
    }

    /**
     * @notice Pause/unpause user withdrawals (onlyOwner)
     * @param desiredValue the desired value of the switch
     */
    function setWithdrawPaused(bool desiredValue) external onlyOwner {
        require(withdrawPaused != desiredValue, "ERR_ALREADY_DESIRED_VALUE");
        withdrawPaused = desiredValue;
        emit LogWithdrawPausedUpdated(msg.sender, desiredValue);
    }

    /**
     * @notice Pause/unpause maintenance functions (onlyOwner)
     * @param desiredValue the desired value of the switch
     */
    function setMaintenancePaused(bool desiredValue) external onlyOwner {
        require(maintenancePaused != desiredValue, "ERR_ALREADY_DESIRED_VALUE");
        maintenancePaused = desiredValue;
        emit LogMaintenancePausedUpdated(msg.sender, desiredValue);
    }

    function setDepositLimits(uint256 low, uint256 high) external onlyOwner {
        minDeposit = low;
        maxDeposit = high;
        emit LogDepositLimitUpdated(msg.sender, low, high);
    }

    /**
     * @notice Update the treasury address
     * @param newTreasury the new treasury address
     */
    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "ERR_INVALID_VALUE");
        treasury = newTreasury;
    }

    /**
     * @notice Update the protocol fee
     * @param newFeeBIPS the value of the fee (in BIPS)
     */
    function setProtocolFeeBIPS(uint256 newFeeBIPS) external onlyOwner {
        require(newFeeBIPS <= 10_000, "ERR_INVALID_VALUE");
        protocolFeeBIPS = newFeeBIPS;
    }

    /**********************
     * End User Functions *
     **********************/

    /**
     * @notice Deposit S, and mint StkS
     */
    function deposit() external payable {
        uint256 amount = msg.value;
        require(amount >= minDeposit && amount <= maxDeposit, "ERR_AMOUNT_OUTSIDE_LIMITS");

        uint256 StkSAmount = getStkSAmountForS(amount);
        stkS.mint(msg.sender, StkSAmount);

        totalPool += amount;

        emit LogDeposited(msg.sender, msg.value, StkSAmount);
    }

    /**
     * @notice Undelegate StkS, corresponding S can then be withdrawn after `withdrawalDelay`
     * @param amountStkS the amount of StkS to undelegate
     * @param fromValidators an array of validator IDs to undelegate from
     */
    function undelegate(uint256 amountStkS, uint256[] calldata fromValidators) external {
        require(!undelegatePaused, "ERR_UNDELEGATE_IS_PAUSED");
        require(amountStkS > 0, "ERR_ZERO_AMOUNT");

        uint256 amountToUndelegate = (getExchangeRate() * amountStkS) / DECIMAL_UNIT;
        stkS.burnFrom(msg.sender, amountStkS);

        totalSStaked -= amountToUndelegate;

        for (uint256 i = 0; i < fromValidators.length; i++) {
            uint256 delegatedAmount = currentDelegations[fromValidators[i]];
            require(delegatedAmount > 0, "ERR_NO_DELEGATION");

            if (amountToUndelegate > 0) {
                // need to calculate a unique wrID for each undelegation request
                uint256 wrId = block.timestamp + block.number + i; // TODO does that number become too big at some point?

                if (amountToUndelegate <= delegatedAmount) {
                    // amountToUndelegate is less than or equal to the amount delegated to this validator, we partially undelegate from the validator.
                    // can undelegate the full `amountToUndelegate` from this validator.
                    _undelegateFromValidator(fromValidators[i], wrId, amountToUndelegate);
                    amountToUndelegate = 0;
                } else {
                    // `amountToUndelegate` is greater than the amount delegated to this validator, so we fully undelegate from the validator.
                    // `amountToUndelegate` not yet 0 and will need another loop.
                    _undelegateFromValidator(fromValidators[i], wrId, delegatedAmount);
                    amountToUndelegate -= delegatedAmount;
                }
            }
        }

        // making sure the full amount has been undelegated, guarding against wrong input and making sure the user gets the full amount back
        require(amountToUndelegate == 0, "ERR_NOT_FULLY_UNDELEGATED");
    }

    /**
     * @notice Withdraw undelegated S
     * @param wrId the unique wrID for the undelegation request
     * @param emergency flag to withdraw without checking the amount, risk to get less S than what is owed
     */
    function withdraw(uint256 wrId, bool emergency) external {
        require(!withdrawPaused, "ERR_WITHDRAW_IS_PAUSED");

        WithdrawalRequest storage request = allWithdrawalRequests[wrId];

        require(request.requestTimestamp > 0, "ERR_WRID_INVALID");
        require(_now() >= request.requestTimestamp + withdrawalDelay, "ERR_NOT_ENOUGH_TIME_PASSED");
        require(!request.isWithdrawn, "ERR_ALREADY_WITHDRAWN");
        request.isWithdrawn = true;

        address user = request.user;
        require(msg.sender == user, "ERR_UNAUTHORIZED");

        uint256 balanceBefore = address(this).balance;

        SFC.withdraw(request.validatorId, wrId);

        uint256 withdrawnAmount = address(this).balance - balanceBefore;

        // can never get more S than what is owed
        require(request.amountS <= withdrawnAmount, "ERR_WITHDRAWN_AMOUNT_TOO_HIGH");

        if (!emergency) {
            // protection against deleting the withdrawal request and going back with less S than what is owned
            // can be bypassed by setting emergency to true
            require(request.amountS == withdrawnAmount, "ERR_NOT_ENOUGH_S");
        }

        // do transfer after marking as withdrawn to protect against re-entrancy
        (bool withdrawnToUser, ) = user.call{value: request.amountS}("");
        require(withdrawnToUser, "Failed to withdraw S to user");

        emit LogWithdrawn(user, wrId, request.amountS, emergency);
    }

    /*************************
     * Maintenance Functions *
     *************************/

    /**
     * @notice Claim rewards from all contracts and add them to the pool
     * @param fromValidators an array of validator IDs to claim rewards from
     */
    function claimRewards(uint256[] calldata fromValidators) external {
        require(!maintenancePaused, "ERR_THIS_FUNCTION_IS_PAUSED");

        uint256 currentEpoch = SFC.currentEpoch();

        if (currentEpoch <= lastKnownEpoch) {
            return;
        }

        lastKnownEpoch = currentEpoch;

        uint256 balanceBefore = address(this).balance;

        for (uint256 i = 0; i < fromValidators.length; i++) {
            uint256 rewards = SFC.pendingRewards(address(this), fromValidators[i]);
            if (rewards > 0) {
                SFC.claimRewards(fromValidators[i]);
            }
        }

        if (protocolFeeBIPS > 0) {
            uint256 balanceAfter = address(this).balance;
            uint256 protocolFee = ((balanceAfter - balanceBefore) * protocolFeeBIPS) / 10_000;
            (bool protocolFeesClaimed, ) = treasury.call{value: protocolFee}("");
            require(protocolFeesClaimed, "Failed to claim protocol fees to treasury");
        }
    }

    /**********************
     * Internal functions *
     **********************/

    /**
     * @notice Undelegate from the validator.
     * @param validatorId the validator to undelegate
     * @param wrId the withdrawal ID for the withdrawal request
     * @param amount the amount to unlock
     */
    function _undelegateFromValidator(uint256 validatorId, uint256 wrId, uint256 amount) internal {
        // create a new withdrawal request
        WithdrawalRequest storage request = allWithdrawalRequests[wrId];
        require(request.requestTimestamp == 0, "ERR_WRID_ALREADY_USED");
        request.requestTimestamp = _now();
        request.user = msg.sender;
        request.amountS = amount;
        request.validatorId = validatorId;
        request.isWithdrawn = false;

        SFC.undelegate(validatorId, wrId, amount);
        currentDelegations[validatorId] -= amount;

        emit LogUndelegated(msg.sender, wrId, amount, validatorId);
    }

    function _now() internal view returns (uint256) {
        return block.timestamp;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice To receive S rewards from SFC
     */
    receive() external payable {}
}
