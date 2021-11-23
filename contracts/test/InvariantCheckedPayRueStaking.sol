// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "../PayRueStaking.sol";

// Inspired by: https://muellerberndt.medium.com/catching-weird-security-bugs-in-solidity-smart-contracts-with-invariant-checks-435582dfb5bd
contract InvariantCheckedPayRueStaking is PayRueStaking {
    address[] public stakers;
    mapping(address => bool) public isStaker;
    uint256 public deployedOn;
    bool public enableLogging;

    // Invariant checking API
    // ======================

    modifier addStaker(
        address user
    )
    {
        if (!isStaker[user]) {
            stakers.push(user);
            isStaker[user] = true;
        }
        _;
    }

    modifier checkInvariants()
    {
        uint256 stakingTokenBalanceBefore = stakingToken.balanceOf(address(this));
        uint256 rewardTokenBalanceBefore = rewardToken.balanceOf(address(this));
        uint256 totalAmountStakedBefore = totalAmountStaked;
        uint256 totalLockedRewardBefore = totalLockedReward();
        uint256 totalGuaranteedRewardBefore = totalGuaranteedReward;
        uint256 totalStoredRewardBefore = totalStoredReward;

        logState("BEFORE");

        enforceGenericInvariants();

        _;

        logState("AFTER ");

        enforceGenericInvariants();

        if (stakingTokenIsRewardToken()) {
            if (totalAmountStaked > totalAmountStakedBefore) {
                // new stake, new staked amount + new locked amount = staking token balance change * 2
                requireChangedBySameAmount(
                    stakingTokenBalanceBefore * 2,
                    stakingToken.balanceOf(address(this)) * 2,
                    totalAmountStakedBefore + totalLockedRewardBefore,
                    totalAmountStaked + totalLockedReward()
                );
            }
            // else unstake or some operation that makes everything stay the same, e.g. claiming
            // this is cumbersome to check for invariants, so we just don't
        } else {
            // if staking token != reward token, staking token balance change
            // will match new stakes
            requireChangedBySameAmount(
                stakingTokenBalanceBefore,
                stakingToken.balanceOf(address(this)),
                totalAmountStakedBefore,
                totalAmountStaked
            );
        }

        // TODO: not sure about this
        if (totalStoredReward < totalStoredRewardBefore) {
            // if stored reward decreased, it means rewards claimed by the same amount
            requireChangedBySameAmount(
                rewardTokenBalanceBefore,
                rewardToken.balanceOf(address(this)),
                totalStoredRewardBefore,
                totalStoredReward
            );
        }

        if (totalGuaranteedReward > totalGuaranteedRewardBefore) {
            // if guaranteed reward increased, it means new stakes by the same amount
            requireChangedBySameAmount(
                totalGuaranteedRewardBefore + totalStoredRewardBefore,
                totalGuaranteedReward + totalStoredReward,
                totalAmountStakedBefore,
                totalAmountStaked
            );
        }

        //if (totalGuaranteedReward < totalGuaranteedRewardBefore) {
        //    // if guaranteed reward decreased, stored reward must increase at least as much
        //    // TODO: seems not to be the case
        //    requireChangedBySameAmount(
        //        totalGuaranteedRewardBefore,
        //        totalGuaranteedReward,
        //        // these are flipped because it's an increase for a decrease
        //        totalStoredReward,
        //        totalStoredRewardBefore
        //    );
        //}

        //if (totalLockedReward() > totalLockedRewardBefore) {
        //    // reward locked increased => there must have been new stakes
        //    // TODO: NOPE! it might also mean that the staking period has been passed without claims
        //    requireChangedBySameAmount(
        //        totalAmountStakedBefore,
        //        totalAmountStaked,
        //        totalLockedRewardBefore,
        //        totalLockedReward()
        //    );
        //}

        if (totalLockedReward() < totalLockedRewardBefore) {
            // if total locked reward decreased, it means a reward was claimed
            requireChangedBySameAmount(
                rewardTokenBalanceBefore,
                rewardToken.balanceOf(address(this)),
                totalLockedRewardBefore,
                totalLockedReward()
            );
        }
    }

    // Enforce invariants that don't require comparing before/after states
    function enforceGenericInvariants()
    internal
    view
    {
        // Someone can send stakingToken to the contract without staking, so the balance is not always just equal
        if (stakingTokenIsRewardToken()) {
            require(totalAmountStaked + totalLockedReward() <= stakingToken.balanceOf(address(this)));
        } else {
            require(totalAmountStaked <= stakingToken.balanceOf(address(this)));
            require(totalLockedReward() <= rewardToken.balanceOf(address(this)));
        }

        uint256 maxLockedReward = totalAmountStaked;
        if (block.timestamp - deployedOn > yieldPeriod) {
            maxLockedReward = totalAmountStaked * (block.timestamp - deployedOn) / yieldPeriod;
        }
        require(totalLockedReward() <= maxLockedReward);

        uint256 totalAmountStakedCalculatedFromUsers = 0;
        uint256 totalAmountStakedCalculatedFromStakes = 0;
        uint256 totalGuaranteedRewardCalculatedFromUsers = 0;
        uint256 totalStoredRewardCalculatedFromUsers = 0;
        for (uint256 i = 0; i < stakers.length; i++) {
            UserStakingData storage userData = stakingDataByUser[stakers[i]];
            require(userData.storedRewardUpdatedOn <= block.timestamp);
            require(userData.guaranteedReward == 0 || userData.guaranteedReward > dustAmount);
            require(userData.amountStaked == 0 || userData.amountStaked > dustAmount);
            totalAmountStakedCalculatedFromUsers += userData.amountStaked;
            totalGuaranteedRewardCalculatedFromUsers += userData.guaranteedReward;
            totalStoredRewardCalculatedFromUsers += userData.storedReward;

            for (uint256 j = 0; j < userData.stakes.length; j++) {
                Stake storage userStake = userData.stakes[j];
                totalAmountStakedCalculatedFromStakes += userStake.amount;
                if (userStake.amount < minStakeAmount) {
                    // fully or partially unstaked, enforce timestamp is ok
                    require(userStake.timestamp <= block.timestamp + lockedPeriod);
                    // previous must also be (fully) unstaked
                    if (j > 0) {
                        require(userData.stakes[j - 1].amount == 0);
                    }
                }
                if (userStake.amount == 0) {
                    require(userData.firstActiveStakeIndex >= j);
                }
            }
        }

        require(totalAmountStakedCalculatedFromUsers == totalAmountStaked);
        require(totalAmountStakedCalculatedFromStakes == totalAmountStaked);
        require(totalGuaranteedRewardCalculatedFromUsers == totalGuaranteedReward);
        require(totalStoredRewardCalculatedFromUsers == totalStoredReward);
        require(totalStoredReward + totalGuaranteedReward == totalLockedReward());
    }

    function requireChangedBySameAmount(
        uint256 aBefore,
        uint256 aAfter,
        uint256 bBefore,
        uint256 bAfter
    )
    internal
    pure
    {
        if (aBefore >= aAfter) {
            require(bBefore >= bAfter);
            require(aBefore - aAfter == bBefore - bAfter);
        } else {
            require(bBefore < bAfter);
            require(aAfter - aBefore == bAfter - bBefore);
        }
    }

    // Test utilities
    // ==============

    function setLogging(
        bool enabled
    )
    public
    {
        enableLogging = enabled;
    }

    function logState(
        string memory prefix
    )
    public
    view
    {
        if (!enableLogging) {
            return;
        }
        console.log(prefix);
        uint256 stakingTokenBalance = stakingToken.balanceOf(address(this));
        uint256 rewardTokenBalance = rewardToken.balanceOf(address(this));
        console.log("%s stakingToken balance:  %s", prefix, stakingTokenBalance);
        console.log("%s rewardToken balance:   %s", prefix, rewardTokenBalance);
        console.log("%s s+r token balance:     %s", prefix, stakingTokenBalance + rewardTokenBalance);
        console.log("%s totalAmountStaked:     %s", prefix, totalAmountStaked);
        console.log("%s totalGuaranteedReward: %s", prefix, totalGuaranteedReward);
        console.log("%s totalStoredReward:     %s", prefix, totalStoredReward);
        console.log("%s totalLockedReward:     %s", prefix, totalLockedReward());
        console.log("%s total staked+locked:   %s", prefix, totalAmountStaked + totalLockedReward());
    }
    function stakingTokenIsRewardToken()
    internal
    pure
    returns (bool)
    {
        // TODO: implement this later after we support different staking and reward tokens
        return true;
    }


    // Boilerplate to enable invariant checking for all functions
    // ==========================================================

    constructor(
        address _stakingToken,
        address _rewardToken
    )
    PayRueStaking(_stakingToken, _rewardToken)
    {
        deployedOn = block.timestamp;
    }


    function stake(
        uint256 amount
    )
    public
    override
    addStaker(msg.sender)
    checkInvariants()
    {
        super.stake(amount);
    }

    function claimReward()
    public
    override
    addStaker(msg.sender)
    checkInvariants()
    {
        super.claimReward();
    }

    function unstake(
        uint256 amount
    )
    public
    override
    addStaker(msg.sender)
    checkInvariants()
    {
        super.unstake(amount);
    }

    function exit()
    public
    override
    addStaker(msg.sender)
    checkInvariants()
    {
        super.exit();
    }

    function payRewardToUser(
        address user
    )
    public
    override
    addStaker(user)
    checkInvariants()
    {
        super.payRewardToUser(user);
    }
}
