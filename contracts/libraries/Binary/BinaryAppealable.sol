/**
 *  @authors: [@fnanni-0]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 */

pragma solidity >=0.7;

import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

library BinaryAppealable {
    using CappedMath for uint256;

    uint256 public constant AMOUNT_OF_CHOICES = 2;
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    enum Party {None, Requester, Respondent}

    struct Round {
        uint256[3] paidFees; // Tracks the fees paid by each side in this round.
        Party sideFunded; // If the round is appealed, i.e. this is not the last round, Party.None means that both sides have paid.
        uint256 feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => uint256[3]) contributions; // Maps contributors to their contributions for each side.
    }

    struct AppealableStorage {
        uint256 sharedStakeMultiplier; // Multiplier for calculating the appeal fee that must be paid by the submitter in the case where there is no winner or loser (e.g. when the arbitrator ruled "refuse to arbitrate").
        uint256 winnerStakeMultiplier; // Multiplier for calculating the appeal fee of the party that won the previous round.
        uint256 loserStakeMultiplier; // Multiplier for calculating the appeal fee of the party that lost the previous round.
        mapping(uint256 => Round[]) roundsByItem; // roundsByItem[itemID]
    }

    /** @dev To be emitted when the appeal fees of one of the parties are fully funded.
     *  @param _itemID The ID of the respective transaction.
     *  @param _party The party that is fully funded.
     *  @param _round The appeal round fully funded by _party. Starts from 0.
     */
    event HasPaidAppealFee(uint256 indexed _itemID, Party _party, uint256 _round);

    /**
     *  @dev To be emitted when someone contributes to the appeal process.
     *  @param _itemID The ID of the respective transaction.
     *  @param _party The party which received the contribution.
     *  @param _contributor The address of the contributor.
     *  @param _round The appeal round to which the contribution is going. Starts from 0.
     *  @param _amount The amount contributed.
     */
    event AppealContribution(uint256 indexed _itemID, Party _party, address indexed _contributor, uint256 _round, uint256 _amount);

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

    function fundAppeal(
        AppealableStorage storage self, 
        uint256 itemID, 
        Party side, 
        uint256 disputeID,
        IArbitrator arbitrator, 
        bytes storage arbitratorExtraData
        ) internal {

        require(side != Party.None, "Invalid party.");

        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = arbitrator.appealPeriod(disputeID);
        require(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd, "Not in appeal period.");

        uint256 multiplier;
        {
            // This scope prevents stack to deep errors.
            uint256 winner = arbitrator.currentRuling(disputeID);
            if (winner == uint256(side)){
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
        require(side != round.sideFunded, "Appeal fee has already been paid.");

        uint256 appealCost = arbitrator.appealCost(disputeID, arbitratorExtraData);
        uint256 totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);

        // Take up to the amount necessary to fund the current round at the current costs.
        uint256 contribution;
        uint256 remainingETH;
        (contribution, remainingETH) = calculateContribution(msg.value, totalCost.subCap(round.paidFees[uint256(side)]));
        round.contributions[msg.sender][uint256(side)] += contribution;
        round.paidFees[uint256(side)] += contribution;
        emit AppealContribution(itemID, side, msg.sender, rounds.length - 1, contribution);

        // Reimburse leftover ETH if any.
        if (remainingETH > 0)
            msg.sender.send(remainingETH); // Deliberate use of send in order to not block the contract in case of reverting fallback.

        if (round.paidFees[uint256(side)] >= totalCost) {
            emit HasPaidAppealFee(itemID, side, rounds.length - 1);
            if (round.sideFunded == Party.None) {
                round.sideFunded = side;
            } else {
                // Both sides are fully funded. Create an appeal.
                arbitrator.appeal{value: appealCost}(disputeID, arbitratorExtraData);
                round.feeRewards = (round.paidFees[uint256(Party.Requester)] + round.paidFees[uint256(Party.Respondent)]).subCap(appealCost);
                round.sideFunded = Party.None;
                rounds.push();
            }
        }

    }

    function _withdrawFeesAndRewards(
        AppealableStorage storage self, 
        uint256 itemID, 
        address _beneficiary, 
        uint256 _round, 
        uint256 _finalRuling
        ) internal returns(uint256 reward) {

        Round[] storage rounds = self.roundsByItem[itemID];
        Round storage round = rounds[_round];
        uint256[3] storage contributionTo = round.contributions[_beneficiary];
        uint256 lastRound = rounds.length - 1;

        if (_round == lastRound) {
            // Allow to reimburse if funding was unsuccessful.
            reward = contributionTo[uint256(Party.Requester)] + contributionTo[uint256(Party.Respondent)];
        } else if (_finalRuling == uint256(Party.None)) {
            // Reimburse unspent fees proportionally if there is no winner and loser.
            uint256 totalFeesPaid = round.paidFees[uint256(Party.Requester)] + round.paidFees[uint256(Party.Respondent)];
            uint256 totalBeneficiaryContributions = contributionTo[uint256(Party.Requester)] + contributionTo[uint256(Party.Respondent)];
            reward = totalFeesPaid > 0 ? (totalBeneficiaryContributions * round.feeRewards) / totalFeesPaid : 0;
        } else {
            // Reward the winner.
            reward = round.paidFees[_finalRuling] > 0
                ? (contributionTo[_finalRuling] * round.feeRewards) / round.paidFees[_finalRuling]
                : 0;
        }
        contributionTo[uint256(Party.Requester)] = 0;
        contributionTo[uint256(Party.Respondent)] = 0;
    }

    function withdrawFeesAndRewards(
        AppealableStorage storage self, 
        uint256 itemID, 
        address payable _beneficiary, 
        uint256 _round, 
        uint256 _finalRuling
        ) internal {
            uint256 reward = _withdrawFeesAndRewards(self, itemID, _beneficiary, _round, _finalRuling);
            _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }
    
    function withdrawRoundBatch(
        AppealableStorage storage self, 
        uint256 itemID, 
        address payable _beneficiary, 
        uint256 _cursor, 
        uint256 _count, 
        uint256 _finalRuling
        ) internal {

        Round[] storage rounds = self.roundsByItem[itemID];
        uint256 maxRound = _count == 0 ? rounds.length : _cursor + _count;
        uint256 reward;
        if (maxRound > rounds.length)
            maxRound = rounds.length;
        for (uint256 i = _cursor; i < maxRound; i++)
            reward += _withdrawFeesAndRewards(self, itemID, _beneficiary, i, _finalRuling);

        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }

    function amountWithdrawable(
        AppealableStorage storage self, 
        uint256 itemID, 
        address _beneficiary, 
        uint256 _finalRuling
        ) internal view returns(uint256 total) {
        
        Round[] storage rounds = self.roundsByItem[itemID];
        uint256 totalRounds = rounds.length;
        for (uint256 i = 0; i < totalRounds; i++) {
            Round storage round = rounds[i];
            if (i == totalRounds - 1) {
                total += round.contributions[_beneficiary][uint256(Party.Requester)] + round.contributions[_beneficiary][uint256(Party.Respondent)];
            } else if (_finalRuling == uint256(Party.None)) {
                uint256 totalFeesPaid = round.paidFees[uint256(Party.Requester)] + round.paidFees[uint256(Party.Respondent)];
                uint256 totalBeneficiaryContributions = round.contributions[_beneficiary][uint256(Party.Requester)] + round.contributions[_beneficiary][uint256(Party.Respondent)];
                total += totalFeesPaid > 0 ? (totalBeneficiaryContributions * round.feeRewards) / totalFeesPaid : 0;
            } else {
                total += round.paidFees[_finalRuling] > 0
                    ? (round.contributions[_beneficiary][_finalRuling] * round.feeRewards) / round.paidFees[_finalRuling]
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

    function getNumberOfRounds(AppealableStorage storage self, uint256 itemID) public view returns (uint256) {
        return self.roundsByItem[itemID].length;
    }

    function getRoundInfo(
        AppealableStorage storage self, 
        uint256 itemID, 
        uint256 _round
        ) internal view returns(
            uint256[3] memory paidFees,
            Party sideFunded,
            uint256 feeRewards,
            bool appealed
        ) {
        
        Round[] storage rounds = self.roundsByItem[itemID];
        Round storage round = rounds[_round];

        return (
            round.paidFees,
            round.sideFunded,
            round.feeRewards,
            _round != rounds.length - 1
        );
    }

    function getContributions(
        AppealableStorage storage self, 
        uint256 itemID, 
        uint256 _round,
        address _contributor
        ) internal view returns(uint256[3] memory contributions) {
        
        Round[] storage rounds = self.roundsByItem[itemID];
        Round storage round = rounds[_round];
        contributions = round.contributions[_contributor];
    }

}