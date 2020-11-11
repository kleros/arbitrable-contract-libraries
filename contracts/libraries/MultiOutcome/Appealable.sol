/**
 *  @authors: [@fnanni-0]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 */

pragma solidity >=0.7;

import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

library Appealable {
    using CappedMath for uint256;

    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    struct Round {
        uint256[] paidFees; // Tracks the fees paid by each side in this round.
        uint256[2] rulingsFunded; // Stores the ruling options that are fully funded.
        uint256 feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => mapping(uint256 => uint256)) contributions; // Maps contributors to their contributions for each side.
    }

    struct AppealableStorage {
        uint256 possibleRulings;
        uint256 sharedStakeMultiplier; // Multiplier for calculating the appeal fee that must be paid by the submitter in the case where there is no winner or loser (e.g. when the arbitrator ruled "refuse to arbitrate").
        uint256 winnerStakeMultiplier; // Multiplier for calculating the appeal fee of the party that won the previous round.
        uint256 loserStakeMultiplier; // Multiplier for calculating the appeal fee of the party that lost the previous round.
        mapping(uint256 => Round[]) roundsByItem; // roundsByItem[itemID]
    }

    /** @dev To be emitted when the appeal fees of one of the parties are fully funded.
     *  @param _itemID The ID of the respective transaction.
     *  @param _ruling The ruling that is fully funded.
     */
    event HasPaidAppealFee(uint256 indexed _itemID, uint256 _ruling);

    /**
     * @dev To be emitted when someone contributes to the appeal process.
     * @param _itemID The ID of the respective transaction.
     * @param _ruling The ruling which received the contribution.
     * @param _contributor The address of the contributor.
     * @param _amount The amount contributed.
     */
    event AppealContribution(uint256 indexed _itemID, uint256 _ruling, address _contributor, uint256 _amount);

    function setMultipliers(
        AppealableStorage storage self, 
        uint256 _sharedStakeMultiplier, 
        uint256 _winnerStakeMultiplier, 
        uint256 _loserStakeMultiplier
        ) internal {
        self.sharedStakeMultiplier = _sharedStakeMultiplier;
        self.winnerStakeMultiplier = _winnerStakeMultiplier;
        self.loserStakeMultiplier = _loserStakeMultiplier;
    }

    function setRulings(
        AppealableStorage storage self, 
        uint256 _possibleRulings
        ) internal {
        self.possibleRulings = _possibleRulings;
    }

    function fundAppeal(
        AppealableStorage storage self, 
        uint256 itemID, 
        uint256 ruling, 
        uint256 disputeID,
        IArbitrator arbitrator, 
        bytes storage arbitratorExtraData
        ) internal {

        require(ruling != 0, "Invalid ruling.");

        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = arbitrator.appealPeriod(disputeID);
        require(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd, "Not in appeal period.");

        uint256 multiplier;
        {
            // This scope prevents stack to deep errors.
            uint256 winner = arbitrator.currentRuling(disputeID);
            if (winner == ruling){
                multiplier = self.winnerStakeMultiplier;
            } else if (winner == 0){
                multiplier = self.sharedStakeMultiplier;
            } else {
                require(block.timestamp < (appealPeriodEnd + appealPeriodStart)/2, "Not in loser's appeal period.");
                multiplier = self.loserStakeMultiplier;
            }
        }

        Round[] storage rounds = self.roundsByItem[itemID];
        Round storage round = rounds[rounds.length - 1];
        require(ruling != round.rulingsFunded[0], "Appeal fee has already been paid.");

        uint256 appealCost = arbitrator.appealCost(disputeID, arbitratorExtraData);
        uint256 totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);

        // Take up to the amount necessary to fund the current round at the current costs.
        uint256 contribution;
        uint256 remainingETH;
        (contribution, remainingETH) = calculateContribution(msg.value, totalCost.subCap(round.paidFees[ruling]));
        round.contributions[msg.sender][ruling] += contribution;
        round.paidFees[ruling] += contribution;
        emit AppealContribution(itemID, ruling, msg.sender, contribution);

        // Reimburse leftover ETH if any.
        if (remainingETH > 0)
            msg.sender.send(remainingETH); // Deliberate use of send in order to not block the contract in case of reverting fallback.

        if (round.paidFees[ruling] >= totalCost) {
            emit HasPaidAppealFee(itemID, ruling);
            if (round.rulingsFunded[0] == 0) {
                round.rulingsFunded[0] = ruling;
            } else {
                // Two rulings are fully funded. Create an appeal.
                arbitrator.appeal{value: appealCost}(disputeID, arbitratorExtraData);
                round.rulingsFunded[1] = ruling;
                round.feeRewards = (round.paidFees[round.rulingsFunded[0]] + round.paidFees[ruling]).subCap(appealCost);
                rounds.push();
            }
        }
    }

    function withdrawFeesAndRewards(
        AppealableStorage storage self, 
        uint256 itemID, 
        address _beneficiary, 
        uint256 _ruling, 
        uint256 _round, 
        uint256 _finalRuling
        ) internal returns(uint256 reward) {

        Round[] storage rounds = self.roundsByItem[itemID];
        Round storage round = rounds[_round];
        mapping(uint256 => uint256) storage contributionTo = round.contributions[_beneficiary];
        uint256 lastRound = rounds.length - 1;

        if (_round == lastRound || (round.rulingsFunded[0] != _ruling && round.rulingsFunded[1] != _ruling)) {
            // Allow to reimburse if funding was unsuccessful, i.e. appeal wasn't created or ruling wasn't fully funded.
            reward = contributionTo[_ruling];
            contributionTo[_ruling] = 0;
        } else if (round.rulingsFunded[0] != _finalRuling && round.rulingsFunded[1] != _finalRuling) {
            // Reimburse unspent fees proportionally, if none of the funding rulings won.
            uint256 totalFeesPaid = round.paidFees[round.rulingsFunded[0]] + round.paidFees[round.rulingsFunded[1]];
            uint256 totalBeneficiaryContributions = contributionTo[round.rulingsFunded[0]] + contributionTo[round.rulingsFunded[1]];
            reward = totalFeesPaid > 0 ? (totalBeneficiaryContributions * round.feeRewards) / totalFeesPaid : 0;

            contributionTo[round.rulingsFunded[0]] = 0;
            contributionTo[round.rulingsFunded[1]] = 0;
        } else if (_ruling == _finalRuling) {
            // Reward the winner.
            reward = round.paidFees[_finalRuling] > 0
                ? (contributionTo[_finalRuling] * round.feeRewards) / round.paidFees[_finalRuling]
                : 0;
            contributionTo[_finalRuling] = 0;
        }
    }
    
    function withdrawRoundBatch(
        AppealableStorage storage self, 
        uint256 itemID, 
        address _beneficiary, 
        uint256 _ruling, 
        uint256 _cursor, 
        uint256 _count, 
        uint256 _finalRuling
        ) internal returns(uint256 reward) {

        Round[] storage rounds = self.roundsByItem[itemID];
        uint256 maxRound = _count == 0 ? rounds.length : _cursor + _count;
        if (maxRound > rounds.length)
            maxRound = rounds.length;
        for (uint256 i = _cursor; i < maxRound; i++)
            reward += withdrawFeesAndRewards(self, itemID, _beneficiary, _ruling, i, _finalRuling);
    }

    function withdrawMultipleRulings(
        AppealableStorage storage self, 
        uint256 itemID, 
        address _beneficiary, 
        uint256 _round, 
        uint256[] memory _rulings,
        uint256 _finalRuling
        ) internal returns(uint256 reward) {
        for (uint256 i = 0; i < _rulings.length; i++) {
            reward += withdrawFeesAndRewards(self, itemID, _beneficiary, _rulings[i], _round, _finalRuling);
        }
    }

    function amountWithdrawable(
        AppealableStorage storage self, 
        uint256 itemID, 
        address _beneficiary, 
        uint256 _ruling, 
        uint256 _finalRuling
        ) internal view returns(uint256 total) {
        
        Round[] storage rounds = self.roundsByItem[itemID];
        uint256 totalRounds = rounds.length;
        for (uint256 i = 0; i < totalRounds; i++) {
            Round storage round = rounds[i];
            mapping(uint256 => uint256) storage contributionTo = round.contributions[_beneficiary];
            if (i == totalRounds-1 || (round.rulingsFunded[0] != _ruling && round.rulingsFunded[1] != _ruling)) {
                // Allow to reimburse if funding was unsuccessful, i.e. appeal wasn't created or ruling wasn't fully funded.
                total += contributionTo[_ruling];
            } else if (round.rulingsFunded[0] != _finalRuling && round.rulingsFunded[1] != _finalRuling) {
                // Reimburse unspent fees proportionally, if none of the funding rulings won.
                uint256 totalFeesPaid = round.paidFees[round.rulingsFunded[0]] + round.paidFees[round.rulingsFunded[1]];
                uint256 totalBeneficiaryContributions = contributionTo[round.rulingsFunded[0]] + contributionTo[round.rulingsFunded[1]];
                total += totalFeesPaid > 0 ? (totalBeneficiaryContributions * round.feeRewards) / totalFeesPaid : 0;
            } else if (_ruling == _finalRuling) {
                // Reward the winner.
                total += round.paidFees[_finalRuling] > 0
                    ? (contributionTo[_finalRuling] * round.feeRewards) / round.paidFees[_finalRuling]
                    : 0;
            }
        }
    }

    /** @dev Returns the contribution value and remainder from available ETH and required amount.
     *  @param _available The amount of ETH available for the contribution.
     *  @param _requiredAmount The amount of ETH required for the contribution.
     *  @return taken The amount of ETH taken.
     *  @return remainder The amount of ETH left from the contribution.
     */
    function calculateContribution(uint256 _available, uint256 _requiredAmount)
        internal
        pure
        returns(uint256 taken, uint256 remainder)
    {
        if (_requiredAmount > _available)
            return (_available, 0); // Take whatever is available, return 0 as leftover ETH.

        remainder = _available - _requiredAmount;
        return (_requiredAmount, remainder);
    }

    function getNumberOfRounds(AppealableStorage storage self, uint256 itemID) internal view returns (uint256) {
        return self.roundsByItem[itemID].length;
    }

    function getRoundInfo(
        AppealableStorage storage self, 
        uint256 itemID, 
        uint256 _round
        ) internal view returns(
            uint256[2] memory paidFees,
            uint256[2] memory rulingsFunded,
            uint256 feeRewards,
            bool appealed
        ) {
        
        Round[] storage rounds = self.roundsByItem[itemID];
        Round storage round = rounds[_round];

        paidFees[0] = round.paidFees[round.rulingsFunded[0]];
        paidFees[1] = round.paidFees[round.rulingsFunded[1]];

        return (
            round.paidFees,
            round.rulingsFunded,
            round.feeRewards,
            _round != rounds.length - 1
        );
    }

    function getFundingStatus(
        AppealableStorage storage self, 
        uint256 itemID, 
        uint256 _round,
        uint256 _ruling
        ) internal view returns(uint feesRaised, bool fullyFunded) {
        Round[] storage rounds = self.roundsByItem[itemID];
        Round storage round = rounds[_round];

        feesRaised = round.paidFees[_ruling];
        fullyFunded = round.rulingsFunded[0] == _ruling || round.rulingsFunded[1] == _ruling;
    }

    function getContributionsToSuccessfulFundings(
        AppealableStorage storage self, 
        uint256 itemID,
        uint256 _round,
        address _contributor
    ) internal view returns(uint[2] memory rulingsFunded, uint[2] memory contributions) {
        Round[] storage rounds = self.roundsByItem[itemID];
        Round storage round = rounds[_round];

        rulingsFunded = round.rulingsFunded;
        contributions[0] = round.contributions[_contributor][rulingsFunded[0]];
        contributions[1] = round.contributions[_contributor][rulingsFunded[1]];
    }
}