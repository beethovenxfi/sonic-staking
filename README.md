# Sonic Staking

This repository includes all contracts used for the LST Staked S ($stkS) by Beets.

In general, $stkS will earn yield from delegating underlying $S to validators. Delegated $S earns rewards and a portion of transaction fees (in $S) for helping secure the network. The rewards can be claimed and will increase the amount of $S in the system hence increasing the price of $stkS against $S. There is a protocol fee applied on the claimed rewards.

The general flow of this LST is the following:

- User deposits $S into the contract and receives $stkS for it, according to the current rate.
- Deposited $S will be accumulated in the "pool" first
- An operator delegates the deposited $S to a validator where it will earn rewards
- An operator will claim rewards from specific validators to increase the $stkS/$S rate.
- A protocol fee is deducted from the rewards, the remainder is added to the pool.
- A user can undelegate $stkS and can withdraw the $S two weeks later.

## Dev notes

Requires node version >18

run tests with `forge clean && forge test -vvv`

deploy to fork
`forge script DeploySonicStaking --fork-url https://rpc.fantom.network --fork-block-number 97094615 --force 0xFC00FACE00000000000000000000000000000000 0xa1E849B1d6c2Fd31c63EEf7822e9E0632411ada7 0xa1E849B1d6c2Fd31c63EEf7822e9E0632411ada7 --sig 'run(address,address,address)'`

## Todo

1. Add timelock for owner

## Access concept

The Sonic Staking contract is `ownable` and also uses OpenZeppelin `AccessControl`. Under access-control, we define the following roles:

1. Default Admin Role
2. Operator
3. Claim

The owner of the contract will be a Timelock with 1 week lock and has the following permissions:

1. Upgrade the contract

The default Admin role will be grant to a Timelock with 1 day lock and has the following permissions:

1. Grant/Revoe roles
2. Set the withdrawal delay
3. Set treasury address
4. Set protocol fees
5. Pause/Unpause deposit
6. Pause/Unpause undelegate
7. Pause/Unpause withdraw

The Operator role will be granted to a multisig and has the following permissions:

1. delegate
2. operator undelegate to pool
3. operator withdraw to pool
4. pause (which pauses deposits, undelegations and withdraws)

The Claim role will be given to an EOA (for automation purposes) and has the following permissions:

1. Claim rewards

## SFC

