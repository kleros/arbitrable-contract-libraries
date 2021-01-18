/**
 * @authors: [@fnanni-0]
 * @reviewers: []
 * @auditors: []
 * @bounties: []
 * @deployments: []
 * SPDX-License-Identifier: MIT
 */

pragma solidity >=0.7;

import "./BinaryArbitrable.sol";
import "../.././interfaces/IAppealEvents.sol";
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";

contract SimpleEscrow is IArbitrable, IEvidence, IAppealEvents {
    using BinaryArbitrable for BinaryArbitrable.ArbitrableStorage;

    BinaryArbitrable.ArbitrableStorage public arbitrableStorage; // Contains most of the data related to arbitration.
    uint256 public constant TX_ID = 0;
    uint256 public constant META_EVIDENCE_ID = 0;
    uint256 public constant RECLAMATION_PERIOD = 3 minutes;
    uint256 public constant ARBITRATION_FEE_DEPOSIT_PERIOD = 3 minutes;

    address payable public payer = msg.sender;
    address payable public payee;
    uint256 public value;
    string public agreement;
    uint256 public createdAt;

    enum RulingOptions {RefusedToArbitrate, PayerWins, PayeeWins}
    enum Status {Initial, Reclaimed, Resolved}
    Status public status;

    uint256 public reclaimedAt;

    constructor(
        address payable _payee,
        IArbitrator _arbitrator,
        string memory _agreement
    ) payable {
        value = msg.value;
        payee = _payee;
        agreement = _agreement;
        createdAt = block.timestamp;

        arbitrableStorage.setArbitrator(_arbitrator, "");
        arbitrableStorage.setMultipliers(0, 0, 0);

        emit MetaEvidence(META_EVIDENCE_ID, _agreement); // Agreement = MetaEvidence. It has information such as what ruling the arbitrator must give in order to make the payer or the payee the winner (in this case 1 and 2, respectively).
    }

    function releaseFunds() public {
        require(status == Status.Initial, "Transaction is not in Initial state.");

        if (msg.sender != payer)
            require(block.timestamp - createdAt > RECLAMATION_PERIOD, "Payer still has time to reclaim.");

        status = Status.Resolved;
        payee.send(value);
    }

    function reclaimFunds() public payable {
       require(!arbitrableStorage.disputeExists(TX_ID), "Dispute has already been created.");
        require(status != Status.Resolved, "Transaction is already resolved.");
        require(msg.sender == payer, "Only the payer can reclaim the funds.");

        if (status == Status.Reclaimed) {
            require(
                block.timestamp - reclaimedAt > ARBITRATION_FEE_DEPOSIT_PERIOD,
                "Payee still has time to deposit arbitration fee."
            );
            payer.send(address(this).balance);
            status = Status.Resolved;
        } else {
            require(block.timestamp - createdAt <= RECLAMATION_PERIOD, "Reclamation period ended.");

            uint256 arbitrationCost = arbitrableStorage.getArbitrationCost();
            require(
                msg.value == arbitrationCost,
                "Can't reclaim funds without depositing arbitration fee."
            );
            reclaimedAt = block.timestamp;
            status = Status.Reclaimed;
        }
    }

    function depositArbitrationFeeForPayee() public payable {
        require(status == Status.Reclaimed, "Transaction is not in Reclaimed state.");
        uint256 arbitrationCost = arbitrableStorage.getArbitrationCost();
        arbitrableStorage.createDispute(
            TX_ID,
            arbitrationCost,
            META_EVIDENCE_ID,
            TX_ID
        );
    }

    function submitEvidence(string calldata _evidence) external {
        require(msg.sender == payer || msg.sender == payee, "Invalid caller.");
        arbitrableStorage.submitEvidence(TX_ID, TX_ID, _evidence);
    }

    function fundAppeal(uint256 _ruling) external payable {
        arbitrableStorage.fundAppeal(TX_ID, _ruling);
    } 

    function rule(uint256 _disputeID, uint256 _ruling) public override {
        RulingOptions _finalRuling = RulingOptions(arbitrableStorage.processRuling(_disputeID, _ruling));

        if (_finalRuling == RulingOptions.PayerWins) payer.send(address(this).balance);
        else if (_finalRuling == RulingOptions.PayeeWins) payee.send(address(this).balance);

        status = Status.Resolved;
    }

    function withdrawFeesAndRewards(address payable _beneficiary, uint256 _round) external {
        arbitrableStorage.withdrawFeesAndRewards(TX_ID, _beneficiary, _round);
    }
    
    function batchWithdrawFeesAndRewards(address payable _beneficiary, uint256 _cursor, uint256 _count) external {
        arbitrableStorage.batchWithdrawFeesAndRewards(TX_ID, _beneficiary, _cursor, _count);
    }

    function remainingTimeToReclaim() public view returns (uint256) {
        require(status == Status.Initial, "Transaction is not in Initial state.");
        return
            (block.timestamp - createdAt) > RECLAMATION_PERIOD
                ? 0
                : (createdAt + RECLAMATION_PERIOD - block.timestamp);
    }

    function remainingTimeToDepositArbitrationFee() public view returns (uint256) {
        require(status == Status.Reclaimed, "Transaction is not in Reclaimed state.");
        require(!arbitrableStorage.disputeExists(TX_ID), "Dispute has already been created.");

        return
            (block.timestamp - reclaimedAt) > ARBITRATION_FEE_DEPOSIT_PERIOD
                ? 0
                : (reclaimedAt + ARBITRATION_FEE_DEPOSIT_PERIOD - block.timestamp);
    }

    // **************************** //
    // *         getters          * //
    // **************************** //

    function getRoundInfo(uint256 _round) external view returns (
            uint256[3] memory paidFees,
            uint256 rulingFunded,
            uint256 feeRewards,
            bool appealed
        ) {
        return arbitrableStorage.getRoundInfo(TX_ID, _round);
    }

    function getNumberOfRounds() external view returns (uint256) {
        return arbitrableStorage.getNumberOfRounds(TX_ID);
    }

    function getContributions(
        uint256 _round,
        address _contributor
    ) external view returns(uint256[3] memory contributions) {
        return arbitrableStorage.getContributions(TX_ID, _round, _contributor);
    }

    function getTotalWithdrawableAmount(address _beneficiary) external view returns (uint256 total) {
        uint256 totalRounds = arbitrableStorage.disputes[TX_ID].roundCounter;
        for (uint256 roundI; roundI < totalRounds; roundI++) {
            (uint256 rewardA, uint256 rewardB) = arbitrableStorage.getWithdrawableAmount(TX_ID, _beneficiary, roundI);
            total += rewardA + rewardB;
        }
    }
}