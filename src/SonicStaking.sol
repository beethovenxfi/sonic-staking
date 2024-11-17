// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "./interfaces/ISFC.sol";
import "./StakedS.sol";

import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";

interface IRateProvider {
    function getRate() external view returns (uint256 _rate);
}

/**
 * @title Sonic Staking Contract
 * @author Beets
 * @notice Main point of interaction with Beets liquid staking for Sonic
 */
contract SonicStaking is IRateProvider, Initializable, OwnableUpgradeable, UUPSUpgradeable, AccessControlUpgradeable {
    // These constants have been taken from the SFC contract
    uint256 public constant DECIMAL_UNIT = 1e18;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

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

    bool public rewardClaimPaused;

    /**
     * The next timestamp eligible for locking
     */
    uint256 public nextEligibleTimestamp;

    /**
     * The total Ss staked and locked
     */
    uint256 public totalDelegated;

    /**
     * The total S that is in the pool and to be staked/locked
     */
    uint256 public totalPool;

    uint256 public wrIdCounter;

    event LogEpochDurationSet(address indexed owner, uint256 duration);
    event LogWithdrawalDelaySet(address indexed owner, uint256 delay);
    event LogUndelegatePausedUpdated(address indexed owner, bool newValue);
    event LogWithdrawPausedUpdated(address indexed owner, bool newValue);
    event LogRewardClaimPausedUpdated(address indexed owner, bool newValue);
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
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        stkS = _stks_;
        SFC = _sfc_;
        treasury = _treasury_;
        epochDuration = 3600 * 4; // four hours
        withdrawalDelay = 604800 * 2; // 14 days
        minDeposit = 1 ether;
        maxDeposit = 1_000_000 ether;
        undelegatePaused = false;
        withdrawPaused = false;
        rewardClaimPaused = false;
        protocolFeeBIPS = 1000;
        wrIdCounter = 100;
    }

    /**
     *
     * Getter & helper functions   *
     *
     */

    /**
     * @notice Returns the current S worth of the protocol
     *
     * Considers:
     *  - current staked S
     *  - current unstaked S
     */
    function totalSWorth() public view returns (uint256) {
        return totalPool + totalDelegated;
    }

    /**
     * @notice Returns the amount of S equivalent 1 StkS (with 18 decimals)
     */
    function getRate() public view returns (uint256) {
        uint256 totalS = totalSWorth();
        uint256 totalStkS = stkS.totalSupply();

        if (totalS == 0 || totalStkS == 0) {
            return 1 * DECIMAL_UNIT;
        }
        return (totalS * DECIMAL_UNIT) / totalStkS;
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

    /**
     *
     * Admin functions   *
     *
     */

    /**
     * @notice Delegate from the pool to a specific validator for MAX_LOCKUP_DURATION
     * @param amount the amount to lock
     * @param toValidatorId the ID of the validator to delegate to
     */
    function delegate(uint256 amount, uint256 toValidatorId) external onlyRole(OPERATOR_ROLE) {
        require(_now() >= nextEligibleTimestamp, "ERR_WAIT_FOR_NEXT_EPOCH"); // TODO: double check with SFC if needed to wait for delegation
        require(amount > 0 && amount <= totalPool, "ERR_INVALID_AMOUNT");

        nextEligibleTimestamp += epochDuration;

        SFC.delegate{value: amount}(toValidatorId);
        currentDelegations[toValidatorId] += amount;

        totalDelegated += amount;
        totalPool -= amount;

        emit LogDelegated(toValidatorId, amount);
    }

    /**
     * @notice Undelegate StkS, corresponding S can then be withdrawn to the pool after `withdrawalDelay`
     * @param amountToUndelegate the amount of S to undelegate from given validator
     * @param fromValidatorId the validator to undelegate from
     */
    function undelegateToPool(uint256 amountToUndelegate, uint256 fromValidatorId) external onlyRole(OPERATOR_ROLE) {
        require(amountToUndelegate > 0, "ERR_ZERO_AMOUNT");

        uint256 delegatedAmount = currentDelegations[fromValidatorId];
        require(delegatedAmount > 0, "ERR_NO_DELEGATION");
        require(amountToUndelegate <= delegatedAmount, "ERR_AMOUNT_TOO_HIGH");

        uint256 wrId = wrIdCounter++;
        _undelegateFromValidator(fromValidatorId, wrId, amountToUndelegate);

        // undelegateToPool has no effect on total S in the system and no stkS was burned.
        // In order to keep the rate unchanged, we need to add amount to delegatedAmount again, because it was subtracted in _undelegateFromValidator
        totalDelegated += amountToUndelegate;
    }

    /**
     * @notice Withdraw undelegated S to the pool
     * @param wrId the unique wrID for the undelegation request
     */
    function withdrawToPool(uint256 wrId) external onlyRole(OPERATOR_ROLE) {
        WithdrawalRequest storage request = allWithdrawalRequests[wrId];

        require(request.requestTimestamp > 0, "ERR_WRID_INVALID");
        require(_now() >= request.requestTimestamp + withdrawalDelay, "ERR_NOT_ENOUGH_TIME_PASSED");
        require(!request.isWithdrawn, "ERR_ALREADY_WITHDRAWN");
        request.isWithdrawn = true;

        uint256 balanceBefore = address(this).balance;

        SFC.withdraw(request.validatorId, wrId);

        uint256 withdrawnAmount = address(this).balance - balanceBefore;

        totalDelegated -= withdrawnAmount;
        totalPool += withdrawnAmount;
    }

    /**
     * @notice Set epoch duration onlyRole(OPERATOR_ROLE)
     * @param duration the new epoch duration in seconds
     */
    function setEpochDuration(uint256 duration) external onlyRole(OPERATOR_ROLE) {
        epochDuration = duration;
        emit LogEpochDurationSet(msg.sender, duration);
    }

    /**
     * @notice Set withdrawal delay onlyRole(OPERATOR_ROLE)
     * @param delay the new delay
     */
    function setWithdrawalDelay(uint256 delay) external onlyRole(OPERATOR_ROLE) {
        withdrawalDelay = delay;
        emit LogWithdrawalDelaySet(msg.sender, delay);
    }

    /**
     * @notice Pause/unpause user undelegations onlyRole(OPERATOR_ROLE)
     * @param desiredValue the desired value of the switch
     */
    function setUndelegatePaused(bool desiredValue) external onlyRole(OPERATOR_ROLE) {
        require(undelegatePaused != desiredValue, "ERR_ALREADY_DESIRED_VALUE");
        undelegatePaused = desiredValue;
        emit LogUndelegatePausedUpdated(msg.sender, desiredValue);
    }

    /**
     * @notice Pause/unpause user withdrawals onlyRole(OPERATOR_ROLE)
     * @param desiredValue the desired value of the switch
     */
    function setWithdrawPaused(bool desiredValue) external onlyRole(OPERATOR_ROLE) {
        require(withdrawPaused != desiredValue, "ERR_ALREADY_DESIRED_VALUE");
        withdrawPaused = desiredValue;
        emit LogWithdrawPausedUpdated(msg.sender, desiredValue);
    }

    /**
     * @notice Pause/unpause reward claiming functions onlyRole(OPERATOR_ROLE)
     * @param desiredValue the desired value of the switch
     */
    function setRewardClaimPaused(bool desiredValue) external onlyRole(OPERATOR_ROLE) {
        require(rewardClaimPaused != desiredValue, "ERR_ALREADY_DESIRED_VALUE");
        rewardClaimPaused = desiredValue;
        emit LogRewardClaimPausedUpdated(msg.sender, desiredValue);
    }

    function setDepositLimits(uint256 low, uint256 high) external onlyRole(OPERATOR_ROLE) {
        minDeposit = low;
        maxDeposit = high;
        emit LogDepositLimitUpdated(msg.sender, low, high);
    }

    /**
     * @notice Update the treasury address
     * @param newTreasury the new treasury address
     */
    function setTreasury(address newTreasury) external onlyRole(OPERATOR_ROLE) {
        require(newTreasury != address(0), "ERR_INVALID_VALUE");
        treasury = newTreasury;
    }

    /**
     * @notice Update the protocol fee
     * @param newFeeBIPS the value of the fee (in BIPS)
     */
    function setProtocolFeeBIPS(uint256 newFeeBIPS) external onlyRole(OPERATOR_ROLE) {
        require(newFeeBIPS <= 10_000, "ERR_INVALID_VALUE");
        protocolFeeBIPS = newFeeBIPS;
    }

    /**
     *
     * End User Functions *
     *
     */

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

        uint256 amountToUndelegate = (getRate() * amountStkS) / DECIMAL_UNIT;
        stkS.burnFrom(msg.sender, amountStkS);

        // always undelegate from pool first
        if (totalPool > 0) {
            uint256 undelegateFromPool = amountToUndelegate;
            if (undelegateFromPool > totalPool) {
                undelegateFromPool = totalPool;
            }
            _undelegateFromPool(wrIdCounter++, undelegateFromPool);
            amountToUndelegate -= undelegateFromPool;
        }

        for (uint256 i = 0; i < fromValidators.length; i++) {
            uint256 delegatedAmount = currentDelegations[fromValidators[i]];
            require(delegatedAmount > 0, "ERR_NO_DELEGATION");

            if (amountToUndelegate > 0) {
                // set current Withdrawal Request ID and increment the counter after assignment
                // wrIDs need to be unique per delegator<->validator pair
                uint256 wrId = wrIdCounter++;

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

        uint256 withdrawnAmount = 0;

        if (request.validatorId == 0) {
            withdrawnAmount = request.amountS;
        } else {
            SFC.withdraw(request.validatorId, wrId);
            withdrawnAmount = address(this).balance - balanceBefore;
        }

        // can never get more S than what is owed
        require(request.amountS <= withdrawnAmount, "ERR_WITHDRAWN_AMOUNT_TOO_HIGH");

        if (!emergency) {
            // protection against deleting the withdrawal request and going back with less S than what is owned
            // can be bypassed by setting emergency to true
            require(request.amountS == withdrawnAmount, "ERR_NOT_ENOUGH_S");
        }

        // do transfer after marking as withdrawn to protect against re-entrancy
        (bool withdrawnToUser,) = user.call{value: request.amountS}("");
        require(withdrawnToUser, "Failed to withdraw S to user");

        emit LogWithdrawn(user, wrId, request.amountS, emergency);
    }

    /**
     *
     * Maintenance Functions *
     *
     */

    /**
     * @notice Claim rewards from all contracts and add them to the pool
     * @param fromValidators an array of validator IDs to claim rewards from
     */
    function claimRewards(uint256[] calldata fromValidators) external {
        require(!rewardClaimPaused, "ERR_REWARD_CLAIM_IS_PAUSED");

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
            require(balanceAfter >= balanceBefore, "ERR_BALANCE_DECREASED");
            uint256 protocolFee = ((balanceAfter - balanceBefore) * protocolFeeBIPS) / 10_000;
            (bool protocolFeesClaimed,) = treasury.call{value: protocolFee}("");
            require(protocolFeesClaimed, "Failed to claim protocol fees to treasury");
        }
        uint256 balancerAfterFees = address(this).balance;
        require(balancerAfterFees >= balanceBefore, "ERR_BALANCE_DECREASED_AFTER_FEES");

        totalPool += balancerAfterFees - balanceBefore;
    }

    /**
     *
     * Internal functions *
     *
     */

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
        totalDelegated -= amount;

        emit LogUndelegated(msg.sender, wrId, amount, validatorId);
    }

    /**
     * @notice Undelegate from the pool.
     * @param wrId the withdrawal ID for the withdrawal request
     * @param amount the amount to unlock
     */
    function _undelegateFromPool(uint256 wrId, uint256 amount) internal {
        // create a new withdrawal request
        WithdrawalRequest storage request = allWithdrawalRequests[wrId];
        require(request.requestTimestamp == 0, "ERR_WRID_ALREADY_USED");
        request.requestTimestamp = _now();
        request.user = msg.sender;
        request.amountS = amount;
        request.validatorId = 0;
        request.isWithdrawn = false;

        totalPool -= amount;

        emit LogUndelegated(msg.sender, wrId, amount, 0);
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
