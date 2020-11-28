/**
 *  @authors: [@fnanni-0]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 */

pragma solidity >=0.7;

import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

library MultiOutcomeArbitrable {
    using CappedMath for uint256;

    uint256 public constant MAX_NO_OF_CHOICES = uint256(-1);
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    enum Status {Undisputed, Disputed, Resolved}

    struct Round {
        uint256[] paidFees; // Tracks the fees paid by each side in this round.
        uint256[2] rulingsFunded; // Stores the ruling options that are fully funded.
        uint256 feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => mapping(uint256 => uint256)) contributions; // Maps contributors to their contributions for each side.
    }

    struct ItemData {
        Round[] rounds;
        Status status;
        uint256 ruling;
        uint256 disputeID;
    }

    struct ArbitrableStorage {
        IArbitrator arbitrator; // Address of the arbitrator contract. TRUSTED.
        bytes arbitratorExtraData; // Extra data to set up the arbitration.     
        uint256 sharedStakeMultiplier; // Multiplier for calculating the appeal fee that must be paid by the submitter in the case where there is no winner or loser (e.g. when the arbitrator ruled "refuse to arbitrate").
        uint256 winnerStakeMultiplier; // Multiplier for calculating the appeal fee of the party that won the previous round.
        uint256 loserStakeMultiplier; // Multiplier for calculating the appeal fee of the party that lost the previous round.
        mapping(uint256 => ItemData) items; // items[itemID]
        mapping(uint256 => uint256) disputeIDtoItemID; // disputeIDtoItemID[disputeID]
    }

    /// @dev events apparently have to be defined both in the library and in the contract where the library is used.
    /// @dev See {@kleros/erc-792/contracts/IArbitrable.sol}
    event Ruling(IArbitrator indexed _arbitrator, uint256 indexed _disputeID, uint256 _ruling);

    /// @dev See {@kleros/erc-792/contracts/erc-1497/IEvidence.sol}
    event Evidence(IArbitrator indexed _arbitrator, uint256 indexed _evidenceGroupID, address indexed _party, string _evidence);

    /// @dev See {@kleros/erc-792/contracts/erc-1497/IEvidence.sol}
    event Dispute(IArbitrator indexed _arbitrator, uint256 indexed _disputeID, uint256 _metaEvidenceID, uint256 _evidenceGroupID);

    /** @dev To be emitted when the appeal fees of one of the parties are fully funded.
     *  @param _itemID The ID of the respective transaction.
     *  @param _ruling The ruling that is fully funded.
     *  @param _round The appeal round fully funded by _party. Starts from 0.
     */
    event HasPaidAppealFee(uint256 indexed _itemID, uint256 _ruling, uint256 _round);

    /**
     *  @dev To be emitted when someone contributes to the appeal process.
     *  @param _itemID The ID of the respective transaction.
     *  @param _ruling The ruling which received the contribution.
     *  @param _contributor The address of the contributor.
     *  @param _round The appeal round to which the contribution is going. Starts from 0.
     *  @param _amount The amount contributed.
     */
    event AppealContribution(uint256 indexed _itemID, uint256 _ruling, address indexed _contributor, uint256 _round, uint256 _amount);

    function setMultipliers(
        ArbitrableStorage storage self, 
        uint256 _sharedStakeMultiplier, 
        uint256 _winnerStakeMultiplier, 
        uint256 _loserStakeMultiplier
        ) internal {
        self.sharedStakeMultiplier = _sharedStakeMultiplier;
        self.winnerStakeMultiplier = _winnerStakeMultiplier;
        self.loserStakeMultiplier = _loserStakeMultiplier;
    }
    
    function setArbitrator(
        ArbitrableStorage storage self, 
        IArbitrator _arbitrator, 
        bytes memory _arbitratorExtraData
        ) internal {
        require(self.arbitrator == IArbitrator(0x0), "Arbitrator already set.");
        require(_arbitrator != IArbitrator(0x0), "Invalid arbitrator address.");
        self.arbitrator = _arbitrator;
        self.arbitratorExtraData = _arbitratorExtraData;
    }

    function createDispute(
        ArbitrableStorage storage self, 
        uint256 itemID,
        uint256 _arbitrationCost,
        uint256 _metaEvidenceID,
        uint256 _evidenceGroupID
    ) internal returns(uint256 disputeID) {

        ItemData storage item = self.items[itemID];
        require(item.status != Status.Undisputed, "Item already disputed.");
        item.status = Status.Disputed;
        disputeID = self.arbitrator.createDispute{value: _arbitrationCost}(MAX_NO_OF_CHOICES, self.arbitratorExtraData);
        item.rounds.push();
        self.disputeIDtoItemID[disputeID] = itemID;
        item.disputeID = disputeID;
        emit Dispute(self.arbitrator, disputeID, _metaEvidenceID, _evidenceGroupID);
    }

    function submitEvidence(
        ArbitrableStorage storage self, 
        uint256 itemID,
        uint256 evidenceGroupID,
        string memory _evidence
    ) internal {
        require(
            self.items[itemID].status < Status.Resolved,
            "Must not send evidence if the dispute is resolved."
        );

        if (bytes(_evidence).length > 0)
            emit Evidence(self.arbitrator, evidenceGroupID, msg.sender, _evidence);
    }

    function fundAppeal(
        ArbitrableStorage storage self, 
        uint256 itemID,
        uint256 ruling
    ) internal returns(uint256 disputeID) {
        ItemData storage item = self.items[itemID];
        require(item.status == Status.Disputed, "No ongoing dispute to appeal.");
        require(ruling != 0, "Invalid ruling.");

        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = self.arbitrator.appealPeriod(item.disputeID);
        require(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd, "Not in appeal period.");

        uint256 multiplier;
        uint256 winner = self.arbitrator.currentRuling(item.disputeID);
        if (winner == ruling){
            multiplier = self.winnerStakeMultiplier;
        } else if (winner == 0){
            multiplier = self.sharedStakeMultiplier;
        } else {
            require(block.timestamp < (appealPeriodEnd + appealPeriodStart)/2, "Not in loser's appeal period.");
            multiplier = self.loserStakeMultiplier;
        }

        Round storage round = item.rounds[item.rounds.length - 1];
        require(ruling != round.rulingsFunded[0], "Appeal fee has already been paid.");

        uint256 appealCost = self.arbitrator.appealCost(item.disputeID, self.arbitratorExtraData);
        uint256 totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);

        // Take up to the amount necessary to fund the current round at the current costs.
        uint256 contribution;
        uint256 remainingETH;
        (contribution, remainingETH) = calculateContribution(msg.value, totalCost.subCap(round.paidFees[ruling]));
        round.contributions[msg.sender][ruling] += contribution;
        round.paidFees[ruling] += contribution;
        emit AppealContribution(itemID, ruling, msg.sender, item.rounds.length - 1, contribution);

        // Reimburse leftover ETH if any.
        if (remainingETH > 0)
            msg.sender.send(remainingETH); // Deliberate use of send in order to not block the contract in case of reverting fallback.

        if (round.paidFees[ruling] >= totalCost) {
            emit HasPaidAppealFee(itemID, ruling, item.rounds.length - 1);
            if (round.rulingsFunded[0] == 0) {
                round.rulingsFunded[0] = ruling;
            } else {
                // Two rulings are fully funded. Create an appeal.
                self.arbitrator.appeal{value: appealCost}(disputeID, self.arbitratorExtraData);
                round.rulingsFunded[1] = ruling;
                round.feeRewards = (round.paidFees[round.rulingsFunded[0]] + round.paidFees[ruling]).subCap(appealCost);
                item.rounds.push();
            }
        }
    }

    function _withdrawFeesAndRewards(
        ArbitrableStorage storage self, 
        uint256 _itemID, 
        address _beneficiary, 
        uint256 _ruling,
        uint256 _round
        ) internal returns(uint256 reward) {

        ItemData storage item = self.items[_itemID];
        Round storage round = item.rounds[_round];
        mapping(uint256 => uint256) storage contributionTo = round.contributions[_beneficiary];
        uint256 lastRound = item.rounds.length - 1;

        if (_round == lastRound || (round.rulingsFunded[0] != _ruling && round.rulingsFunded[1] != _ruling)) {
            // Allow to reimburse if funding was unsuccessful, i.e. appeal wasn't created or ruling wasn't fully funded.
            reward = contributionTo[_ruling];
            contributionTo[_ruling] = 0;
        } else if (round.rulingsFunded[0] != item.ruling && round.rulingsFunded[1] != item.ruling) {
            // Reimburse unspent fees proportionally, if none of the funding rulings won.
            uint256 totalFeesPaid = round.paidFees[round.rulingsFunded[0]] + round.paidFees[round.rulingsFunded[1]];
            uint256 totalBeneficiaryContributions = contributionTo[round.rulingsFunded[0]] + contributionTo[round.rulingsFunded[1]];
            reward = totalFeesPaid > 0 ? (totalBeneficiaryContributions * round.feeRewards) / totalFeesPaid : 0;

            contributionTo[round.rulingsFunded[0]] = 0;
            contributionTo[round.rulingsFunded[1]] = 0;
        } else if (_ruling == item.ruling) {
            // Reward the winner.
            reward = round.paidFees[item.ruling] > 0
                ? (contributionTo[item.ruling] * round.feeRewards) / round.paidFees[item.ruling]
                : 0;
            contributionTo[item.ruling] = 0;
        }
    }

    function withdrawFeesAndRewards(
        ArbitrableStorage storage self, 
        uint256 _itemID, 
        address payable _beneficiary, 
        uint256 _ruling, 
        uint256 _round
    ) internal {
        require(self.items[_itemID].status == Status.Resolved, "Dispute not resolved.");
        uint256 reward = _withdrawFeesAndRewards(self, _itemID, _beneficiary, _ruling, _round);
        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }
    
    function withdrawRoundBatch(
        ArbitrableStorage storage self, 
        uint256 _itemID, 
        address payable _beneficiary, 
        uint256 _ruling, 
        uint256 _cursor, 
        uint256 _count
    ) internal {

        ItemData storage item = self.items[_itemID];
        require(item.status == Status.Resolved, "Dispute not resolved.");

        uint256 maxRound = _count == 0 ? item.rounds.length : _cursor + _count;
        uint256 reward;
        if (maxRound > item.rounds.length)
            maxRound = item.rounds.length;
        for (uint256 i = _cursor; i < maxRound; i++)
            reward += _withdrawFeesAndRewards(self, _itemID, _beneficiary, _ruling, i);
        
        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }

    function withdrawMultipleRulings(
        ArbitrableStorage storage self, 
        uint256 _itemID, 
        address payable _beneficiary,
        uint256[] memory _rulings,
        uint256 _round
    ) internal {
        ItemData storage item = self.items[_itemID];
        require(item.status == Status.Resolved, "Dispute not resolved.");

        uint256 reward;
        for (uint256 i = 0; i < _rulings.length; i++) 
            reward += _withdrawFeesAndRewards(self, _itemID, _beneficiary, _rulings[i], _round);
        
        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }

    function amountWithdrawable(
        ArbitrableStorage storage self, 
        uint256 _itemID, 
        address _beneficiary, 
        uint256 _ruling
    ) internal view returns(uint256 total) {
        
        ItemData storage item = self.items[_itemID];
        if (item.status != Status.Resolved) return total;   

        uint256 totalRounds = item.rounds.length;
        for (uint256 i = 0; i < totalRounds; i++) {
            Round storage round = item.rounds[i];
            mapping(uint256 => uint256) storage contributionTo = round.contributions[_beneficiary];
            if (i == totalRounds-1 || (round.rulingsFunded[0] != _ruling && round.rulingsFunded[1] != _ruling)) {
                // Allow to reimburse if funding was unsuccessful, i.e. appeal wasn't created or ruling wasn't fully funded.
                total += contributionTo[_ruling];
            } else if (round.rulingsFunded[0] != item.ruling && round.rulingsFunded[1] != item.ruling) {
                // Reimburse unspent fees proportionally, if none of the funding rulings won.
                uint256 totalFeesPaid = round.paidFees[round.rulingsFunded[0]] + round.paidFees[round.rulingsFunded[1]];
                uint256 totalBeneficiaryContributions = contributionTo[round.rulingsFunded[0]] + contributionTo[round.rulingsFunded[1]];
                total += totalFeesPaid > 0 ? (totalBeneficiaryContributions * round.feeRewards) / totalFeesPaid : 0;
            } else if (_ruling == item.ruling) {
                // Reward the winner.
                total += round.paidFees[item.ruling] > 0
                    ? (contributionTo[item.ruling] * round.feeRewards) / round.paidFees[item.ruling]
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

    function getFinalRuling(ArbitrableStorage storage self, uint256 itemID) internal view returns(uint256) {
        ItemData storage item = self.items[itemID];
        require(item.status == Status.Resolved, "Arbitrator has not ruled yet.");
        return item.ruling;
    }

    function getNumberOfRounds(ArbitrableStorage storage self, uint256 _itemID) internal view returns (uint256) {
        return self.items[_itemID].rounds.length;
    }

    function getRoundInfo(
        ArbitrableStorage storage self, 
        uint256 _itemID, 
        uint256 _round
    ) internal view returns(
        uint256[2] memory paidFees,
        uint256[2] memory rulingsFunded,
        uint256 feeRewards,
        bool appealed
    ) {
        ItemData storage item = self.items[_itemID];
        Round storage round = item.rounds[_round];

        paidFees[0] = round.paidFees[round.rulingsFunded[0]];
        paidFees[1] = round.paidFees[round.rulingsFunded[1]];

        return (
            paidFees,
            round.rulingsFunded,
            round.feeRewards,
            _round != item.rounds.length - 1
        );
    }

    function getFundingStatus(
        ArbitrableStorage storage self, 
        uint256 _itemID, 
        uint256 _round,
        uint256 _ruling
    ) internal view returns(uint feesRaised, bool fullyFunded) {
        ItemData storage item = self.items[_itemID];
        Round storage round = item.rounds[_round];

        feesRaised = round.paidFees[_ruling];
        fullyFunded = round.rulingsFunded[0] == _ruling || round.rulingsFunded[1] == _ruling;
    }

    function getContributionsToSuccessfulFundings(
        ArbitrableStorage storage self, 
        uint256 _itemID,
        uint256 _round,
        address _contributor
    ) internal view returns(uint[2] memory rulingsFunded, uint[2] memory contributions) {
        ItemData storage item = self.items[_itemID];
        Round storage round = item.rounds[_round];

        rulingsFunded = round.rulingsFunded;
        contributions[0] = round.contributions[_contributor][rulingsFunded[0]];
        contributions[1] = round.contributions[_contributor][rulingsFunded[1]];
    }
}