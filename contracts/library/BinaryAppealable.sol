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

    enum Party {None, Requester, Respondent}

    struct Round {
        uint256[3] paidFees; // Tracks the fees paid by each side in this round.
        Party sideFunded; // If the round is appealed, i.e. this is not the last round, Party.None means that both sides have paid.
        uint256 feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => uint256[3]) contributions; // Maps contributors to their contributions for each side.
    }

    function fundAppeal(
        Round[] storage self, 
        Party _side, 
        uint256 disputeID,
        IArbitrator arbitrator, 
        bytes storage arbitratorExtraData, 
        uint256 loserStakeMultiplier,
        uint256 winnerStakeMultiplier,
        uint256 sharedStakeMultiplier,
        uint256 multiplierDivisor
        ) internal returns(uint256 contribution, bool sideFullyFunded, bool appealCreated) {

        require(_side != Party.None, "Invalid party.");

        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = arbitrator.appealPeriod(disputeID);
        require(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd, "Funding must be made within the appeal period.");

        uint256 multiplier;
        {
            // This scope prevents stack to deep errors.
            uint256 winner = arbitrator.currentRuling(disputeID);
            if (winner == uint256(_side)){
                multiplier = winnerStakeMultiplier;
            } else if (winner == 0){
                multiplier = sharedStakeMultiplier;
            } else {
                require(block.timestamp < (appealPeriodEnd + appealPeriodStart)/2, "The loser must pay during the first half of the appeal period.");
                multiplier = loserStakeMultiplier;
            }
        }

        Round storage round = self[self.length - 1];
        require(_side != round.sideFunded, "Appeal fee has already been paid.");

        uint256 appealCost = arbitrator.appealCost(disputeID, arbitratorExtraData);
        uint256 totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / multiplierDivisor);

        // Take up to the amount necessary to fund the current round at the current costs.
        uint256 remainingETH;
        (contribution, remainingETH) = calculateContribution(msg.value, totalCost.subCap(round.paidFees[uint256(_side)]));
        round.contributions[msg.sender][uint256(_side)] += contribution;
        round.paidFees[uint256(_side)] += contribution;

        // Reimburse leftover ETH if any.
        if (remainingETH > 0)
            msg.sender.send(remainingETH); // Deliberate use of send in order to not block the contract in case of reverting fallback.
        
        if (round.paidFees[uint256(_side)] >= totalCost) {
            sideFullyFunded = true;
            if (round.sideFunded == Party.None) {
                round.sideFunded = _side;
            } else {
                // Create an appeal if each side is funded.
                appealCreated = true;
                arbitrator.appeal{value: appealCost}(disputeID, arbitratorExtraData);
                round.feeRewards = (round.paidFees[uint256(Party.Requester)] + round.paidFees[uint256(Party.Respondent)]).subCap(appealCost);
                round.sideFunded = Party.None;
                self.push();
            }
        }

    }

    function withdrawFeesAndRewards(Round[] storage self, address _beneficiary, uint256 _round, uint256 _finalRuling) internal returns(uint256 reward) {
        Round storage round = self[_round];
        uint256[3] storage contributionTo = round.contributions[_beneficiary];
        uint256 lastRound = self.length - 1;

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
    
    function withdrawRoundBatch(Round[] storage self, address _beneficiary, uint256 _cursor, uint256 _count, uint256 _finalRuling) internal returns(uint256 reward) {
        uint256 maxRound = _count == 0 ? self.length : _cursor + _count;
        if (maxRound > self.length)
            maxRound = self.length;
        for (uint256 i = _cursor; i < maxRound; i++)
            reward += withdrawFeesAndRewards(self, _beneficiary, i, _finalRuling);
    }

    function amountWithdrawable(Round[] storage self, address _beneficiary, uint256 finalRuling) internal view returns(uint256 total) {
        uint256 totalRounds = self.length;
        for (uint256 i = 0; i < totalRounds; i++) {
            BinaryAppealable.Round storage round = self[i];
            if (i == totalRounds - 1) {
                total += round.contributions[_beneficiary][uint256(Party.Requester)] + round.contributions[_beneficiary][uint256(Party.Respondent)];
            } else if (finalRuling == uint256(Party.None)) {
                uint256 totalFeesPaid = round.paidFees[uint256(Party.Requester)] + round.paidFees[uint256(Party.Respondent)];
                uint256 totalBeneficiaryContributions = round.contributions[_beneficiary][uint256(Party.Requester)] + round.contributions[_beneficiary][uint256(Party.Respondent)];
                total += totalFeesPaid > 0 ? (totalBeneficiaryContributions * round.feeRewards) / totalFeesPaid : 0;
            } else {
                total += round.paidFees[finalRuling] > 0
                    ? (round.contributions[_beneficiary][finalRuling] * round.feeRewards) / round.paidFees[finalRuling]
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
}