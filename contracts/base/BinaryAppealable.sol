/**
 *  @authors: [@fnanni-0]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 */

pragma solidity >=0.7;

import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

contract BinaryAppealable {
    
    using CappedMath for uint256;

    // **************************** //
    // *    Contract variables    * //
    // **************************** //

    uint256 public constant AMOUNT_OF_CHOICES = 2;
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    enum BaseParty {None, Requester, Respondent}

    struct Round {
        uint256[3] paidFees; // Tracks the fees paid by each side in this round.
        BaseParty sideFunded; // If the round is appealed, i.e. this is not the last round, Party.None means that both sides have paid.
        uint256 feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => uint256[3]) contributions; // Maps contributors to their contributions for each side.
    }

    /** @dev Constructor.
     */
    constructor () {}

    function _fundAppeal(
        Round[] storage rounds, 
        BaseParty _side, 
        uint256 disputeID,
        IArbitrator arbitrator,
        bytes storage arbitratorExtraData,
        uint256 loserStakeMultiplier,
        uint256 winnerStakeMultiplier,
        uint256 sharedStakeMultiplier
        ) internal returns(uint256 contribution, bool sideFullyFunded, bool appealCreated) {

        require(_side != BaseParty.None, "Invalid party.");

        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = arbitrator.appealPeriod(disputeID);
        require(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd, "Not in appeal period.");

        uint256 multiplier;
        {
            // This scope prevents stack to deep errors.
            uint256 winner = arbitrator.currentRuling(disputeID);
            if (winner == uint256(_side)){
                multiplier = winnerStakeMultiplier;
            } else if (winner == 0){
                multiplier = sharedStakeMultiplier;
            } else {
                require(block.timestamp < (appealPeriodEnd + appealPeriodStart)/2, "Not in loser's appeal period.");
                multiplier = loserStakeMultiplier;
            }
        }

        Round storage round = rounds[rounds.length - 1];
        require(_side != round.sideFunded, "Party has been fully funded.");

        uint256 appealCost = arbitrator.appealCost(disputeID, arbitratorExtraData);
        uint256 totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);

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
            if (round.sideFunded == BaseParty.None) {
                round.sideFunded = _side;
            } else {
                // Create an appeal if each side is funded.
                appealCreated = true;
                arbitrator.appeal{value: appealCost}(disputeID, arbitratorExtraData);
                round.feeRewards = (round.paidFees[uint256(BaseParty.Requester)] + round.paidFees[uint256(BaseParty.Respondent)]).subCap(appealCost);
                round.sideFunded = BaseParty.None;
                rounds.push();
            }
        }
    }
    
    function _withdrawFeesAndRewards(Round[] storage rounds, address _beneficiary, uint256 _round, uint256 _finalRuling) internal returns(uint256 reward) {
        Round storage round = rounds[_round];
        uint256[3] storage contributionTo = round.contributions[_beneficiary];
        uint256 lastRound = rounds.length - 1;

        if (_round == lastRound) {
            // Allow to reimburse if funding was unsuccessful.
            reward = contributionTo[uint256(BaseParty.Requester)] + contributionTo[uint256(BaseParty.Respondent)];
        } else if (_finalRuling == uint256(BaseParty.None)) {
            // Reimburse unspent fees proportionally if there is no winner and loser.
            uint256 totalFeesPaid = round.paidFees[uint256(BaseParty.Requester)] + round.paidFees[uint256(BaseParty.Respondent)];
            uint256 totalBeneficiaryContributions = contributionTo[uint256(BaseParty.Requester)] + contributionTo[uint256(BaseParty.Respondent)];
            reward = totalFeesPaid > 0 ? (totalBeneficiaryContributions * round.feeRewards) / totalFeesPaid : 0;
        } else {
            // Reward the winner.
            reward = round.paidFees[_finalRuling] > 0
                ? (contributionTo[_finalRuling] * round.feeRewards) / round.paidFees[_finalRuling]
                : 0;
        }
        contributionTo[uint256(BaseParty.Requester)] = 0;
        contributionTo[uint256(BaseParty.Respondent)] = 0;
    }
    
    function _withdrawRoundBatch(Round[] storage rounds, address _beneficiary, uint256 _cursor, uint256 _count, uint256 _finalRuling) internal returns(uint256 reward) {
        reward;
        uint256 maxRound = _count == 0 ? rounds.length : _cursor + _count;
        if (maxRound > rounds.length)
            maxRound = rounds.length;
        for (uint256 i = _cursor; i < maxRound; i++)
            reward += _withdrawFeesAndRewards(rounds, _beneficiary, i, _finalRuling);
    }

    function _amountWithdrawable(Round[] storage rounds, address _beneficiary, uint256 finalRuling) internal view returns(uint256 total) {
        uint256 totalRounds = rounds.length;
        for (uint256 i = 0; i < totalRounds; i++) {
            BinaryAppealable.Round storage round = rounds[i];
            if (i == totalRounds - 1) {
                total += round.contributions[_beneficiary][uint256(BaseParty.Requester)] + round.contributions[_beneficiary][uint256(BaseParty.Respondent)];
            } else if (finalRuling == uint256(BaseParty.None)) {
                uint256 totalFeesPaid = round.paidFees[uint256(BaseParty.Requester)] + round.paidFees[uint256(BaseParty.Respondent)];
                uint256 totalBeneficiaryContributions = round.contributions[_beneficiary][uint256(BaseParty.Requester)] + round.contributions[_beneficiary][uint256(BaseParty.Respondent)];
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

    function getRoundInfo(bytes32 roundsSlot, uint256 _round) external view returns (
            uint256[3] memory paidFees,
            BaseParty sideFunded,
            uint256 feeRewards,
            bool appealed
        )
    {
        Round[] storage rounds;
        assembly {
            rounds.slot := roundsSlot
        }
        Round storage round = rounds[_round];
        return (
            round.paidFees,
            round.sideFunded,
            round.feeRewards,
            _round != rounds.length - 1
        );
    }

    function getContributions(bytes32 roundsSlot, uint256 _round, address _contributor) external view returns(
        uint256[3] memory contributions
        ) 
    {
        Round[] storage rounds;
        assembly {
            rounds.slot := roundsSlot
        }
        Round storage round = rounds[_round];
        contributions = round.contributions[_contributor];
    }

    function getNumberOfRounds(bytes32 roundsSlot) external view returns(uint256) {
        Round[] storage rounds;
        assembly {
            rounds.slot := roundsSlot
        }
        return rounds.length;
    }
}