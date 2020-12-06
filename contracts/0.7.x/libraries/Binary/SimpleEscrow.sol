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

    address payable public payer = msg.sender;
    address payable public payee;
    uint256 public value;
    string public agreement;
    uint256 public createdAt;
    uint256 public constant reclamationPeriod = 3 minutes;
    uint256 public constant arbitrationFeeDepositPeriod = 3 minutes;

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

        emit MetaEvidence(META_EVIDENCE_ID, _agreement); // Agreement = MetaEvidence. It has information such as what ruling must the arbitrator give in order to make the payer or the payee the winner (in this case 1 and 2, respectively).
    }

    function releaseFunds() public {
        require(status == Status.Initial, "Transaction is not in Initial state.");

        if (msg.sender != payer)
            require(block.timestamp - createdAt > reclamationPeriod, "Payer still has time to reclaim.");

        status = Status.Resolved;
        payee.send(value);
    }

    function reclaimFunds() public payable {
        BinaryArbitrable.Status disputeStatus = arbitrableStorage.items[TX_ID].status;
        require(disputeStatus == BinaryArbitrable.Status.Undisputed, "Dispute has already been created.");
        require(status != Status.Resolved, "Transaction is already resolved.");
        require(msg.sender == payer, "Only the payer can reclaim the funds.");

        if (status == Status.Reclaimed) {
            require(
                block.timestamp - reclaimedAt > arbitrationFeeDepositPeriod,
                "Payee still has time to deposit arbitration fee."
            );
            payer.send(address(this).balance);
            status = Status.Resolved;
        } else {
            require(block.timestamp - createdAt <= reclamationPeriod, "Reclamation period ended.");

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

    function rule(uint256 _disputeID, uint256 _ruling) public override {
        BinaryArbitrable.Party _finalRuling = arbitrableStorage.processRuling(_disputeID, _ruling);

        if (_finalRuling == BinaryArbitrable.Party.Requester) payer.send(address(this).balance);
        else if (_finalRuling == BinaryArbitrable.Party.Respondent) payee.send(address(this).balance);

        status = Status.Resolved;
    }

    function remainingTimeToReclaim() public view returns (uint256) {
        require(status == Status.Initial, "Transaction is not in Initial state.");
        return
            (block.timestamp - createdAt) > reclamationPeriod
                ? 0
                : (createdAt + reclamationPeriod - block.timestamp);
    }

    function remainingTimeToDepositArbitrationFee() public view returns (uint256) {
        require(status == Status.Reclaimed, "Transaction is not in Reclaimed state.");
        BinaryArbitrable.Status disputeStatus = arbitrableStorage.items[TX_ID].status;
        require(disputeStatus == BinaryArbitrable.Status.Undisputed, "Dispute has already been created.");

        return
            (block.timestamp - reclaimedAt) > arbitrationFeeDepositPeriod
                ? 0
                : (reclaimedAt + arbitrationFeeDepositPeriod - block.timestamp);
    }
}