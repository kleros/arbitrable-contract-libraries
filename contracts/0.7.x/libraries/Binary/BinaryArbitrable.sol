/**
 *  @authors: [@fnanni-0]
 *  @reviewers: [@hbarcelos]
 *  @auditors: []
 *  @bounties: []
 */

pragma solidity >=0.7;

import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

library BinaryArbitrable {
    using CappedMath for uint256;

    /* *** Contract variables *** */
    uint256 public constant AMOUNT_OF_CHOICES = 2;
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.
    uint256 private constant PARTY_A = 1; // Represents the ruling option 1.
    uint256 private constant PARTY_B = 2; // Represents the ruling option 2.

    enum Status {None, Disputed, Resolved}

    struct Round {
        uint256[3] paidFees; // Tracks the fees paid by each ruling in this round.
        uint256 rulingFunded; // {0, 1, 2} If the round is appealed, i.e. this is not the last round, 0 means that both rulings (1 and 2) have paid.
        uint256 feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the ruling that ultimately wins a dispute.
        mapping(address => uint256[3]) contributions; // Maps contributors to their contributions for each ruling.
    }

    struct ItemData {
        Round[] rounds;
        Status status;
        uint256 ruling; // Gas saving opportunity
        uint256 disputeID;
    }

    struct ArbitrableStorage {
        IArbitrator arbitrator; // Address of the arbitrator contract. TRUSTED. Should only be set once.
        bytes arbitratorExtraData; // Extra data to set up the arbitration. Should only be set once.
        uint256 sharedStakeMultiplier; // Multiplier for calculating the appeal fee that must be paid by the submitter in the case where there is no winner or loser (e.g. when the arbitrator ruled "refuse to arbitrate").
        uint256 winnerStakeMultiplier; // Multiplier for calculating the appeal fee of the party that won the previous round.
        uint256 loserStakeMultiplier; // Multiplier for calculating the appeal fee of the party that lost the previous round.
        mapping(uint256 => ItemData) items; // items[itemID]
        mapping(uint256 => uint256) disputeIDtoItemID; // disputeIDtoItemID[disputeID]
    }

    /* *** Events *** */

    /// @dev When a library function emits an event, Solidity requires the event to be defined both inside the library and in the contract where the library is used. Make sure that your arbitrable contract inherits the interfaces mentioned below in order to comply with this (IArbitrable, IEvidence and IAppealEvents).
    /// @dev See {@kleros/erc-792/contracts/IArbitrable.sol}
    event Ruling(IArbitrator indexed _arbitrator, uint256 indexed _disputeID, uint256 _ruling);

    /// @dev See {@kleros/erc-792/contracts/erc-1497/IEvidence.sol}
    event Evidence(IArbitrator indexed _arbitrator, uint256 indexed _evidenceGroupID, address indexed _party, string _evidence);

    /// @dev See {@kleros/erc-792/contracts/erc-1497/IEvidence.sol}
    event Dispute(IArbitrator indexed _arbitrator, uint256 indexed _disputeID, uint256 _metaEvidenceID, uint256 _evidenceGroupID);

    /// @dev See {@kleros/appeal-utils/contracts/0.7.x/interfaces/IAppealEvents.sol}
    event HasPaidAppealFee(uint256 indexed _itemID, uint256 indexed _ruling, uint256 _round);

    /// @dev See {@kleros/appeal-utils/contracts/0.7.x/interfaces/IAppealEvents.sol}
    event AppealContribution(uint256 indexed _itemID, uint256 indexed _ruling, address indexed _contributor, uint256 _round, uint256 _amount);

    /// @dev See {@kleros/appeal-utils/contracts/0.7.x/interfaces/IAppealEvents.sol}
    event Withdrawal(uint256 indexed _itemID, uint256 indexed _round, uint256 _ruling, address indexed _contributor, uint256 _reward);

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
        require(_arbitrator != IArbitrator(0x0), "Invalid arbitrator.");
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
        require(item.status == Status.None, "Item already disputed.");
        item.status = Status.Disputed;
        disputeID = self.arbitrator.createDispute{value: _arbitrationCost}(AMOUNT_OF_CHOICES, self.arbitratorExtraData);
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

    /** @dev Takes up to the total amount required to fund a ruling of an appeal. Reimburses the rest. Creates an appeal if both rulings (1 and 2) are fully funded.
     *  @param _itemID The ID of the disputed item.
     *  @param _ruling The ruling to which the contribution is made.
     */
    function fundAppeal(ArbitrableStorage storage self, uint256 _itemID, uint256 _ruling) internal {
        ItemData storage item = self.items[_itemID];
        require(item.status == Status.Disputed, "No ongoing dispute to appeal.");
        require(_ruling != 0 && _ruling <= AMOUNT_OF_CHOICES, "Invalid ruling.");

        Round storage round = item.rounds[item.rounds.length - 1];
        require(_ruling != round.rulingFunded, "Appeal fee has already been paid.");

        (uint256 appealCost, uint256 totalCost) = getAppealFeeComponents(self, _itemID, _ruling);

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
            if (round.rulingFunded == 0) {
                round.rulingFunded = _ruling;
            } else {
                // Both rulings are fully funded. Create an appeal.
                self.arbitrator.appeal{value: appealCost}(item.disputeID, self.arbitratorExtraData);
                round.feeRewards = (round.paidFees[PARTY_A] + round.paidFees[PARTY_B]).subCap(appealCost);
                round.rulingFunded = 0; // clear storage
                item.rounds.push();
            }
        }
    }

    /** @dev Validates and registers the ruling for a dispute. Can only be called by the arbitrator.
     *  The purpose of this function is to ensure that the address calling it has the right to rule on the contract. The ruling is inverted if a party loses from lack of appeal fees funding.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refuse to arbitrate".
     */
    function processRuling(
        ArbitrableStorage storage self, 
        uint256 _disputeID, 
        uint256 _ruling
    ) internal returns(uint256 finalRuling) {
        
        uint256 itemID = self.disputeIDtoItemID[_disputeID];
        ItemData storage item = self.items[itemID];

        require(item.status == Status.Disputed, "Invalid dispute status.");
        require(msg.sender == address(self.arbitrator), "The caller must be the arbitrator.");
        require(_ruling <= AMOUNT_OF_CHOICES, "Invalid ruling.");

        Round storage round = item.rounds[item.rounds.length - 1];

        // If only one ruling was fully funded, we considered it the winner, regardless of the arbitrator's decision.
        if (round.rulingFunded == 0)
            finalRuling = _ruling;
        else
            finalRuling = round.rulingFunded;

        item.status = Status.Resolved;
        item.ruling = finalRuling;

        emit Ruling(self.arbitrator, _disputeID, finalRuling);
    }

    /** @dev Calculates the reward that the _beneficiary is entitled to at _round and registers the withdrawal.
     *  Beware that this function does NOT check the status of the dispute and does NOT send the rewards to the _beneficiary. Use withdrawFeesAndRewards() for that purpose.
     *  @param _itemID The ID of the disputed item.
     *  @param _beneficiary The address that made contributions.
     *  @param _round The round from which to withdraw.
     *  @return reward The reward value that was withdrawn and can be sent to the _beneficiary.
     */
    function _registerWithdrawal(
        ArbitrableStorage storage self, 
        uint256 _itemID, 
        address _beneficiary, 
        uint256 _round
    ) internal returns(uint256 reward) {

        ItemData storage item = self.items[_itemID];
        Round storage round = item.rounds[_round];
        uint256[3] storage contributionTo = round.contributions[_beneficiary];
        uint256 lastRound = item.rounds.length - 1;

        if (_round == lastRound) {
            // Allow to reimburse if funding was unsuccessful.
            reward = contributionTo[PARTY_A] + contributionTo[PARTY_B];
        } else if (item.ruling == 0) {
            // Reimburse unspent fees proportionally if there is no winner and loser.
            uint256 totalFeesPaid = round.paidFees[PARTY_A] + round.paidFees[PARTY_B];
            uint256 totalBeneficiaryContributions = contributionTo[PARTY_A] + contributionTo[PARTY_B];
            reward = totalFeesPaid > 0 ? (totalBeneficiaryContributions * round.feeRewards) / totalFeesPaid : 0;
        } else {
            // Reward the winner.
            reward = round.paidFees[item.ruling] > 0
                ? (contributionTo[item.ruling] * round.feeRewards) / round.paidFees[item.ruling]
                : 0;
        }
        contributionTo[PARTY_A] = 0;
        contributionTo[PARTY_B] = 0;

        // The beneficiary doesn't withdraw fees and rewards from a particular ruling but from any. Therefore, the 'ruling' field of Withdrawal is left undefined (0).
        emit Withdrawal(_itemID, _round, 0, _beneficiary, reward);
    }

    /** @dev Withdraws contributions of appeal rounds. Reimburses contributions if the appeal was not fully funded. 
     *  If the appeal was fully funded, sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute.
     *  @param _itemID The ID of the disputed item.
     *  @param _beneficiary The address that made the contributions.
     *  @param _round The round from which to withdraw.
     */
    function withdrawFeesAndRewards(
        ArbitrableStorage storage self, 
        uint256 _itemID, 
        address payable _beneficiary, 
        uint256 _round
    ) internal {
        require(self.items[_itemID].status == Status.Resolved, "Dispute not resolved.");
        uint256 reward = _registerWithdrawal(self, _itemID, _beneficiary, _round);
        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }
    
    /** @dev Withdraws contributions of multiple appeal rounds at once. This function is O(n) where n is the number of rounds. 
     *  This could exceed the gas limit, therefore this function should be used only as a utility and not be relied upon by other contracts.
     *  @param _itemID The ID of the disputed item.
     *  @param _beneficiary The address that made the contributions.
     *  @param _cursor The round from where to start withdrawing.
     *  @param _count The number of rounds to iterate. If set to 0 or a value larger than the number of rounds, iterates until the last round.
     */
    function batchWithdrawFeesAndRewards(
        ArbitrableStorage storage self, 
        uint256 _itemID, 
        address payable _beneficiary, 
        uint256 _cursor, 
        uint256 _count
    ) internal {

        ItemData storage item = self.items[_itemID];
        require(item.status == Status.Resolved, "Dispute not resolved.");

        uint256 maxRound = _count == 0 ? item.rounds.length : _cursor + _count;
        if (maxRound > item.rounds.length)
            maxRound = item.rounds.length;
        uint256 reward;
        for (uint256 i = _cursor; i < maxRound; i++)
            reward += _registerWithdrawal(self, _itemID, _beneficiary, i);

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
     *  @return total The reward value to which the _beneficiary is entitled.
     */
    function withdrawableAmount(
        ArbitrableStorage storage self, 
        uint256 _itemID, 
        address _beneficiary
    ) internal view returns(uint256 total) {

        ItemData storage item = self.items[_itemID];
        if (item.status != Status.Resolved) return total;        

        uint256 totalRounds = item.rounds.length;
        for (uint256 i = 0; i < totalRounds; i++) {
            Round storage round = item.rounds[i];
            if (i == totalRounds - 1) {
                total += round.contributions[_beneficiary][PARTY_A] + round.contributions[_beneficiary][PARTY_B];
            } else if (item.ruling == 0) {
                uint256 totalFeesPaid = round.paidFees[PARTY_A] + round.paidFees[PARTY_B];
                uint256 totalBeneficiaryContributions = round.contributions[_beneficiary][PARTY_A] + round.contributions[_beneficiary][PARTY_B];
                total += totalFeesPaid > 0 ? (totalBeneficiaryContributions * round.feeRewards) / totalFeesPaid : 0;
            } else {
                total += round.paidFees[item.ruling] > 0
                    ? (round.contributions[_beneficiary][item.ruling] * round.feeRewards) / round.paidFees[item.ruling]
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

    /**
     *  @dev Calculates the appeal fee and total cost for an arbitration.
     *  @param _itemID The ID of the disputed item.
     *  @param _ruling The ruling to which the contribution is made.
     *  @return appealCost The appeal fee charged by the arbitrator.  @return totalCost The total cost for appealing.
    */
    function getAppealFeeComponents(
        ArbitrableStorage storage self,
        uint256 _itemID,
        uint256 _ruling
    ) internal view returns (uint256 appealCost, uint256 totalCost) {
        ItemData storage item = self.items[_itemID];

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

        appealCost = self.arbitrator.appealCost(item.disputeID, self.arbitratorExtraData);
        totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);
    }

    /** @dev Gets the final ruling if the dispute is resolved.
     *  @param _itemID The ID of the disputed item.
     *  @return The ruling that won the dispute.
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
     *  @return paidFees rulingFunded feeRewards appealed The round information.
     */
    function getRoundInfo(
        ArbitrableStorage storage self, 
        uint256 _itemID, 
        uint256 _round
        ) internal view returns(
            uint256[3] memory paidFees,
            uint256 rulingFunded,
            uint256 feeRewards,
            bool appealed
        ) {
        
        ItemData storage item = self.items[_itemID];
        Round storage round = item.rounds[_round];

        return (
            round.paidFees,
            round.rulingFunded,
            round.feeRewards,
            _round != item.rounds.length - 1
        );
    }

    /** @dev Gets the contributions made by a party for a given round of appeal of a disputed item.
     *  @param _itemID The ID of the disputed item.
     *  @param _round The round number.
     *  @param _contributor The address of the contributor.
     *  @return contributions Array of contributions order according to Party enum.
     */
    function getContributions(
        ArbitrableStorage storage self, 
        uint256 _itemID, 
        uint256 _round,
        address _contributor
    ) internal view returns(uint256[3] memory contributions) {
        
        ItemData storage item = self.items[_itemID];
        Round storage round = item.rounds[_round];
        contributions = round.contributions[_contributor];
    }

}