Staking on Sonic is done via the Special Fees Contract (SFC) as per this [repo](https://github.com/Fantom-foundation/opera-sfc). The contracts in this repository are implemented against [this commit](https://github.com/Fantom-foundation/opera-sfc/tree/8c700e0ef1224cdb29e8afed6ea89eacdfba9dd7).

A brief description of functions used by the LST contract are presented below.

### Epochs

The SFC defines so-called epochs. Epochs are sealed by the node driver. After an epoch is sealed, the total rewards earned in that epoch are calculated, and stored in a snapshot. This is used to calculate the rewards received by validators and delegators.

An epoch can seal when:

- Maximum epoch gas (1.5 billion) is exceeded
- Maximum epoch duration (4 hours) is exceeded
- A validator cheating incident is confirmed
- AdvanceEpoch is signaled from the Driver contract

### Delegate

The staking system on Sonic, which is handled by the SFC, uses validators and delegators. Validators run validator nodes that secure the network. Validators are required to have at least 50k $S self-staked. Each validator can have up to 15 times their self-staked amount delegated to it. To delegate to a validator, one calls [delegate()](https://github.com/Fantom-foundation/opera-sfc/blob/8c700e0ef1224cdb29e8afed6ea89eacdfba9dd7/contracts/sfc/SFC.sol#L392) on the SFC and passes the amount of $S as a value.

![sfc delegate](images/sfc_delegate.png)

### Undelegate and withdraw

There is an unbonding period of two weeks. Retrieving delegated funds is a two step process with a two week waiting period in between. You first call [undelegate](https://github.com/Fantom-foundation/opera-sfc/blob/8c700e0ef1224cdb29e8afed6ea89eacdfba9dd7/contracts/sfc/SFC.sol#L466) and after two weeks you can withdraw your $S via [withdraw](https://github.com/Fantom-foundation/opera-sfc/blob/8c700e0ef1224cdb29e8afed6ea89eacdfba9dd7/contracts/sfc/SFC.sol#L398).

![sfc undelegate](images/sfc_undelegate.png)
![sfc withdraw](images/sfc_withdraw.png)

### Claim rewards and pending rewards

All rewards are hadled via stashes in SFC. This means that everytime an epoch seals, [rewards are stashed for that particular epoch](https://github.com/Fantom-foundation/opera-sfc/blob/8c700e0ef1224cdb29e8afed6ea89eacdfba9dd7/contracts/sfc/SFC.sol#L308). This is then used to calculate the amount of rewards a delegator receives for a given epoch.

Delegated $S is entitled to staking rewards which can be claimed via [claimRewards()](https://github.com/Fantom-foundation/opera-sfc/blob/8c700e0ef1224cdb29e8afed6ea89eacdfba9dd7/contracts/sfc/SFC.sol#L448)

Pending rewards can be queried via [pendingRewards()](https://github.com/Fantom-foundation/opera-sfc/blob/8c700e0ef1224cdb29e8afed6ea89eacdfba9dd7/contracts/sfc/SFC.sol#L448)

![sfc claim rewards](images/sfc_claimrewards.png)

## Sonic Staking

This contract handles all operations for the LST $stkS. In general, a user deposits $S into the contract and receives $stkS in returned, based on the current rate.
The contract is kept upgradable because the SFC we are integrating against is also upgradable.

### Deposit (user function)

A user deposits $S into the Sonic Staking contract and receives $stkS based on the current rate. The $S that has been sent to the contract is first added to the pool and is not immediately delegated.
![stks deposit](images/sonicstaking_deposit.png)

### undelegate (user function)

If a user wants to redeem $stkS for $S, this is done with a two-step withdrawal process via the Sonic Staking contract. A user calls `undelegate()` on the Sonic Staking contract. First, the Sonic Staking contract will withdraw as much as possible from the pool. Any left over amount that needs to be withdrawn is undelegated from the provided validators. The $stkS will be burned in the process.
![stks undelegate](images/sonicstaking_undelegate.png)

### withdraw (user function)

After the two week unbonding period, the user can withdraw their $S by calling `withdraw()`. This will mark the withdrawals as withdrawn and send the $S to the user.
If a validator acts maliciously it can be slashed by the SFC, effectively reducing its stake. This means that any delegated $S will also be reduced, effectively reducing the amount of $S a user receives when withdrawing. To allow for "force" withdrawals, the flag `emergency` is set to true.
![stks withdraw](images/sonicstaking_withdraw.png)

### delegate (operator function)

$S that has been deposited into the pool will be delegated to the defined validators when the operator calls `delegate()`. This amount of $S is then reduced from the pool, added to the total delegate amount and delegated to the specified validator and will start to earn rewards.
![stks delegate](images/sonicstaking_delegate.png)

### claimRewards (operator function)

To claim rewards and increase the rate of $stkS against $S, the operator calls `claimRewards()`. This will claim rewards from the specified validators, deduct the protocol fee and add the remaining funds to the pool, increasing the amount of $S in the system while the $stkS supply stays the same.
![stks claim rewards](images/sonicstaking_claimRewards.png)

### undelegateToPool (operator function)

If a validator has an issue, i.e. is not online anymore, it doesn't produce rewards for the delegated stake. In that case, it is important that the delegated amount can be withdrawn to the pool and delegated to another validator. This function initiates an undelegation without burning $stkS, as the withdrawn $S will in the end go back to the pool, this should not affect the rate.
![stks undelegate to pool](images/sonicstaking_undelegateToPool.png)

### withdrawToPool (operator function)

Once the unbonding time is over, the undelegated $S can be withdrawn into the pool.
![stks withdraw to pool](images/sonicstaking_withdrawToPool.png)
