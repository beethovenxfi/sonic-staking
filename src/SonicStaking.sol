// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import {ISFC} from "./interfaces/ISFC.sol";
import {IRateProvider} from "./interfaces/IRateProvider.sol";

import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20Upgradeable} from "openzeppelin-contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from
    "openzeppelin-contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PermitUpgradeable} from
    "openzeppelin-contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title Sonic Staking Contract
 * @author Beets
 * @notice Main point of interaction with Beets liquid staking for Sonic
 */
contract SonicStaking is
    IRateProvider,
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PermitUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    AccessControlUpgradeable
{
    // These constants have been taken from the SFC contract
    uint256 public constant DECIMAL_UNIT = 1e18;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant CLAIM_ROLE = keccak256("CLAIM_ROLE");

    uint256 public constant MAX_PROTOCOL_FEE_BIPS = 10_000;
    uint256 public constant MIN_DEPOSIT = 1 ether;

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

    bool public depositPaused;

    bool public undelegatePaused;

    bool public withdrawPaused;

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

    event WithdrawDelaySet(address indexed owner, uint256 delay);
    event UndelegatePausedUpdated(address indexed owner, bool newValue);
    event WithdrawPausedUpdated(address indexed owner, bool newValue);
    event DepositPausedUpdated(address indexed owner, bool newValue);

    event Deposited(address indexed user, uint256 assetAmount, uint256 wrappedAmount);
    event Delegated(uint256 indexed toValidator, uint256 assetAmount);
    event Undelegated(
        address indexed user, uint256 withdarwId, uint256 assetAmount, uint256 fromValidator, WithdrawKind kind
    );
    event Withdrawn(address indexed user, uint256 withdarwId, uint256 assetAmount, WithdrawKind kind, bool emergency);

    error DelegateAmountCannotBeZero();
    error DelegateAmountLargerThanPool();
    error UndelegateAmountCannotBeZero();
    error NoDelegationForValidator(uint256 validatorId);
    error UndelegateAmountExceedsDelegated();
    error WithdrawIdDoesNotExist();
    error WithdrawDelayNotElapsed(uint256 earliestWithdrawTime);
    error WithdrawAlreadyProcessed();
    error UnauthorizedWithdraw();
    error TreasuryAddressCannotBeZero();
    error ProtocolFeeTooHigh();
    error DepositTooSmall();
    error DepositPaused();
    error UndelegationPaused();
    error WithdrawsPaused();
    error RewardClaimingPaused();
    error WithdrawnAmountTooHigh();
    error WithdrawnAmountTooLow();
    error NativeTransferFailed();
    error ProtocolFeeTransferFailed();
    error PausedValueDidNotChange();
    error UnableToUndelegateFullAmountFromSpecifiedValidators();
    error UndelegateAmountExceedsPool();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /**
     * @notice Initializer
     * @param _sfc the address of the SFC contract (is NOT modifiable)
     * @param _treasury The address of the treasury where fees are sent to (is modifiable)
     */
    function initialize(ISFC _sfc, address _treasury) public initializer {
        __ERC20_init("Beets Staked Sonic", "stS");
        __ERC20Burnable_init();
        __ERC20Permit_init("Beets Staked Sonic");

        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        SFC = _sfc;
        treasury = _treasury;
        withdrawDelay = 604800 * 2; // 14 days
        undelegatePaused = false;
        withdrawPaused = false;
        depositPaused = false;
        protocolFeeBIPS = 1000;
        withdrawCounter = 100;
    }

    /**
     *
     * Getter & helper functions
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
     * @notice Returns the amount of asset equivalent to 1 share (with 18 decimals)
     */
    function getRate() public view returns (uint256) {
        return convertToAssets(1e18);
    }

    /**
     * @notice Returns the amount of share equivalent to the provided number of assets
     * @param assetAmount the amount of assets to convert
     */
    function convertToShares(uint256 assetAmount) public view returns (uint256) {
        uint256 assetsTotal = totalAssets();
        uint256 totalShares = totalSupply();

        if (assetsTotal == 0 || totalShares == 0) {
            return assetAmount;
        }

        return (assetAmount * totalShares) / assetsTotal;
    }

    function convertToAssets(uint256 sharesAmount) public view returns (uint256) {
        uint256 assetsTotal = totalAssets();
        uint256 totalShares = totalSupply();

        if (assetsTotal == 0 || totalShares == 0) {
            return sharesAmount;
        }

        return (sharesAmount * assetsTotal) / totalShares;
    }

    /**
     *
     * OPERATOR functions
     *
     */

    /**
     * @notice Delegate from the pool to a specific validator
     * @param amount the amount of assets to delegate
     * @param validatorId the ID of the validator to delegate to
     */
    function delegate(uint256 amount, uint256 validatorId) external onlyRole(OPERATOR_ROLE) {
        require(amount > 0, DelegateAmountCannotBeZero());
        require(amount <= totalPool, DelegateAmountLargerThanPool());

        totalPool -= amount;
        totalDelegated += amount;

        SFC.delegate{value: amount}(validatorId);

        emit Delegated(validatorId, amount);
    }

    /**
     * @notice Undelegate assets, assets can then be withdrawn to the pool after `withdrawDelay`
     * @param amount the amount of assets to undelegate from given validator
     * @param validatorId the validator to undelegate from
     */
    function operatorUndelegateToPool(uint256 amount, uint256 validatorId) external onlyRole(OPERATOR_ROLE) {
        require(amount > 0, UndelegateAmountCannotBeZero());

        uint256 delegatedAmount = SFC.getStake(address(this), validatorId);

        require(delegatedAmount > 0, NoDelegationForValidator(validatorId));
        require(amount <= delegatedAmount, UndelegateAmountExceedsDelegated());

        _undelegateFromValidator(validatorId, amount);

        pendingOperatorWithdraw += amount;
    }

    /**
     * @notice Withdraw undelegated assets to the pool
     * @param withdrawId the unique withdrawId for the undelegation request
     * @param emergency flag to withdraw without checking the amount, risk to get less assets than what is owed
     */
    function operatorWithdrawToPool(uint256 withdrawId, bool emergency)
        external
        onlyRole(OPERATOR_ROLE)
        withValidWithdrawId(withdrawId)
    {
        WithdrawRequest storage request = allWithdrawRequests[withdrawId];

        request.isWithdrawn = true;

        uint256 balanceBefore = address(this).balance;

        SFC.withdraw(request.validatorId, withdrawId);

        // in the instance of a slahing event, the amount withdrawn will not match the request amount.
        // We track the change of balance for the contract to get the actual amount withdrawn.
        uint256 actualWithdrawnAmount = address(this).balance - balanceBefore;

        if (!emergency) {
            // In the instance of a slashing event, the amount withdrawn will not match the request amount.
            // The operator must acknowledge this by setting emergency to true and accept that a drop in the rate will occur.
            require(request.assetAmount == actualWithdrawnAmount, WithdrawnAmountTooLow());
        }

        // we need to subtract the request amount from the pending amount since that is the value that was added during
        // the operator undelegate
        pendingOperatorWithdraw -= request.assetAmount;

        // We then account for the actual amount we were able to withdraw
        // In the instance of a realized slashing event, this will result in a drop in the rate.
        totalPool += actualWithdrawnAmount;
    }

    /**
     * @notice Pause all protocol functions
     * @dev The operator is given the power to pause the protocol, giving them the power to take action in the case of
     *      an emergency. Enabling the protocol is reserved for the admin.
     */
    function pause() external onlyRole(OPERATOR_ROLE) {
        _setDepositPaused(true);
        _setUndelegatePaused(true);
        _setWithdrawPaused(true);
    }

    /**
     *
     * OWNER functions
     *
     */

    /**
     * @notice Set withdraw delay
     * @param delay the new delay
     */
    function setWithdrawDelay(uint256 delay) external onlyOwner {
        withdrawDelay = delay;
        emit WithdrawDelaySet(msg.sender, delay);
    }

    /**
     * @notice Pause/unpause user undelegations
     * @param newValue the desired value of the switch
     */
    function setUndelegatePaused(bool newValue) external onlyOwner {
        _setUndelegatePaused(newValue);
    }

    /**
     * @notice Pause/unpause user withdraws
     * @param newValue the desired value of the switch
     */
    function setWithdrawPaused(bool newValue) external onlyOwner {
        _setWithdrawPaused(newValue);
    }

    /**
     * @notice Pause/unpause deposit function
     * @param newValue the desired value of the switch
     */
    function setDepositPaused(bool newValue) external onlyOwner {
        _setDepositPaused(newValue);
    }

    /**
     * @notice Update the treasury address
     * @param newTreasury the new treasury address
     */
    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), TreasuryAddressCannotBeZero());

        treasury = newTreasury;
    }

    /**
     * @notice Update the protocol fee
     * @param newFeeBIPS the value of the fee (in BIPS)
     */
    function setProtocolFeeBIPS(uint256 newFeeBIPS) external onlyOwner {
        require(newFeeBIPS <= MAX_PROTOCOL_FEE_BIPS, ProtocolFeeTooHigh());

        protocolFeeBIPS = newFeeBIPS;
    }

    /**
     *
     * End User Functions
     *
     */

    /**
     * @notice Deposit assets, and mint shares
     */
    function deposit() external payable {
        uint256 amount = msg.value;
        require(amount >= MIN_DEPOSIT, DepositTooSmall());
        require(!depositPaused, DepositPaused());

        address user = msg.sender;
        uint256 sharesAmount = convertToShares(amount);

        _mint(user, sharesAmount);

        totalPool += amount;

        emit Deposited(user, amount, sharesAmount);
    }

    /**
     * @notice Undelegate asset, assets can then be withdrawn after `withdrawDelay`
     * @dev We leave it to off-chain infra to optimize for the fewest number of validators, as each validator creates
     *      an additional withdraw request.
     * @param amountShares the amount of shares to undelegate
     * @param validatorIds an array of validator IDs to undelegate from
     */
    function undelegate(uint256 amountShares, uint256[] calldata validatorIds) external {
        require(!undelegatePaused, UndelegationPaused());
        require(amountShares > 0, UndelegateAmountCannotBeZero());

        uint256 amountToUndelegate = convertToAssets(amountShares);

        _burn(msg.sender, amountShares);

        for (uint256 i = 0; i < validatorIds.length; i++) {
            uint256 amountDelegated = SFC.getStake(address(this), validatorIds[i]);

            require(amountDelegated > 0, NoDelegationForValidator(validatorIds[i]));

            if (amountToUndelegate > amountDelegated) {
                _undelegateFromValidator(validatorIds[i], amountDelegated);
                amountToUndelegate -= amountDelegated;
            } else {
                _undelegateFromValidator(validatorIds[i], amountToUndelegate);
                amountToUndelegate = 0;
                // we've undelegated the full amount, no need to continue
                break;
            }
        }

        // check that the full amount has been undelegated
        require(amountToUndelegate == 0, UnableToUndelegateFullAmountFromSpecifiedValidators());
    }

    /**
     * @notice Undelegate from the pool.
     * @param amountShares the amount of shares to undelegate
     */
    function undelegateFromPool(uint256 amountShares) external {
        require(amountShares > 0, UndelegateAmountCannotBeZero());

        uint256 amountToUndelegate = convertToAssets(amountShares);

        require(amountToUndelegate <= totalPool, UndelegateAmountExceedsPool());

        _burn(msg.sender, amountShares);

        uint256 withdrawId = _createWithdrawRequest(WithdrawKind.POOL, 0, amountToUndelegate);

        totalPool -= amountToUndelegate;

        emit Undelegated(msg.sender, withdrawId, amountToUndelegate, 0, WithdrawKind.POOL);
    }

    /**
     * @notice Withdraw undelegated assets
     * @param withdrawId the unique withdraw id for the undelegation request
     * @param emergency flag to withdraw without checking the amount, risk to get less assets than what is owed
     */
    function withdraw(uint256 withdrawId, bool emergency) public withValidWithdrawId(withdrawId) {
        require(!withdrawPaused, WithdrawsPaused());

        WithdrawRequest storage request = allWithdrawRequests[withdrawId];

        request.isWithdrawn = true;

        uint256 withdrawnAmount = 0;

        if (request.kind == WithdrawKind.POOL) {
            withdrawnAmount = request.assetAmount;
        } else {
            uint256 balanceBefore = address(this).balance;

            SFC.withdraw(request.validatorId, withdrawId);
            withdrawnAmount = address(this).balance - balanceBefore;

            // can never get more assets than what is owed
            require(withdrawnAmount <= request.assetAmount, WithdrawnAmountTooHigh());

            if (!emergency) {
                // In the instance of a slashing event, the amount withdrawn will not match the request amount.
                // The user must acknowledge this by setting emergency to true. Since the user is absorbing
                // this loss, there is no impact on the rate.
                require(request.assetAmount == withdrawnAmount, WithdrawnAmountTooLow());
            }
        }

        address user = msg.sender;
        (bool withdrawnToUser,) = user.call{value: withdrawnAmount}("");
        require(withdrawnToUser, NativeTransferFailed());

        emit Withdrawn(user, withdrawId, withdrawnAmount, request.kind, emergency);
    }

    /**
     * @notice Withdraw undelegated assets for a list of withdrawIds
     * @param withdrawIds the unique withdraw ids for the undelegation requests
     * @param emergency flag to withdraw without checking the amount, risk to get less assets than what is owed
     */
    function withdrawMany(uint256[] calldata withdrawIds, bool emergency) external {
        for (uint256 i = 0; i < withdrawIds.length; i++) {
            withdraw(withdrawIds[i], emergency);
        }
    }

    /**
     * @notice Claim rewards from all contracts and add them to the pool
     * @param validatorIds an array of validator IDs to claim rewards from
     */
    function claimRewards(uint256[] calldata validatorIds) external onlyRole(CLAIM_ROLE) {
        uint256 balanceBefore = address(this).balance;

        for (uint256 i = 0; i < validatorIds.length; i++) {
            uint256 rewards = SFC.pendingRewards(address(this), validatorIds[i]);

            if (rewards > 0) {
                SFC.claimRewards(validatorIds[i]);
            }
        }

        uint256 totalRewardsClaimed = address(this).balance - balanceBefore;
        uint256 protocolFee = 0;

        if (totalRewardsClaimed > 0 && protocolFeeBIPS > 0) {
            protocolFee = (totalRewardsClaimed * protocolFeeBIPS) / MAX_PROTOCOL_FEE_BIPS;

            (bool protocolFeesClaimed,) = treasury.call{value: protocolFee}("");
            require(protocolFeesClaimed, ProtocolFeeTransferFailed());
        }

        totalPool += totalRewardsClaimed - protocolFee;
    }

    /**
     *
     * Internal functions
     *
     */

    /**
     * @notice Undelegate from the validator.
     * @param validatorId the validator to undelegate
     * @param amount the amount to undelegate
     */
    function _undelegateFromValidator(uint256 validatorId, uint256 amount) internal {
        uint256 withdrawId = _createWithdrawRequest(WithdrawKind.VALIDATOR, validatorId, amount);

        SFC.undelegate(validatorId, withdrawId, amount);

        totalDelegated -= amount;

        emit Undelegated(msg.sender, withdrawId, amount, validatorId, WithdrawKind.VALIDATOR);
    }

    function _createWithdrawRequest(WithdrawKind kind, uint256 validatorId, uint256 amount)
        internal
        returns (uint256 withdrawId)
    {
        withdrawId = _incrementWithdrawCounter();
        WithdrawRequest storage request = allWithdrawRequests[withdrawId];

        request.kind = kind;
        request.requestTimestamp = _now();
        request.user = msg.sender;
        request.assetAmount = amount;
        request.validatorId = validatorId;
        request.isWithdrawn = false;
    }

    function _now() internal view returns (uint256) {
        return block.timestamp;
    }

    function _incrementWithdrawCounter() internal returns (uint256) {
        withdrawCounter++;

        return withdrawCounter;
    }

    function _setUndelegatePaused(bool newValue) internal {
        require(undelegatePaused != newValue, PausedValueDidNotChange());

        undelegatePaused = newValue;
        emit UndelegatePausedUpdated(msg.sender, newValue);
    }

    function _setWithdrawPaused(bool newValue) internal {
        require(withdrawPaused != newValue, PausedValueDidNotChange());

        withdrawPaused = newValue;
        emit WithdrawPausedUpdated(msg.sender, newValue);
    }

    function _setDepositPaused(bool newValue) internal {
        require(depositPaused != newValue, PausedValueDidNotChange());

        depositPaused = newValue;

        emit DepositPausedUpdated(msg.sender, newValue);
    }

    modifier withValidWithdrawId(uint256 withdrawId) {
        WithdrawRequest storage request = allWithdrawRequests[withdrawId];
        uint256 earliestWithdrawTime = request.requestTimestamp + withdrawDelay;

        require(request.requestTimestamp > 0, WithdrawIdDoesNotExist());
        require(_now() >= earliestWithdrawTime, WithdrawDelayNotElapsed(earliestWithdrawTime));
        require(!request.isWithdrawn, WithdrawAlreadyProcessed());
        require(msg.sender == request.user, UnauthorizedWithdraw());

        _;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice To receive native asset rewards from SFC
     */
    receive() external payable {}
}
