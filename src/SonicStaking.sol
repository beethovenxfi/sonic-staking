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

    enum WithdrawKind {
        POOL,
        VALIDATOR
    }

    struct WithdrawRequest {
        WithdrawKind kind;
        uint256 validatorId;
        uint256 assetAmount;
        bool isWithdrawn;
        uint256 requestTimestamp;
        address user;
    }

    mapping(uint256 withdrawId => WithdrawRequest request) public allWithdrawRequests;

    /**
     * @dev A reference to the wrapped asset ERC20 token contract
     */
    StakedS public wrapped;

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
     * The delay between undelegation & withdraw
     */
    uint256 public withdrawDelay;

    uint256 public minDeposit;

    uint256 public maxDeposit;

    bool public undelegatePaused;

    bool public withdrawPaused;

    bool public rewardClaimPaused;

    /**
     * The total assets delegated to validators
     */
    uint256 public totalDelegated;

    /**
     * The total assets that is in the pool
     */
    uint256 public totalPool;

    /**
     * The total amount of asset that is pending withdraw from the operator which will be withdrawn to the pool.
     */
    uint256 public pendingOperatorWithdraw;

    uint256 public withdrawCounter;

    event withdrawDelaySet(address indexed owner, uint256 delay);
    event UndelegatePausedUpdated(address indexed owner, bool newValue);
    event WithdrawPausedUpdated(address indexed owner, bool newValue);
    event RewardClaimPausedUpdated(address indexed owner, bool newValue);
    event DepositLimitUpdated(address indexed owner, uint256 min, uint256 max);

    event Deposited(address indexed user, uint256 assetAmount, uint256 wrappedAmount);
    event Delegated(uint256 indexed toValidator, uint256 assetAmount);
    event Undelegated(
        address indexed user, uint256 wrID, uint256 assetAmount, uint256 fromValidator, WithdrawKind kind
    );
    event Withdrawn(address indexed user, uint256 wrID, uint256 assetAmount, WithdrawKind kind, bool emergency);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /**
     * @notice Initializer
     * @param _wrappedToken_ the address of the wrapped token contract (is NOT modifiable)
     * @param _sfc_ the address of the SFC contract (is NOT modifiable)
     * @param _treasury_ The address of the treasury where fees are sent to (is modifiable)
     */
    function initialize(StakedS _wrappedToken_, ISFC _sfc_, address _treasury_) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        wrapped = _wrappedToken_;
        SFC = _sfc_;
        treasury = _treasury_;
        withdrawDelay = 604800 * 2; // 14 days
        minDeposit = 1 ether;
        maxDeposit = 1_000_000 ether;
        undelegatePaused = false;
        withdrawPaused = false;
        rewardClaimPaused = false;
        protocolFeeBIPS = 1000;
        withdrawCounter = 100;
    }

    /**
     *
     * Getter & helper functions   *
     *
     */

    /**
     * @notice Returns the current asset worth of the protocol
     *
     * Considers:
     *  - current staked assets
     *  - current delegated assets
     *  - pending operator withdraws
     */
    function totalAssets() public view returns (uint256) {
        return totalPool + totalDelegated + pendingOperatorWithdraw;
    }

    /**
     * @notice Returns the amount of asset equivalent 1 wrapped asset (with 18 decimals)
     */
    function getRate() public view returns (uint256) {
        uint256 assetTotal = totalAssets();
        uint256 totalWrapped = wrapped.totalSupply();

        if (assetTotal == 0 || totalWrapped == 0) {
            return 1 * DECIMAL_UNIT;
        }
        return (assetTotal * DECIMAL_UNIT) / totalWrapped;
    }

    /**
     * @notice Returns the amount of wrapped asset equivalent to the provided asset
     * @param assetAmount the amount of asset to convert
     */
    function convertToShares(uint256 assetAmount) public view returns (uint256) {
        uint256 assetTotal = totalAssets();
        uint256 totalWrapped = wrapped.totalSupply();

        if (assetTotal == 0 || totalWrapped == 0) {
            return assetAmount;
        }
        return (assetAmount * totalWrapped) / assetTotal;
    }

    /**
     *
     * Admin functions   *
     *
     */

    /**
     * @notice Delegate from the pool to a specific validator
     * @param amount the amount to delegate
     * @param toValidatorId the ID of the validator to delegate to
     */
    function delegate(uint256 amount, uint256 toValidatorId) external onlyRole(OPERATOR_ROLE) {
        require(amount > 0 && amount <= totalPool, "ERR_INVALID_AMOUNT");

        totalPool -= amount;

        SFC.delegate{value: amount}(toValidatorId);

        totalDelegated += amount;

        emit Delegated(toValidatorId, amount);
    }

    /**
     * @notice Undelegate assets, assets can then be withdrawn to the pool after `withdrawDelay`
     * @param amountToUndelegate the amount of assets to undelegate from given validator
     * @param fromValidatorId the validator to undelegate from
     */
    function operatorUndelegateToPool(uint256 amountToUndelegate, uint256 fromValidatorId)
        external
        onlyRole(OPERATOR_ROLE)
    {
        require(amountToUndelegate > 0, "ERR_ZERO_AMOUNT");

        uint256 delegatedAmount = SFC.getStake(address(this), fromValidatorId);
        require(delegatedAmount > 0, "ERR_NO_DELEGATION");
        require(amountToUndelegate <= delegatedAmount, "ERR_AMOUNT_TOO_HIGH");

        _undelegateFromValidator(fromValidatorId, amountToUndelegate);

        pendingOperatorWithdraw += amountToUndelegate;
    }

    /**
     * @notice Withdraw undelegated assets to the pool
     * @param wrId the unique wrID for the undelegation request
     */
    function operatorWithdrawToPool(uint256 wrId) external onlyRole(OPERATOR_ROLE) {
        WithdrawRequest storage request = allWithdrawRequests[wrId];

        require(request.requestTimestamp > 0, "ERR_WRID_INVALID");
        require(_now() >= request.requestTimestamp + withdrawDelay, "ERR_NOT_ENOUGH_TIME_PASSED");
        require(!request.isWithdrawn, "ERR_ALREADY_WITHDRAWN");

        request.isWithdrawn = true;

        require(msg.sender == request.user, "ERR_UNAUTHORIZED");

        uint256 balanceBefore = address(this).balance;

        SFC.withdraw(request.validatorId, wrId);

        // in the instance of a slahing event, the amount withdrawn will not match the request amount.
        // We track the change of balance for the contract to get the actual amount withdrawn.
        uint256 actualWithdrawnAmount = address(this).balance - balanceBefore;

        // we need to subtract the request amount from the pending amount since that is the value that was added during
        // the operator undelegate
        pendingOperatorWithdraw -= request.assetAmount;

        // We then account for the actual amount we were able to withdraw
        // In the instance of a realized slashing event, this will result in a drop in the rate.
        totalPool += actualWithdrawnAmount;
    }

    /**
     * @notice Set withdraw delay onlyRole(OPERATOR_ROLE)
     * @param delay the new delay
     */
    function setWithdrawDelay(uint256 delay) external onlyRole(OPERATOR_ROLE) {
        withdrawDelay = delay;
        emit withdrawDelaySet(msg.sender, delay);
    }

    /**
     * @notice Pause/unpause user undelegations onlyRole(OPERATOR_ROLE)
     * @param desiredValue the desired value of the switch
     */
    function setUndelegatePaused(bool desiredValue) external onlyRole(OPERATOR_ROLE) {
        require(undelegatePaused != desiredValue, "ERR_ALREADY_DESIRED_VALUE");
        undelegatePaused = desiredValue;
        emit UndelegatePausedUpdated(msg.sender, desiredValue);
    }

    /**
     * @notice Pause/unpause user withdraws onlyRole(OPERATOR_ROLE)
     * @param desiredValue the desired value of the switch
     */
    function setWithdrawPaused(bool desiredValue) external onlyRole(OPERATOR_ROLE) {
        require(withdrawPaused != desiredValue, "ERR_ALREADY_DESIRED_VALUE");
        withdrawPaused = desiredValue;
        emit WithdrawPausedUpdated(msg.sender, desiredValue);
    }

    /**
     * @notice Pause/unpause reward claiming functions onlyRole(OPERATOR_ROLE)
     * @param desiredValue the desired value of the switch
     */
    function setRewardClaimPaused(bool desiredValue) external onlyRole(OPERATOR_ROLE) {
        require(rewardClaimPaused != desiredValue, "ERR_ALREADY_DESIRED_VALUE");
        rewardClaimPaused = desiredValue;
        emit RewardClaimPausedUpdated(msg.sender, desiredValue);
    }

    function setDepositLimits(uint256 min, uint256 max) external onlyRole(OPERATOR_ROLE) {
        minDeposit = min;
        maxDeposit = max;
        emit DepositLimitUpdated(msg.sender, min, max);
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
     * @notice Deposit assets, and mint wrapped assets
     */
    function deposit() external payable {
        uint256 amount = msg.value;
        require(amount >= minDeposit && amount <= maxDeposit, "ERR_AMOUNT_OUTSIDE_LIMITS");

        address user = msg.sender;
        uint256 wrappedAmount = convertToShares(amount);
        wrapped.mint(user, wrappedAmount);

        totalPool += amount;

        emit Deposited(user, amount, wrappedAmount);
    }

    /**
     * @notice Undelegate asset, assets can then be withdrawn after `withdrawDelay`
     * @param amountWrappedAsset the amount of wrapped asset to undelegate
     * @param fromValidators an array of validator IDs to undelegate from
     */
    function undelegate(uint256 amountWrappedAsset, uint256[] calldata fromValidators) external {
        require(!undelegatePaused, "ERR_UNDELEGATE_IS_PAUSED");
        require(amountWrappedAsset > 0, "ERR_ZERO_AMOUNT");

        uint256 amountToUndelegate = (getRate() * amountWrappedAsset) / DECIMAL_UNIT;
        wrapped.burnFrom(msg.sender, amountWrappedAsset);

        // undelegate from the pool first
        if (totalPool > 0) {
            uint256 undelegateFromPool;

            if (amountToUndelegate > totalPool) {
                undelegateFromPool = totalPool;
            } else {
                undelegateFromPool = amountToUndelegate;
            }

            _undelegateFromPool(undelegateFromPool);
            amountToUndelegate -= undelegateFromPool;
        }

        for (uint256 i = 0; i < fromValidators.length; i++) {
            uint256 delegatedAmount = SFC.getStake(address(this), fromValidators[i]);
            require(delegatedAmount > 0, "ERR_NO_DELEGATION");

            if (amountToUndelegate > 0) {
                if (amountToUndelegate <= delegatedAmount) {
                    // amountToUndelegate is less than or equal to the amount delegated to this validator, we partially undelegate from the validator.
                    // can undelegate the full `amountToUndelegate` from this validator.
                    _undelegateFromValidator(fromValidators[i], amountToUndelegate);
                    amountToUndelegate = 0;
                } else {
                    // `amountToUndelegate` is greater than the amount delegated to this validator, so we fully undelegate from the validator.
                    // `amountToUndelegate` not yet 0 and will need another loop.
                    _undelegateFromValidator(fromValidators[i], delegatedAmount);
                    amountToUndelegate -= delegatedAmount;
                }
            }
        }

        // making sure the full amount has been undelegated, guarding against wrong input and making sure the user gets the full amount back
        require(amountToUndelegate == 0, "ERR_NOT_FULLY_UNDELEGATED");
    }

    /**
     * @notice Withdraw undelegated assets
     * @param withdrawId the unique wrID for the undelegation request
     * @param emergency flag to withdraw without checking the amount, risk to get less assets than what is owed
     */
    function withdraw(uint256 withdrawId, bool emergency) external {
        require(!withdrawPaused, "ERR_WITHDRAW_IS_PAUSED");

        WithdrawRequest storage request = allWithdrawRequests[withdrawId];

        require(request.requestTimestamp > 0, "ERR_WRID_INVALID");
        require(_now() >= request.requestTimestamp + withdrawDelay, "ERR_NOT_ENOUGH_TIME_PASSED");
        require(!request.isWithdrawn, "ERR_ALREADY_WITHDRAWN");
        request.isWithdrawn = true;

        address user = request.user;
        require(msg.sender == user, "ERR_UNAUTHORIZED");

        uint256 balanceBefore = address(this).balance;

        uint256 withdrawnAmount = 0;

        if (request.kind == WithdrawKind.POOL) {
            withdrawnAmount = request.assetAmount;
        } else {
            SFC.withdraw(request.validatorId, withdrawId);
            withdrawnAmount = address(this).balance - balanceBefore;
        }

        // can never get more assets than what is owed
        require(withdrawnAmount <= request.assetAmount, "ERR_WITHDRAWN_AMOUNT_TOO_HIGH");

        if (!emergency) {
            // protection against deleting the withdraw request and going back with less assets than what is owned
            // can be bypassed by setting emergency to true
            require(request.assetAmount == withdrawnAmount, "ERR_NOT_ENOUGH_ASSETS");
        }

        // do transfer after marking as withdrawn to protect against re-entrancy
        (bool withdrawnToUser,) = user.call{value: withdrawnAmount}("");
        require(withdrawnToUser, "Failed to withdraw asset to user");

        emit Withdrawn(user, withdrawId, request.assetAmount, request.kind, emergency);
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
     * @param amount the amount to undelegate
     */
    function _undelegateFromValidator(uint256 validatorId, uint256 amount) internal {
        // create a new withdraw request
        uint256 withdrawId = _incrementWithdrawCounter();
        WithdrawRequest storage request = allWithdrawRequests[withdrawId];
        require(request.requestTimestamp == 0, "ERR_WRID_ALREADY_USED");

        request.kind = WithdrawKind.VALIDATOR;
        request.requestTimestamp = _now();
        request.user = msg.sender;
        request.assetAmount = amount;
        request.validatorId = validatorId;
        request.isWithdrawn = false;

        SFC.undelegate(validatorId, withdrawId, amount);

        totalDelegated -= amount;

        emit Undelegated(msg.sender, withdrawId, amount, validatorId, request.kind);
    }

    /**
     * @notice Undelegate from the pool.
     * @param amount the amount to undelegate
     */
    function _undelegateFromPool(uint256 amount) internal {
        // create a new withdraw request
        uint256 withdrawId = _incrementWithdrawCounter();
        WithdrawRequest storage request = allWithdrawRequests[withdrawId];
        require(request.requestTimestamp == 0, "ERR_WRID_ALREADY_USED");

        request.kind = WithdrawKind.POOL;
        request.requestTimestamp = _now();
        request.user = msg.sender;
        request.assetAmount = amount;
        request.validatorId = 0;
        request.isWithdrawn = false;

        totalPool -= amount;

        emit Undelegated(msg.sender, withdrawId, amount, 0, request.kind);
    }

    function _now() internal view returns (uint256) {
        return block.timestamp;
    }

    function _incrementWithdrawCounter() internal returns (uint256) {
        withdrawCounter++;

        return withdrawCounter;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice To receive native asset rewards from SFC
     */
    receive() external payable {}
}
