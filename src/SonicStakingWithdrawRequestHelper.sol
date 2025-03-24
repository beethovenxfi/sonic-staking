// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {SonicStaking} from "./SonicStaking.sol";

contract SonicStakingWithdrawRequestHelper {
    struct WithdrawRequest {
        uint256 id;
        SonicStaking.WithdrawKind kind;
        uint256 validatorId;
        uint256 assetAmount;
        bool isWithdrawn;
        uint256 requestTimestamp;
        address user;
    }

    SonicStaking public immutable sonicStaking;

    constructor(address payable _sonicStaking) {
        sonicStaking = SonicStaking(_sonicStaking);
    }

    function getUserWithdrawsCount(address user) public view returns (uint256) {
        return sonicStaking.userNumWithdraws(user);
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
        returns (WithdrawRequest[] memory withdraws)
    {
        uint256 userWithdrawsCount = getUserWithdrawsCount(user);

        require(skip < userWithdrawsCount, SonicStaking.UserWithdrawsSkipTooLarge());
        require(maxSize > 0, SonicStaking.UserWithdrawsMaxSizeCannotBeZero());

        uint256 remaining = userWithdrawsCount - skip;
        uint256 size = remaining < maxSize ? remaining : maxSize;
        WithdrawRequest[] memory items = new WithdrawRequest[](size);

        for (uint256 i = 0; i < size; i++) {
            if (!reverseOrder) {
                // In chronological order we simply skip the first (older) entries
                items[i] = getWithdrawRequest(sonicStaking.userWithdraws(user, skip + i));
            } else {
                // In reverse order we go back to front, skipping the last (newer) entries. Note that `remaining` will
                // equal the total count if `skip` is 0, meaning we'd start with the newest entry.
                items[i] = getWithdrawRequest(sonicStaking.userWithdraws(user, remaining - 1 - i));
            }
        }

        return items;
    }

    function getWithdrawRequest(uint256 withdrawId) public view returns (WithdrawRequest memory) {
        SonicStaking.WithdrawRequest memory withdrawRequest = sonicStaking.getWithdrawRequest(withdrawId);

        return WithdrawRequest({
            id: withdrawId,
            kind: withdrawRequest.kind,
            validatorId: withdrawRequest.validatorId,
            assetAmount: withdrawRequest.assetAmount,
            isWithdrawn: withdrawRequest.isWithdrawn,
            requestTimestamp: withdrawRequest.requestTimestamp,
            user: withdrawRequest.user
        });
    }
}
