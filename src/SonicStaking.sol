// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

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
import {ReentrancyGuardUpgradeable} from "openzeppelin-contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

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
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    // These constants have been taken from the SFC contract
    uint256 public constant DECIMAL_UNIT = 1e18;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant CLAIM_ROLE = keccak256("CLAIM_ROLE");

    uint256 public constant MAX_PROTOCOL_FEE_BIPS = 10_000;
    uint256 public constant MIN_DEPOSIT = 1 ether;
    uint256 public constant MIN_UNDELEGATE_AMOUNT_SHARES = 1 ether;

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

    mapping(uint256 withdrawId => WithdrawRequest request) private _allWithdrawRequests;

    /**
     * @dev We track all withdraw ids for each user, in order to allow for easier off-chain UX.
     */
    mapping(address user => mapping(uint256 index => uint256 withdrawId)) public userWithdraws;
    mapping(address user => uint256 numWithdraws) public userNumWithdraws;

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
    event Deposited(address indexed user, uint256 amountAssets, uint256 amountShares);
    event Delegated(uint256 indexed validatorId, uint256 amountAssets);
    event Undelegated(
        address indexed user, uint256 withdrawId, uint256 validatorId, uint256 amountAssets, WithdrawKind kind
    );
    event Withdrawn(address indexed user, uint256 withdrawId, uint256 amountAssets, WithdrawKind kind, bool emergency);
    event Donated(address indexed user, uint256 amountAssets);

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
    error UndelegatePaused();
    error WithdrawsPaused();
    error RewardClaimingPaused();
    error WithdrawnAmountTooHigh();
    error WithdrawnAmountTooLow();
    error NativeTransferFailed();
    error ProtocolFeeTransferFailed();
    error PausedValueDidNotChange();
    error UndelegateAmountExceedsPool();
    error UserWithdrawsSkipTooLarge();
    error UserWithdrawsMaxSizeZero();
    error ArrayLengthMismatch();
    error UndelegateAmountTooSmall();
    error DonationAmountCannotBeZero();
    error InvariantViolated();
    error InvariantGrowthViolated();

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
        __ReentrancyGuard_init();
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
     * @dev This modifier is used to validate a given withdrawId when performing a withdraw. A valid withdraw Id:
     *      - exists
     *      - has not been processed
     *      - has passed the withdraw delay
     *      - msg.sender is the user that made the initial request
     */
    modifier withValidWithdrawId(uint256 withdrawId) {
        WithdrawRequest storage request = _allWithdrawRequests[withdrawId];
        uint256 earliestWithdrawTime = request.requestTimestamp + withdrawDelay;

        require(request.requestTimestamp > 0, WithdrawIdDoesNotExist());
        require(_now() >= earliestWithdrawTime, WithdrawDelayNotElapsed(earliestWithdrawTime));
        require(!request.isWithdrawn, WithdrawAlreadyProcessed());
        require(msg.sender == request.user, UnauthorizedWithdraw());

        _;
    }

    modifier enforceInvariant() {
        uint256 rateBefore = getRate();

        _;

        _enforceInvariant(rateBefore);
    }

    modifier enforceInvariantGrowth() {
        uint256 rateBefore = getRate();

        _;

        uint256 rateAfter = getRate();

        require(rateAfter >= rateBefore, InvariantGrowthViolated());
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
     * @dev This function is provided for native compatability with balancer pools
     */
    function getRate() public view returns (uint256) {
        return convertToAssets(1 ether);
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

    /**
     * @notice Returns the amount of asset equivalent to the provided number of shares
     * @param sharesAmount the amount of shares to convert
     */
    function convertToAssets(uint256 sharesAmount) public view returns (uint256) {
        uint256 assetsTotal = totalAssets();
        uint256 totalShares = totalSupply();

        if (assetsTotal == 0 || totalShares == 0) {
            return sharesAmount;
        }

        return (sharesAmount * assetsTotal) / totalShares;
    }

    /**
     * @notice Returns the user's withdraws
     * @param user the user to get the withdraws for
     * @param skip the number of withdraws to skip, used for pagination
     * @param maxSize the maximum number of withdraws to return. It's possible to return less than maxSize. Used for pagination.
     * @param reverseOrder whether to return the withdraws in reverse order (newest first)
     */
    function getUserWithdraws(address user, uint256 skip, uint256 maxSize, bool reverseOrder)
        public
        view
        returns (WithdrawRequest[] memory)
    {
        require(skip < userNumWithdraws[user], UserWithdrawsSkipTooLarge());
        require(maxSize > 0, UserWithdrawsMaxSizeZero());

        uint256 remaining = userNumWithdraws[user] - skip;
        uint256 size = remaining < maxSize ? remaining : maxSize;
        WithdrawRequest[] memory items = new WithdrawRequest[](size);

        for (uint256 i = 0; i < size; i++) {
            if (!reverseOrder) {
                // In chronological order we simply skip the first (older) entries
                items[i] = _allWithdrawRequests[userWithdraws[user][skip + i]];
            } else {
                // In reverse order we go back to front, skipping the last (newer) entries. Note that `remaining` will
                // equal the total count if `skip` is 0, meaning we'd start with the newest entry.
                items[i] = _allWithdrawRequests[userWithdraws[user][remaining - 1 - i]];
            }
        }

        return items;
    }

    function getWithdrawRequest(uint256 withdrawId) external view returns (WithdrawRequest memory) {
        return _allWithdrawRequests[withdrawId];
    }

    /**
     *
     * End User Functions
     *
     */

    /**
     * @notice Deposit native assets and mint shares of the LST.
     */
    function deposit() external payable enforceInvariant {
        uint256 amount = msg.value;
        require(amount >= MIN_DEPOSIT, DepositTooSmall());
        require(!depositPaused, DepositPaused());

        address user = msg.sender;

        uint256 sharesAmount = convertToShares(amount);

        _mint(user, sharesAmount);

        // Deposits are added to the pool initially. The assets are delegated to validators by the operator
        totalPool += amount;

        emit Deposited(user, amount, sharesAmount);
    }

    /**
     * @notice Undelegate staked assets. The shares are burnt from the msg.sender and a withdraw request is created.
     * The assets are withdrawable after the `withdrawDelay` has passed.
     * @param validatorId the validator to undelegate from
     * @param amountShares the amount of shares to undelegate
     */
    function undelegate(uint256 validatorId, uint256 amountShares)
        public
        nonReentrant
        enforceInvariant
        returns (uint256 withdrawId)
    {
        require(!undelegatePaused, UndelegatePaused());
        require(amountShares >= MIN_UNDELEGATE_AMOUNT_SHARES, UndelegateAmountTooSmall());

        uint256 amountAssets = convertToAssets(amountShares);
        uint256 amountDelegated = SFC.getStake(address(this), validatorId);

        require(amountAssets <= amountDelegated, UndelegateAmountExceedsDelegated());

        _burn(msg.sender, amountShares);

        withdrawId = _createAndStoreWithdrawRequest(WithdrawKind.VALIDATOR, validatorId, amountAssets);

        totalDelegated -= amountAssets;

        SFC.undelegate(validatorId, withdrawId, amountAssets);

        emit Undelegated(msg.sender, withdrawId, validatorId, amountAssets, WithdrawKind.VALIDATOR);
    }

    /**
     * @notice Undelegate staked assets from multiple validators.
     * @dev This function is provided as a convenience for bulking large undelegation requests across several
     * validators. This function is not gas optimized as we operate in an environment where gas is less of a concern.
     * We instead optimize for simpler code that is easier to reason about.
     * @param validatorIds an array of validator ids to undelegate from
     * @param amountShares an array of amounts of shares to undelegate
     */
    function undelegateMany(uint256[] calldata validatorIds, uint256[] calldata amountShares)
        external
        returns (uint256[] memory withdrawIds)
    {
        require(validatorIds.length == amountShares.length, ArrayLengthMismatch());

        withdrawIds = new uint256[](validatorIds.length);

        for (uint256 i = 0; i < validatorIds.length; i++) {
            withdrawIds[i] = undelegate(validatorIds[i], amountShares[i]);
        }
    }

    /**
     * @notice Undelegate from the pool.
     * @dev While always possible to undelegate from the pool, the standard flow is to undelegate from a validator.
     * @param amountShares the amount of shares to undelegate
     */
    function undelegateFromPool(uint256 amountShares) external enforceInvariant returns (uint256 withdrawId) {
        require(amountShares >= MIN_UNDELEGATE_AMOUNT_SHARES, UndelegateAmountTooSmall());

        uint256 amountToUndelegate = convertToAssets(amountShares);

        require(amountToUndelegate <= totalPool, UndelegateAmountExceedsPool());

        _burn(msg.sender, amountShares);

        // The validatorId is ignored for pool withdrawals
        withdrawId = _createAndStoreWithdrawRequest(WithdrawKind.POOL, 0, amountToUndelegate);

        totalPool -= amountToUndelegate;

        emit Undelegated(msg.sender, withdrawId, 0, amountToUndelegate, WithdrawKind.POOL);
    }

    /**
     * @notice Withdraw undelegated assets
     * @param withdrawId the unique withdraw id for the undelegation request
     * @param emergency flag to withdraw without checking the amount, risk to get less assets than what is owed
     */
    function withdraw(uint256 withdrawId, bool emergency)
        public
        nonReentrant
        enforceInvariant
        withValidWithdrawId(withdrawId)
        returns (uint256)
    {
        require(!withdrawPaused, WithdrawsPaused());

        WithdrawRequest storage request = _allWithdrawRequests[withdrawId];

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

        return withdrawnAmount;
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
     *
     * OPERATOR functions
     *
     */

    /**
     * @notice Delegate from the pool to a specific validator
     * @param validatorId the ID of the validator to delegate to
     * @param amount the amount of assets to delegate
     */
    function delegate(uint256 validatorId, uint256 amount)
        external
        nonReentrant
        onlyRole(OPERATOR_ROLE)
        enforceInvariant
    {
        require(amount > 0, DelegateAmountCannotBeZero());
        require(amount <= totalPool, DelegateAmountLargerThanPool());

        totalPool -= amount;
        totalDelegated += amount;

        SFC.delegate{value: amount}(validatorId);

        emit Delegated(validatorId, amount);
    }

    /**
     * @notice Undelegate assets, assets can then be withdrawn to the pool after `withdrawDelay`
     * @param validatorId the validator to undelegate from
     * @param amountAssets the amount of assets to undelegate from given validator
     */
    function operatorUndelegateToPool(uint256 validatorId, uint256 amountAssets)
        external
        nonReentrant
        onlyRole(OPERATOR_ROLE)
        enforceInvariant
        returns (uint256 withdrawId)
    {
        require(amountAssets > 0, UndelegateAmountCannotBeZero());

        uint256 delegatedAmount = SFC.getStake(address(this), validatorId);

        require(delegatedAmount > 0, NoDelegationForValidator(validatorId));
        require(amountAssets <= delegatedAmount, UndelegateAmountExceedsDelegated());

        withdrawId = _createAndStoreWithdrawRequest(WithdrawKind.VALIDATOR, validatorId, amountAssets);

        totalDelegated -= amountAssets;

        pendingOperatorWithdraw += amountAssets;

        SFC.undelegate(validatorId, withdrawId, amountAssets);

        emit Undelegated(msg.sender, withdrawId, validatorId, amountAssets, WithdrawKind.VALIDATOR);
    }

    /**
     * @notice Withdraw undelegated assets to the pool
     * @dev This is the only operation that allows for the rate to decrease.
     * @param withdrawId the unique withdrawId for the undelegation request
     * @param emergency when true, the operator acknowledges that the amount withdrawn may be less than what is owed,
     * potentially decreasing the rate.
     */
    function operatorWithdrawToPool(uint256 withdrawId, bool emergency)
        external
        nonReentrant
        onlyRole(OPERATOR_ROLE)
        withValidWithdrawId(withdrawId)
    {
        WithdrawRequest storage request = _allWithdrawRequests[withdrawId];

        request.isWithdrawn = true;

        uint256 balanceBefore = address(this).balance;
        uint256 rateBefore = getRate();

        SFC.withdraw(request.validatorId, withdrawId);

        // in the instance of a slahing event, the amount withdrawn will not match the request amount.
        // We track the change of balance for the contract to get the actual amount withdrawn.
        uint256 actualWithdrawnAmount = address(this).balance - balanceBefore;

        // we need to subtract the request amount from the pending amount since that is the value that was added during
        // the operator undelegate
        pendingOperatorWithdraw -= request.assetAmount;

        // We then account for the actual amount we were able to withdraw
        // In the instance of a realized slashing event, this will result in a drop in the rate.
        totalPool += actualWithdrawnAmount;

        if (!emergency) {
            // In the instance of a slashing event, the amount withdrawn will not match the request amount.
            // The operator must acknowledge this by setting emergency to true and accept that a drop in the rate will occur.

            // When emergency == false, we enforce the rate invariant
            _enforceInvariant(rateBefore);
        }
    }

    /**
     * @notice Donate assets to the pool
     * @dev Donations are added to the pool, causing the rate to increase. Only the operator can donate.
     */
    function donate() external payable onlyRole(OPERATOR_ROLE) enforceInvariantGrowth {
        uint256 donationAmount = msg.value;

        require(donationAmount > 0, DonationAmountCannotBeZero());

        totalPool += donationAmount;

        emit Donated(msg.sender, donationAmount);
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
     * @notice Claim rewards from all contracts and add them to the pool
     * @param validatorIds an array of validator IDs to claim rewards from
     */
    function claimRewards(uint256[] calldata validatorIds)
        external
        nonReentrant
        onlyRole(CLAIM_ROLE)
        enforceInvariantGrowth
    {
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
    function _createAndStoreWithdrawRequest(WithdrawKind kind, uint256 validatorId, uint256 amount)
        internal
        returns (uint256 withdrawId)
    {
        address user = msg.sender;
        withdrawId = _incrementWithdrawCounter();
        WithdrawRequest storage request = _allWithdrawRequests[withdrawId];

        request.kind = kind;
        request.requestTimestamp = _now();
        request.user = user;
        request.assetAmount = amount;
        request.validatorId = validatorId;
        request.isWithdrawn = false;

        // We store the user's withdraw ids to allow for easier off-chain processing.
        userWithdraws[user][userNumWithdraws[user]] = withdrawId;
        userNumWithdraws[user]++;
    }

    function _now() internal view returns (uint256) {
        return block.timestamp;
    }

    /**
     * @dev Given the size of uint256 and the maximum supply of $S, we can safely assume that this will never overflow with even a 1 wei minimum withdraw amount.
     */
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

    function _enforceInvariant(uint256 rateBefore) internal view {
        uint256 rateAfter = getRate();

        // in instances where rounding occours, we allow for the rate to be 1 wei higher than it was before.
        // All operations should round in the favor of the protocol, resulting in a higher rate.
        require(rateBefore == rateAfter || rateBefore == rateAfter + 1, InvariantViolated());
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice To receive native asset rewards from SFC
     */
    receive() external payable {}
}
