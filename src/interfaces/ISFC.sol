// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

interface ISFC {
    function currentEpoch() external view returns (uint256);

    function currentSealedEpoch() external view returns (uint256);

    function getValidator(uint256 toValidatorID)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            address
        );

    function getEpochSnapshot(uint256 epoch)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        );

    function getLockupInfo(address delegator, uint256 toValidatorID)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        );

    function getWithdrawalRequest(
        address delegator,
        uint256 toValidatorID,
        uint256 wrID
    )
        external
        view
        returns (
            uint256,
            uint256,
            uint256
        );

    function getStake(address delegator, uint256 toValidatorID)
        external
        view
        returns (uint256);

    function getStashedLockupRewards(address delegator, uint256 toValidatorID)
        external
        view
        returns (
            uint256,
            uint256,
            uint256
        );

    function getLockedStake(address delegator, uint256 toValidatorID)
        external
        view
        returns (uint256);

    function pendingRewards(address delegator, uint256 toValidatorID)
        external
        view
        returns (uint256);

    function isSlashed(uint256 toValidatorID) external view returns (bool);

    function slashingRefundRatio(uint256 toValidatorID)
        external
        view
        returns (uint256);

    function getEpochAccumulatedRewardPerToken(
        uint256 epoch,
        uint256 validatorID
    ) external view returns (uint256);

    function stashedRewardsUntilEpoch(address delegator, uint256 toValidatorID)
        external
        view
        returns (uint256);

    function isLockedUp(address delegator, uint256 toValidatorID)
        external
        view
        returns (bool);

    function delegate(uint256 toValidatorID) external payable;

    function lockStake(
        uint256 toValidatorID,
        uint256 lockupDuration,
        uint256 amount
    ) external;

    function relockStake(
        uint256 toValidatorID,
        uint256 lockupDuration,
        uint256 amount
    ) external;

    function restakeRewards(uint256 toValidatorID) external;

    function claimRewards(uint256 toValidatorID) external;

    function undelegate(
        uint256 toValidatorID,
        uint256 wrID,
        uint256 amount
    ) external;

    function unlockStake(uint256 toValidatorID, uint256 amount)
        external
        returns (uint256);

    function withdraw(uint256 toValidatorID, uint256 wrID) external;
}
