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

    /* *** Contract variables *** */
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

    /* *** Events *** */

    /// @dev events have to be defined both in the library and in the contract where the library is used.
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

    // **************************** //
    // *    Modifying the state   * //
    // **************************** //

    /** @dev Changes the stake multipliers.
     *  @param _sharedStakeMultiplier A new value of the multiplier for calculating appeal fees. In basis points.
     *  @param _winnerStakeMultiplier A new value of the multiplier for calculating appeal fees. In basis points.
     *  @param _loserStakeMultiplier A new value of the multiplier for calculating appeal fees. In basis points.
     */
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
    
    /** @dev Sets the arbitrator data. Can only be set once.
     *  @param _arbitrator The address of the arbitrator contract the is going to be used for every dispute created.
     *  @param _arbitratorExtraData The extra data for the arbitrator.
     */
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

    /** @dev Invokes the arbitrator to create a dispute. Requires _arbitrationCost ETH. It's the arbitrable contract responsability to make sure the amount of ETH available in the contract is enough.
     *  @param _itemID The ID of the disputable item.
     *  @param _arbitrationCost Value in wei, as defined in getArbitrationCost(), that is needed to create a dispute. 
     *  @param _metaEvidenceID The ID of the meta-evidence of the dispute as defined in the ERC-1497 standard.
     *  @param _evidenceGroupID The ID of the evidence group the evidence belongs to.
     *  @return disputeID The ID assigned by the arbitrator to the newly created dispute.
     */
    function createDispute(
        ArbitrableStorage storage self, 
        uint256 _itemID,
        uint256 _arbitrationCost,
        uint256 _metaEvidenceID,
        uint256 _evidenceGroupID
    ) internal returns(uint256 disputeID) {

        ItemData storage item = self.items[_itemID];
        require(item.status == Status.Undisputed, "Item already disputed.");
        item.status = Status.Disputed;
        disputeID = self.arbitrator.createDispute{value: _arbitrationCost}(MAX_NO_OF_CHOICES, self.arbitratorExtraData);
        item.rounds.push();
        self.disputeIDtoItemID[disputeID] = _itemID;
        item.disputeID = disputeID;
        emit Dispute(self.arbitrator, disputeID, _metaEvidenceID, _evidenceGroupID);
    }

    /** @dev Submits a reference to evidence. EVENT.
     *  @param _itemID The ID of the disputable item.
     *  @param _evidenceGroupID ID of the evidence group the evidence belongs to. It must match the one used in createDispute().
     *  @param _evidence A link to evidence using its URI.
     */
    function submitEvidence(
        ArbitrableStorage storage self, 
        uint256 _itemID,
        uint256 _evidenceGroupID,
        string memory _evidence
    ) internal {
        require(
            self.items[_itemID].status < Status.Resolved,
            "Must not send evidence if the dispute is resolved."
        );

        if (bytes(_evidence).length > 0)
            emit Evidence(self.arbitrator, _evidenceGroupID, msg.sender, _evidence);
    }

    /** @dev Takes up to the total amount required to fund a side of an appeal. Reimburses the rest. Creates an appeal if all sides are fully funded.
     *  @param _itemID The ID of the disputed item.
     *  @param _ruling The ruling to which the contribution is made.
     */
    function fundAppeal(
        ArbitrableStorage storage self, 
        uint256 _itemID,
        uint256 _ruling
    ) internal returns(uint256 disputeID) {
        ItemData storage item = self.items[_itemID];
        require(item.status == Status.Disputed, "No ongoing dispute to appeal.");
        require(_ruling != 0, "Invalid ruling.");

        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = self.arbitrator.appealPeriod(item.disputeID);
        require(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd, "Not in appeal period.");

        uint256 multiplier;
        uint256 winner = self.arbitrator.currentRuling(item.disputeID);
        if (winner == _ruling){
            multiplier = self.winnerStakeMultiplier;
        } else if (winner == 0){
            multiplier = self.sharedStakeMultiplier;
        } else {
            require(block.timestamp < (appealPeriodEnd + appealPeriodStart)/2, "Not in loser's appeal period.");
            multiplier = self.loserStakeMultiplier;
        }

        Round storage round = item.rounds[item.rounds.length - 1];
        require(_ruling != round.rulingsFunded[0], "Appeal fee has already been paid.");

        uint256 appealCost = self.arbitrator.appealCost(item.disputeID, self.arbitratorExtraData);
        uint256 totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);

        // Take up to the amount necessary to fund the current round at the current costs.
        uint256 contribution;
        uint256 remainingETH;
        (contribution, remainingETH) = calculateContribution(msg.value, totalCost.subCap(round.paidFees[_ruling]));
        round.contributions[msg.sender][_ruling] += contribution;
        round.paidFees[_ruling] += contribution;
        emit AppealContribution(_itemID, _ruling, msg.sender, item.rounds.length - 1, contribution);

        // Reimburse leftover ETH if any.
        if (remainingETH > 0)
            msg.sender.send(remainingETH); // Deliberate use of send in order to not block the contract in case of reverting fallback.

        if (round.paidFees[_ruling] >= totalCost) {
            emit HasPaidAppealFee(_itemID, _ruling, item.rounds.length - 1);
            if (round.rulingsFunded[0] == 0) {
                round.rulingsFunded[0] = _ruling;
            } else {
                // Two rulings are fully funded. Create an appeal.
                self.arbitrator.appeal{value: appealCost}(disputeID, self.arbitratorExtraData);
                round.rulingsFunded[1] = _ruling;
                round.feeRewards = (round.paidFees[round.rulingsFunded[0]] + round.paidFees[_ruling]).subCap(appealCost);
                item.rounds.push();
            }
        }
    }

    /** @dev Calculates the reward that the _beneficiary is entitled to at _round and clears the storage.
     *  Beware that this function does NOT check the status of the dispute and does NOT send the rewards to the _beneficiary. Use withdrawFeesAndRewards() for that purpose.
     *  @param _itemID The ID of the disputed item.
     *  @param _beneficiary The address that made contributions.
     *  @param _ruling The ruling to which the contributions were made.
     *  @param _round The round from which to withdraw.
     *  @return reward The reward value that was withdrawn and can be sent to the _beneficiary.
     */
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
            // Notice that in practice jurors can vote for rulings that didn't fund the appeal. If this happens, Contributor to the winner ruling are only entitle to receive their contributions back.
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

    /** @dev Withdraws contributions of appeal rounds. Reimburses contributions if the appeal was not fully funded. 
     *  If the appeal was fully funded, sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute.
     *  @param _itemID The ID of the disputed item.
     *  @param _beneficiary The address that made contributions.
     *  @param _ruling The ruling to which the contributions were made.
     *  @param _round The round from which to withdraw.
     */
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
    
    /** @dev Withdraws contributions of multiple appeal rounds at once. This function is O(n) where n is the number of rounds. 
     *  This could exceed the gas limit, therefore this function should be used only as a utility and not be relied upon by other contracts.
     *  @param _itemID The ID of the disputed item.
     *  @param _beneficiary The address that made the contributions.
     *  @param _ruling The ruling to which the contributions were made.
     *  @param _cursor The round from where to start withdrawing.
     *  @param _count The number of rounds to iterate. If set to 0 or a value larger than the number of rounds, iterates until the last round.
     */
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

    /** @dev Withdraws contributions of multiple rulings for given round at once. This function is O(n) where n is the number of rulings. 
     *  This could exceed the gas limit, therefore this function should be used only as a utility and not be relied upon by other contracts.
     *  @param _itemID The ID of the disputed item.
     *  @param _beneficiary The address that made the contributions.
     *  @param _rulings Array of rulings to which the contributions were made.
     *  @param _round The round from which to withdrawing.
     */
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

    // ******************** //
    // *      Getters     * //
    // ******************** //

    /** @dev Gets the rewards withdrawable for a given ruling taken into account all rounds. 
     *  This function is O(n) where n is the number of rounds. 
     *  This could exceed the gas limit, therefore this function should be used only as a utility and not be relied upon by other contracts.
     *  @param _itemID The ID of the disputed item.
     *  @param _beneficiary The address that made the contributions.
     *  @param _ruling The ruling to which the contributions were made.
     *  @return total The reward value to which the _beneficiary is entitled.
     */
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
    function calculateContribution(
        uint256 _available,
        uint256 _requiredAmount
    ) internal pure returns(uint256 taken, uint256 remainder) {
        if (_requiredAmount > _available)
            return (_available, 0); // Take whatever is available, return 0 as leftover ETH.

        remainder = _available - _requiredAmount;
        return (_requiredAmount, remainder);
    }

    /** @dev Gets the final ruling if the dispute is resolved.
     *  @param _itemID The ID of the disputed item.
     *  @return The ruling the won the dispute.
     */
    function getFinalRuling(ArbitrableStorage storage self, uint256 _itemID) internal view returns(uint256) {
        ItemData storage item = self.items[_itemID];
        require(item.status == Status.Resolved, "Arbitrator has not ruled yet.");
        return item.ruling;
    }

    /** @dev Gets the cost of arbitration using the given arbitrator and arbitratorExtraData.
     *  @return Arbitration cost.
     */
    function getArbitrationCost(ArbitrableStorage storage self) internal view returns(uint256) {
        return self.arbitrator.arbitrationCost(self.arbitratorExtraData);
    }

    /** @dev Gets the number of rounds of the specific item.
     *  @param _itemID The ID of the disputed item.
     *  @return The number of rounds.
     */
    function getNumberOfRounds(ArbitrableStorage storage self, uint256 _itemID) internal view returns (uint256) {
        return self.items[_itemID].rounds.length;
    }

    /** @dev Gets the information on a round of a disputed item.
     *  @param _itemID The ID of the disputed item.
     *  @param _round The round to be queried.
     *  @return paidFees sideFunded feeRewards appealed The round information.
     */
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

    /** @dev Gets the current fundings raised for a ruling at a given round.
     *  @param _itemID The ID of the disputed item.
     *  @param _round The round number.
     *  @param _ruling The address of the contributor.
     *  @return feesRaised fullyFunded contributions Array of funded rulings and the contributions the beneficiary made to them.
     */
    function getFundingStatus(
        ArbitrableStorage storage self, 
        uint256 _itemID, 
        uint256 _round,
        uint256 _ruling
    ) internal view returns(uint256 feesRaised, bool fullyFunded) {
        ItemData storage item = self.items[_itemID];
        Round storage round = item.rounds[_round];

        feesRaised = round.paidFees[_ruling];
        fullyFunded = round.rulingsFunded[0] == _ruling || round.rulingsFunded[1] == _ruling;
    }

    /** @dev Gets the contributions made by a party for a given round of appeal of a disputed item.
     *  @param _itemID The ID of the disputed item.
     *  @param _round The round number.
     *  @param _contributor The address of the contributor.
     *  @return rulingsFunded contributions Array of funded rulings and the contributions the beneficiary made to them.
     */
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