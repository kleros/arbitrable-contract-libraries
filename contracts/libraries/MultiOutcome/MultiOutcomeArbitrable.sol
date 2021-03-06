/**
 *  @authors: [@fnanni-0]
 *  @reviewers: [@epiqueras*]
 *  @auditors: []
 *  @bounties: []
 */

pragma solidity >=0.7;

import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

library MultiOutcomeArbitrable {
    using CappedMath for uint256;

    /* *** Contract variables *** */
    uint256 private constant MAX_NO_OF_CHOICES = type(uint256).max;
    uint256 private constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    enum Status {None, Disputed, Resolved}

    struct Round {
        mapping(uint256 => uint256) paidFees; // Tracks the fees paid by each ruling in this round.
        uint256 rulingFunded; // If the round is appealed, i.e. this is not the last round, 0 means that 2 rulings were fully funded.
        uint256 totalFees; // Sum of fees paid during the funding of the appeal round.
        uint256 appealCost; // Fees sent to the arbitrator in order to appeal.
        mapping(address => mapping(uint256 => uint256)) contributions; // Maps contributors to their contributions for each ruling.
    }

    struct DisputeData {
        mapping(uint256 => Round) rounds;
        uint248 roundCounter;
        Status status;
        uint256 ruling;
        uint256 disputeIDOnArbitratorSide;
    }

    struct ArbitrableStorage {
        IArbitrator arbitrator; // Address of the arbitrator contract. Should only be set once. TRUSTED.
        bytes arbitratorExtraData; // Extra data to set up the arbitration.     
        uint256 sharedStakeMultiplier; // Multiplier for calculating the appeal fee that must be paid by the submitter in the case where there is no winner or loser (e.g. when the arbitrator ruled "refuse to arbitrate").
        uint256 winnerStakeMultiplier; // Multiplier for calculating the appeal fee of the party that won the previous round.
        uint256 loserStakeMultiplier; // Multiplier for calculating the appeal fee of the party that lost the previous round.
        mapping(uint256 => DisputeData) disputes; // disputes[localDisputeID]
        mapping(uint256 => uint256) externalIDtoLocalID; // Maps external (arbitrator's side) dispute ids to local dispute ids. The local dispute ids must be defined by the arbitrable contract. externalIDtoLocalID[disputeIDOnArbitratorSide]
    }

    /* *** Events *** */

    /// @dev When a library function emits an event, Solidity requires the event to be defined both inside the library and in the contract where the library is used. Make sure that your arbitrable contract inherits the interfaces mentioned below in order to comply with this (IArbitrable, IEvidence and IAppealEvents).
    /// @dev See {@kleros/erc-792/contracts/IArbitrable.sol}.
    event Ruling(IArbitrator indexed _arbitrator, uint256 indexed _disputeIDOnArbitratorSide, uint256 _ruling);

    /// @dev See {@kleros/erc-792/contracts/erc-1497/IEvidence.sol}.
    event Evidence(IArbitrator indexed _arbitrator, uint256 indexed _evidenceGroupID, address indexed _party, string _evidence);

    /// @dev See {@kleros/erc-792/contracts/erc-1497/IEvidence.sol}.
    event Dispute(IArbitrator indexed _arbitrator, uint256 indexed _disputeIDOnArbitratorSide, uint256 _metaEvidenceID, uint256 _evidenceGroupID);

    /// @dev See {https://github.com/kleros/arbitrable-contract-libraries/blob/main/contracts/interfaces/IAppealEvents.sol}.
    event HasPaidAppealFee(uint256 indexed _localDisputeID, uint256 _round, uint256 indexed _ruling);

    /// @dev See {https://github.com/kleros/arbitrable-contract-libraries/blob/main/contracts/interfaces/IAppealEvents.sol}.
    event AppealContribution(uint256 indexed _localDisputeID, uint256 _round, uint256 indexed _ruling, address indexed _contributor, uint256 _amount);

    /// @dev See {https://github.com/kleros/arbitrable-contract-libraries/blob/main/contracts/interfaces/IAppealEvents.sol}.
    event Withdrawal(uint256 indexed _localDisputeID, uint256 indexed _round, uint256 _ruling, address indexed _contributor, uint256 _reward);

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
        require(
            self.arbitrator == IArbitrator(0x0) && _arbitrator != IArbitrator(0x0), 
            "Arbitrator is set or is invalid."
        );
        self.arbitrator = _arbitrator;
        self.arbitratorExtraData = _arbitratorExtraData;
    }

    /** @dev Invokes the arbitrator to create a dispute. Requires _arbitrationCost ETH. It's the arbitrable contract responsability to make sure the amount of ETH available in the contract is enough.
     *  @param _localDisputeID The dispute ID as defined in the arbitrable contract.
     *  @param _arbitrationCost Value in wei, as defined in getArbitrationCost(), that is needed to create a dispute. 
     *  @param _metaEvidenceID The ID of the meta-evidence of the dispute as defined in the ERC-1497 standard.
     *  @param _evidenceGroupID The ID of the evidence group the evidence belongs to.
     *  @return disputeID The ID assigned by the arbitrator to the newly created dispute.
     */
    function createDispute(
        ArbitrableStorage storage self, 
        uint256 _localDisputeID,
        uint256 _arbitrationCost,
        uint256 _metaEvidenceID,
        uint256 _evidenceGroupID
    ) internal returns(uint256 disputeID) {
        DisputeData storage dispute = self.disputes[_localDisputeID];
        require(dispute.status == Status.None, "Dispute already created.");
        
        disputeID = self.arbitrator.createDispute{value: _arbitrationCost}(MAX_NO_OF_CHOICES, self.arbitratorExtraData);
        
        dispute.disputeIDOnArbitratorSide = disputeID;
        dispute.status = Status.Disputed;
        dispute.roundCounter = 1;
        
        self.externalIDtoLocalID[disputeID] = _localDisputeID;

        emit Dispute(self.arbitrator, disputeID, _metaEvidenceID, _evidenceGroupID);
    }

    /** @dev Submits a reference to evidence. EVENT.
     *  @param _localDisputeID The dispute ID as defined in the arbitrable contract.
     *  @param _evidenceGroupID ID of the evidence group the evidence belongs to. It must match the one used in createDispute().
     *  @param _evidence A link to evidence using its URI.
     */
    function submitEvidence(
        ArbitrableStorage storage self, 
        uint256 _localDisputeID,
        uint256 _evidenceGroupID,
        string memory _evidence
    ) internal {
        require(
            self.disputes[_localDisputeID].status < Status.Resolved,
            "The dispute is resolved."
        );

        if (bytes(_evidence).length > 0)
            emit Evidence(self.arbitrator, _evidenceGroupID, msg.sender, _evidence);
    }

    /** @dev Takes up to the total amount required to fund a side of an appeal. Reimburses the rest. Creates an appeal if two sides are fully funded.
     *  @param _localDisputeID The dispute ID as defined in the arbitrable contract.
     *  @param _ruling The ruling to which the contribution is made.
     */
    function fundAppeal(ArbitrableStorage storage self, uint256 _localDisputeID, uint256 _ruling) internal {
        DisputeData storage dispute = self.disputes[_localDisputeID];
        require(dispute.status == Status.Disputed, "No ongoing dispute to appeal.");
        
        uint256 currentRound = uint256(dispute.roundCounter - 1);
        Round storage round = dispute.rounds[currentRound];
        uint256 rulingFunded = round.rulingFunded; // Use local variable for gas saving purposes.
        require(
            _ruling != rulingFunded && _ruling != 0, 
            "Ruling is funded or is invalid."
        );

        (uint256 appealCost, uint256 totalCost) = getAppealFeeComponents(self, _localDisputeID, _ruling);

        uint256 paidFee = round.paidFees[_ruling]; // Use local variable for gas saving purposes.
        // Take up to the amount necessary to fund the current round at the current costs.
        (uint256 contribution, uint256 remainingETH) = calculateContribution(msg.value, totalCost.subCap(paidFee));
        round.contributions[msg.sender][_ruling] += contribution;
        paidFee += contribution;
        round.paidFees[_ruling] = paidFee;
        round.totalFees += contribution; // Contributors to rulings that don't get fully funded can still win/lose rewards/contributions.
        emit AppealContribution(_localDisputeID, currentRound, _ruling, msg.sender, contribution);

        // Reimburse leftover ETH if any.
        if (remainingETH > 0)
            msg.sender.send(remainingETH); // Deliberate use of send in order not to block the contract in case of reverting fallback.
        
        if (paidFee >= totalCost) {
            emit HasPaidAppealFee(_localDisputeID, currentRound, _ruling);
            if (rulingFunded == 0) {
                round.rulingFunded = _ruling;
            } else {
                // Two rulings are fully funded. Create an appeal.
                self.arbitrator.appeal{value: appealCost}(dispute.disputeIDOnArbitratorSide, self.arbitratorExtraData);
                round.appealCost = appealCost;
                round.rulingFunded = 0; // clear storage
                dispute.roundCounter = uint248(currentRound + 2); // currentRound starts at 0 while roundCounter at 1.
            }
        }
    }

    /** @dev Validates and registers the ruling for a dispute. Can only be called by the arbitrator.
     *  The purpose of this function is to ensure that the address calling it has the right to rule on the contract. The ruling is inverted if a ruling loses from lack of appeal fees funding.
     *  @param _disputeIDOnArbitratorSide ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refuse to arbitrate".
     */
    function processRuling(
        ArbitrableStorage storage self, 
        uint256 _disputeIDOnArbitratorSide, 
        uint256 _ruling
    ) internal returns(uint256 finalRuling) {
        uint256 localDisputeID = self.externalIDtoLocalID[_disputeIDOnArbitratorSide];
        DisputeData storage dispute = self.disputes[localDisputeID];
        IArbitrator arbitrator = self.arbitrator;

        require(
            dispute.status == Status.Disputed &&
            msg.sender == address(arbitrator), 
            "Ruling can't be processed."
        );

        Round storage round = dispute.rounds[dispute.roundCounter - 1];

        // If only one ruling was fully funded, we consider it the winner, regardless of the arbitrator's decision.
        if (round.rulingFunded == 0)
            finalRuling = _ruling;
        else
            finalRuling = round.rulingFunded;

        dispute.status = Status.Resolved;
        dispute.ruling = finalRuling;

        emit Ruling(arbitrator, _disputeIDOnArbitratorSide, finalRuling);
    }

    /** @dev Withdraws contributions of appeal rounds. Reimburses contributions if the appeal was not fully funded. 
     *  If the appeal was fully funded, sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute.
     *  @param _localDisputeID The dispute ID as defined in the arbitrable contract.
     *  @param _beneficiary The address that made contributions.
     *  @param _round The round from which to withdraw.
     *  @param _ruling The ruling to which the contributions were made.
     */
    function withdrawFeesAndRewards(
        ArbitrableStorage storage self, 
        uint256 _localDisputeID, 
        address payable _beneficiary, 
        uint256 _round,
        uint256 _ruling
    ) internal {
        DisputeData storage dispute = self.disputes[_localDisputeID];
        require(dispute.status == Status.Resolved, "Dispute not resolved.");
        uint256 reward = getWithdrawableAmount(self, _localDisputeID, _beneficiary, _round, _ruling);

        if (reward > 0) {
            dispute.rounds[_round].contributions[_beneficiary][_ruling] = 0;
            emit Withdrawal(_localDisputeID, _round, _ruling, _beneficiary, reward);
            _beneficiary.send(reward); // It is the user responsibility to accept ETH.
        }
    }
    
    /** @dev Withdraws contributions of multiple appeal rounds at once. This function is O(n) where n is the number of rounds. 
     *  This could exceed the gas limit, therefore this function should be used only as a utility and not be relied upon by other contracts.
     *  @param _localDisputeID The dispute ID as defined in the arbitrable contract.
     *  @param _beneficiary The address that made the contributions.
     *  @param _cursor The round from where to start withdrawing.
     *  @param _count The number of rounds to iterate. If set to 0 or a value larger than the number of rounds, iterates until the last round.
     *  @param _ruling The ruling to which the contributions were made.
     */
    function batchWithdrawFeesAndRewards(
        ArbitrableStorage storage self, 
        uint256 _localDisputeID, 
        address payable _beneficiary, 
        uint256 _cursor, 
        uint256 _count,
        uint256 _ruling 
    ) internal {
        DisputeData storage dispute = self.disputes[_localDisputeID];
        require(dispute.status == Status.Resolved, "Dispute not resolved.");

        uint256 maxRound = _cursor + _count > dispute.roundCounter ? dispute.roundCounter : _cursor + _count;
        uint256 reward;
        for (uint256 i = _cursor; i < maxRound; i++) {
            uint256 roundReward = getWithdrawableAmount(self, _localDisputeID, _beneficiary, i, _ruling);
            reward += roundReward;

            if (roundReward > 0) {
                dispute.rounds[i].contributions[_beneficiary][_ruling] = 0;
                emit Withdrawal(_localDisputeID, i, _ruling, _beneficiary, roundReward);
            }
        }
            
        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }

    // ******************** //
    // *      Getters     * //
    // ******************** //

    /** @dev Gets the rewards withdrawable for a given round and ruling. 
     *  Beware that withdrawals are allowed only after the dispute gets Resolved. 
     *  @param _localDisputeID The dispute ID as defined in the arbitrable contract.
     *  @param _beneficiary The address that made the contributions.
     *  @param _round The round from which to withdraw.
     *  @param _ruling The ruling to which the contributions were made.
     *  @return reward The reward value to which the _beneficiary is entitled.
     */
    function getWithdrawableAmount(
        ArbitrableStorage storage self, 
        uint256 _localDisputeID, 
        address _beneficiary, 
        uint256 _round, 
        uint256 _ruling
    ) internal view returns(uint256 reward) {
        DisputeData storage dispute = self.disputes[_localDisputeID];
        Round storage round = dispute.rounds[_round];
        uint256 lastRound = dispute.roundCounter - 1;
        uint256 finalRuling = dispute.ruling;
        mapping(uint256 => uint256) storage contributionTo = round.contributions[_beneficiary];

        if (_round == lastRound) {
            // Allow to reimburse if funding was unsuccessful, i.e. appeal wasn't created.
            reward = contributionTo[_ruling];
        } else if (round.paidFees[finalRuling] > 0) {
            // If there is a winner, reward the winner.
            if (_ruling == finalRuling) {
                uint256 feeRewards = round.totalFees - round.appealCost;
                reward = (contributionTo[_ruling] * feeRewards) / round.paidFees[_ruling];
            }
        } else {
            // There is no winner. Reimburse unspent fees proportionally.
            uint256 feeRewards = round.totalFees - round.appealCost;
            reward = round.totalFees > 0 ? (contributionTo[_ruling] * feeRewards) / round.totalFees : 0;
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
     *  @param _localDisputeID The dispute ID as defined in the arbitrable contract.
     *  @param _ruling The ruling to which the contribution is made.
     *  @return appealCost The appeal fee charged by the arbitrator.  @return totalCost The total cost for appealing.
    */
    function getAppealFeeComponents(
        ArbitrableStorage storage self,
        uint256 _localDisputeID,
        uint256 _ruling
    ) internal view returns (uint256 appealCost, uint256 totalCost) {
        DisputeData storage dispute = self.disputes[_localDisputeID];
        IArbitrator arbitrator = self.arbitrator;
        uint256 disputeIDOnArbitratorSide = dispute.disputeIDOnArbitratorSide;

        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = arbitrator.appealPeriod(disputeIDOnArbitratorSide);
        require(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd, "Not in appeal period.");

        uint256 multiplier;
        uint256 winner = arbitrator.currentRuling(disputeIDOnArbitratorSide);
        if (winner == _ruling){
            multiplier = self.winnerStakeMultiplier;
        } else if (winner == 0){
            multiplier = self.sharedStakeMultiplier;
        } else {
            require(block.timestamp < (appealPeriodEnd + appealPeriodStart)/2, "Not in loser's appeal period.");
            multiplier = self.loserStakeMultiplier;
        }

        appealCost = arbitrator.appealCost(disputeIDOnArbitratorSide, self.arbitratorExtraData);
        totalCost = appealCost.addCap(appealCost.mulCap(multiplier) / MULTIPLIER_DIVISOR);
    }

    /** @dev Gets the final ruling if the dispute is resolved.
     *  @param _localDisputeID The dispute ID as defined in the arbitrable contract.
     *  @return The ruling that won the dispute.
     */
    function getFinalRuling(ArbitrableStorage storage self, uint256 _localDisputeID) internal view returns(uint256) {
        DisputeData storage dispute = self.disputes[_localDisputeID];
        require(dispute.status == Status.Resolved, "Arbitrator has not ruled yet.");
        return dispute.ruling;
    }

    /** @dev Gets the cost of arbitration using the given arbitrator and arbitratorExtraData.
     *  @return Arbitration cost.
     */
    function getArbitrationCost(ArbitrableStorage storage self) internal view returns(uint256) {
        return self.arbitrator.arbitrationCost(self.arbitratorExtraData);
    }

    /** @dev Gets the number of rounds of the specific dispute.
     *  @param _localDisputeID The dispute ID as defined in the arbitrable contract.
     *  @return The number of rounds.
     */
    function getNumberOfRounds(ArbitrableStorage storage self, uint256 _localDisputeID) internal view returns (uint256) {
        return self.disputes[_localDisputeID].roundCounter;
    }

    /** @dev Gets the information on a round of a disputed dispute.
     *  @param _localDisputeID The dispute ID as defined in the arbitrable contract.
     *  @param _round The round to be queried.
     *  @return rulingFunded feeRewards appealCostPaid appealed The round information.
     */
    function getRoundInfo(
        ArbitrableStorage storage self, 
        uint256 _localDisputeID, 
        uint256 _round
    ) internal view returns(
        uint256 rulingFunded,
        uint256 feeRewards,
        uint256 appealCostPaid,
        bool appealed
    ) {
        DisputeData storage dispute = self.disputes[_localDisputeID];
        Round storage round = dispute.rounds[_round];

        rulingFunded = round.rulingFunded;
        feeRewards = round.totalFees - round.appealCost;
        appealCostPaid = round.appealCost;
        appealed = _round != dispute.roundCounter - 1;
    }

    /** @dev Gets the contribution to a ruling made by an address for a given round of appeal of a dispute.
     *  @param _localDisputeID The dispute ID as defined in the arbitrable contract.
     *  @param _round The round number.
     *  @param _contributor The address of the contributor.
     *  @param _ruling The address of the contributor.
     *  @return contribution made by _contributor.
     *  @return rulingContributions sum of all contributions to _ruling.
     */
    function getContribution(
        ArbitrableStorage storage self, 
        uint256 _localDisputeID, 
        uint256 _round,
        address _contributor,
        uint256 _ruling
    ) internal view returns(uint256 contribution, uint256 rulingContributions) {
        DisputeData storage dispute = self.disputes[_localDisputeID];
        Round storage round = dispute.rounds[_round];
        contribution = round.contributions[_contributor][_ruling];
        rulingContributions = round.paidFees[_ruling];
    }
}