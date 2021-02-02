/**
 *  @authors: [@fnanni-0]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 */

pragma solidity >=0.7;
pragma experimental ABIEncoderV2;

import "./BinaryUpgradableArbitrable.sol";
import "../.././interfaces/IAppealEvents.sol";
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

contract MockEscrowUpgradable is IArbitrable, IEvidence, IAppealEvents {
    
    using CappedMath for uint256;
    using BinaryUpgradableArbitrable for BinaryUpgradableArbitrable.ArbitrableStorage;

    // **************************** //
    // *    Contract variables    * //
    // **************************** //

    enum Party {None, Sender, Receiver}
    enum Status {Ongoing, WaitingSenderFee, WaitingReceiverFee, Resolved}
    enum Resolution {TransactionExecuted, TimeoutBySender, TimeoutByReceiver, RulingEnforced}

    struct Transaction {
        address payable sender;
        address payable receiver;
        uint256 amount;
        uint256 deadline; // Timestamp at which the transaction can be automatically executed if not disputed.
        uint256 senderFee; // Total fees paid by the sender.
        uint256 receiverFee; // Total fees paid by the receiver.
        uint256 lastInteraction; // Last interaction for the dispute procedure.
        Status status;
    }

    uint256 public immutable feeTimeout; // Time in seconds a party can take to pay arbitration fees before being considered unresponsive and lose the dispute.
    
    /// @dev Stores the hashes of all transactions.
    bytes32[] public transactionHashes;

    /// @dev Contains most of the data related to arbitration.
    BinaryUpgradableArbitrable.ArbitrableStorage public arbitrableStorage;

    // **************************** //
    // *          Events          * //
    // **************************** //

    /**
     * @dev To be emitted whenever a transaction state is updated.
     * @param _transactionID The ID of the changed transaction.
     * @param _transaction The full transaction data after update.
     */
    event TransactionStateUpdated(uint256 indexed _transactionID, Transaction _transaction);

    /** @dev To be emitted when a party pays or reimburses the other.
     *  @param _transactionID The index of the transaction.
     *  @param _amount The amount paid.
     *  @param _party The party that paid.
     */
    event Payment(uint256 indexed _transactionID, uint256 _amount, address _party);

    /** @dev Indicate that a party has to pay a fee or would otherwise be considered as losing.
     *  @param _transactionID The index of the transaction.
     *  @param _party The party who has to pay.
     */
    event HasToPayFee(uint256 indexed _transactionID, Party _party);

    /** @dev Emitted when a transaction is created.
     *  @param _transactionID The index of the transaction.
     *  @param _sender The address of the sender.
     *  @param _receiver The address of the receiver.
     *  @param _amount The initial amount in the transaction.
     */
    event TransactionCreated(uint256 indexed _transactionID, address indexed _sender, address indexed _receiver, uint256 _amount);

    /** @dev To be emitted when a transaction is resolved, either by its execution, a timeout or because a ruling was enforced.
     *  @param _transactionID The ID of the respective transaction.
     *  @param _resolution Short description of what caused the transaction to be solved.
     */
    event TransactionResolved(uint256 indexed _transactionID, Resolution indexed _resolution);

    // **************************** //
    // *    Arbitrable functions  * //
    // *    Modifying the state   * //
    // **************************** //

    /** @dev Constructor.
     *  @param _arbitrator The arbitrator of the contract.
     *  @param _arbitratorExtraData Extra data for the arbitrator.
     *  @param _feeTimeout Arbitration fee timeout for the parties.
     *  @param _sharedStakeMultiplier Multiplier of the appeal cost that the submitter must pay for a round when there is no winner/loser in the previous round. In basis points.
     *  @param _winnerStakeMultiplier Multiplier of the appeal cost that the winner has to pay for a round. In basis points.
     *  @param _loserStakeMultiplier Multiplier of the appeal cost that the loser has to pay for a round. In basis points.
     */
    constructor (
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        uint256 _feeTimeout,
        uint256 _sharedStakeMultiplier,
        uint256 _winnerStakeMultiplier,
        uint256 _loserStakeMultiplier
    ) {
        feeTimeout = _feeTimeout;
        arbitrableStorage.setMultipliers(_sharedStakeMultiplier, _winnerStakeMultiplier, _loserStakeMultiplier);
        arbitrableStorage.setArbitrator(_arbitrator, _arbitratorExtraData);
    }

    modifier onlyValidTransaction(uint256 _transactionID, Transaction memory _transaction) {
        require(
            transactionHashes[_transactionID - 1] == hashTransactionState(_transaction), 
            "Transaction doesn't match stored hash."
            );
        _;
    }

    function changeArbitrator(IArbitrator _arbitrator, bytes memory _arbitratorExtraData) external {
        arbitrableStorage.setArbitrator(_arbitrator, _arbitratorExtraData);
    }

    /** @dev Create a transaction.
     *  @param _timeoutPayment Time after which a party can automatically execute the arbitrable transaction.
     *  @param _receiver The recipient of the transaction.
     *  @param _metaEvidence Link to the meta-evidence.
     *  @return transactionID The index of the transaction.
     */
    function createTransaction(
        uint256 _timeoutPayment,
        address payable _receiver,
        string calldata _metaEvidence
    ) public payable returns (uint256 transactionID) {
        
        Transaction memory transaction;
        transaction.sender = msg.sender;
        transaction.receiver = _receiver;
        transaction.amount = msg.value;
        transaction.deadline = block.timestamp + _timeoutPayment;
        transaction.lastInteraction = block.timestamp;
        transaction.status = Status.Ongoing; // Redundant code. This line is only for clarity.

        transactionHashes.push(hashTransactionState(transaction));
        transactionID = transactionHashes.length; // transactionID starts at 1. This way, TransactionDispute can check if a dispute exists by testing transactionID != 0.

        emit MetaEvidence(transactionID, _metaEvidence);
        emit TransactionCreated(transactionID, msg.sender, _receiver, msg.value);
        emit TransactionStateUpdated(transactionID, transaction);
    }

    /** @dev Pay receiver. To be called if the good or service is provided.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _amount Amount to pay in wei.
     */
    function pay(uint256 _transactionID, Transaction memory _transaction, uint256 _amount) public onlyValidTransaction(_transactionID, _transaction) {
        require(_transaction.sender == msg.sender, "The caller must be the sender.");
        require(!arbitrableStorage.disputeExists(_transactionID), "Dispute has already been created.");
        require(_transaction.status == Status.Ongoing, "The transaction must not be disputed/executed.");
        require(_amount <= _transaction.amount, "Maximum amount available for payment exceeded.");

        _transaction.receiver.send(_amount);
        _transaction.amount -= _amount;
        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction); // solhint-disable-line

        emit Payment(_transactionID, _amount, msg.sender);
        emit TransactionStateUpdated(_transactionID, _transaction);
    }

    /** @dev Reimburse sender. To be called if the good or service can't be fully provided.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _amountReimbursed Amount to reimburse in wei.
     */
    function reimburse(uint256 _transactionID, Transaction memory _transaction, uint256 _amountReimbursed) public onlyValidTransaction(_transactionID, _transaction) {
        require(_transaction.receiver == msg.sender, "The caller must be the receiver.");
        require(!arbitrableStorage.disputeExists(_transactionID), "Dispute has already been created.");
        require(_transaction.status == Status.Ongoing, "The transaction must not be disputed/executed.");
        require(_amountReimbursed <= _transaction.amount, "Maximum reimbursement available exceeded.");

        _transaction.sender.send(_amountReimbursed);
        _transaction.amount -= _amountReimbursed;
        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction); // solhint-disable-line

        emit Payment(_transactionID, _amountReimbursed, msg.sender);
        emit TransactionStateUpdated(_transactionID, _transaction);
    }

    /** @dev Transfer the transaction's amount to the receiver if the timeout has passed.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function executeTransaction(uint256 _transactionID, Transaction memory _transaction) public onlyValidTransaction(_transactionID, _transaction) {
        require(block.timestamp >= _transaction.deadline, "Deadline not passed.");
        require(!arbitrableStorage.disputeExists(_transactionID), "Dispute has already been created.");
        require(_transaction.status == Status.Ongoing, "The transaction must not be disputed/executed.");

        _transaction.receiver.send(_transaction.amount);
        _transaction.amount = 0;

        _transaction.status = Status.Resolved;

        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction); // solhint-disable-line
        emit TransactionStateUpdated(_transactionID, _transaction);
        emit TransactionResolved(_transactionID, Resolution.TransactionExecuted);
    }

    /** @dev Pay the arbitration fee to raise a dispute. To be called by the sender. UNTRUSTED.
     *  Note that the arbitrator can have createDispute throw, which will make this function throw and therefore lead to a party being timed-out.
     *  This is not a vulnerability as the arbitrator can rule in favor of one party anyway.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function payArbitrationFeeBySender(uint256 _transactionID, Transaction memory _transaction) public payable onlyValidTransaction(_transactionID, _transaction) {
        require(!arbitrableStorage.disputeExists(_transactionID), "Dispute has already been created.");
        require(_transaction.status < Status.Resolved, "The transaction must not be executed.");
        require(msg.sender == _transaction.sender, "The caller must be the sender.");

        uint256 arbitrationCost = arbitrableStorage.getArbitrationCost(_transactionID);
        _transaction.senderFee += msg.value;
        // Require that the total pay at least the arbitration cost.
        require(_transaction.senderFee >= arbitrationCost, "The sender fee must cover arbitration costs.");

        _transaction.lastInteraction = block.timestamp;

        // The receiver still has to pay. This can also happen if he has paid, but arbitrationCost has increased.
        if (_transaction.receiverFee < arbitrationCost) {
            _transaction.status = Status.WaitingReceiverFee;
            emit HasToPayFee(_transactionID, Party.Receiver);
        } else { // The receiver has also paid the fee. We create the dispute.
            raiseDispute(_transactionID, _transaction, arbitrationCost);
        }

        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);
        emit TransactionStateUpdated(_transactionID, _transaction);
    }

    /** @dev Pay the arbitration fee to raise a dispute. To be called by the receiver. UNTRUSTED.
     *  Note that this function mirrors payArbitrationFeeBySender.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function payArbitrationFeeByReceiver(uint256 _transactionID, Transaction memory _transaction) public payable onlyValidTransaction(_transactionID, _transaction) {
        require(!arbitrableStorage.disputeExists(_transactionID), "Dispute has already been created.");
        require(_transaction.status < Status.Resolved, "The transaction must not be executed.");
        require(msg.sender == _transaction.receiver, "The caller must be the receiver.");
        
        uint256 arbitrationCost = arbitrableStorage.getArbitrationCost(_transactionID);
        _transaction.receiverFee += msg.value;
        // Require that the total paid to be at least the arbitration cost.
        require(_transaction.receiverFee >= arbitrationCost, "The receiver fee must cover arbitration costs.");

        _transaction.lastInteraction = block.timestamp;
        // The sender still has to pay. This can also happen if he has paid, but arbitrationCost has increased.
        if (_transaction.senderFee < arbitrationCost) {
            _transaction.status = Status.WaitingSenderFee;
            emit HasToPayFee(_transactionID, Party.Sender);
        } else { // The sender has also paid the fee. We create the dispute.
            raiseDispute(_transactionID, _transaction, arbitrationCost);
        }

        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);
        emit TransactionStateUpdated(_transactionID, _transaction);
    }

    /** @dev Reimburse sender if receiver fails to pay the fee.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function timeOutBySender(uint256 _transactionID, Transaction memory _transaction) public onlyValidTransaction(_transactionID, _transaction) {
        require(_transaction.status == Status.WaitingReceiverFee, "The transaction is not waiting on the receiver.");
        require(block.timestamp - _transaction.lastInteraction >= feeTimeout, "Timeout has not passed yet.");

        if (_transaction.receiverFee != 0) {
            _transaction.receiver.send(_transaction.receiverFee);
            _transaction.receiverFee = 0;
        }

        _transaction.sender.send(_transaction.senderFee + _transaction.amount);
        _transaction.amount = 0;
        _transaction.senderFee = 0;
        _transaction.status = Status.Resolved;

        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction); // solhint-disable-line
        emit TransactionStateUpdated(_transactionID, _transaction);
        emit TransactionResolved(_transactionID, Resolution.TimeoutBySender);
    }

    /** @dev Pay receiver if sender fails to pay the fee.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function timeOutByReceiver(uint256 _transactionID, Transaction memory _transaction) public onlyValidTransaction(_transactionID, _transaction) {
        require(_transaction.status == Status.WaitingSenderFee, "The transaction is not waiting on the sender.");
        require(block.timestamp - _transaction.lastInteraction >= feeTimeout, "Timeout has not passed yet.");

        if (_transaction.senderFee != 0) {
            _transaction.sender.send(_transaction.senderFee);
            _transaction.senderFee = 0;
        }

        _transaction.receiver.send(_transaction.receiverFee + _transaction.amount);
        _transaction.amount = 0;
        _transaction.receiverFee = 0;
        _transaction.status = Status.Resolved;

        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction); // solhint-disable-line
        emit TransactionStateUpdated(_transactionID, _transaction);
        emit TransactionResolved(_transactionID, Resolution.TimeoutByReceiver);
    }

    /** @dev Create a dispute. UNTRUSTED.
     *  This function is internal and thus the transaction state validity is not checked. Caller functions MUST do the check before calling this function.
     *  _transaction MUST be a reference (not a copy) because its state is modified. Caller functions MUST emit the TransactionStateUpdated event and update the hash.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _arbitrationCost Amount to pay the arbitrator.
     */
    function raiseDispute(uint256 _transactionID, Transaction memory _transaction, uint256 _arbitrationCost) internal {
        arbitrableStorage.createDispute(
            _transactionID,
            _arbitrationCost,
            _transactionID,
            _transactionID
        );

        _transaction.status = Status.Ongoing;

        // Refund sender if it overpaid.
        if (_transaction.senderFee > _arbitrationCost) {
            uint256 extraFeeSender = _transaction.senderFee - _arbitrationCost;
            _transaction.senderFee = _arbitrationCost;
            _transaction.sender.send(extraFeeSender);
        }

        // Refund receiver if it overpaid.
        if (_transaction.receiverFee > _arbitrationCost) {
            uint256 extraFeeReceiver = _transaction.receiverFee - _arbitrationCost;
            _transaction.receiverFee = _arbitrationCost;
            _transaction.receiver.send(extraFeeReceiver);
        }
    }

    /** @dev Submit a reference to evidence. EVENT.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _evidence A link to an evidence using its URI.
     */
    function submitEvidence(uint256 _transactionID, Transaction calldata _transaction, string calldata _evidence) public onlyValidTransaction(_transactionID, _transaction) {
        require(
            msg.sender == _transaction.sender || msg.sender == _transaction.receiver,
            "The caller must be the sender or the receiver."
        );
        arbitrableStorage.submitEvidence(_transactionID, _transactionID, _evidence);
    }

    /** @dev Takes up to the total amount required to fund a party of an appeal. Reimburses the rest. Creates an appeal if both parties are fully funded.
     *  @param _transactionID The ID of the disputed transaction.
     *  @param _transaction The transaction state.
     *  @param _ruling The party that pays the appeal fee.
     */
    function fundAppeal(uint256 _transactionID, Transaction calldata _transaction, uint256 _ruling) external payable onlyValidTransaction(_transactionID, _transaction) {
        arbitrableStorage.fundAppeal(_transactionID, _ruling);
    } 
    
    /** @dev Witdraws contributions of appeal rounds. Reimburses contributions if the appeal was not fully funded. 
     *  If the appeal was fully funded, sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute.
     *  @param _beneficiary The address that made contributions.
     *  @param _transactionID The ID of the associated transaction.
     *  @param _transaction The transaction state.
     *  @param _round The round from which to withdraw.
     */
    function withdrawFeesAndRewards(
        address payable _beneficiary, 
        uint256 _transactionID, 
        Transaction calldata _transaction, 
        uint256 _round
    ) public onlyValidTransaction(_transactionID, _transaction) {
        arbitrableStorage.withdrawFeesAndRewards(_transactionID, _beneficiary, _round);
    }
    
    /** @dev Withdraws contributions of multiple appeal rounds at once. This function is O(n) where n is the number of rounds. 
     *  This could exceed the gas limit, therefore this function should be used only as a utility and not be relied upon by other contracts.
     *  @param _beneficiary The address that made contributions.
     *  @param _transactionID The ID of the associated transaction.
     *  @param _transaction The transaction state.
     *  @param _cursor The round from where to start withdrawing.
     *  @param _count The number of rounds to iterate. If set to 0 or a value larger than the number of rounds, iterates until the last round.
     */
    function batchWithdrawFeesAndRewards(
        address payable _beneficiary, 
        uint256 _transactionID, 
        Transaction calldata _transaction, 
        uint256 _cursor, 
        uint256 _count
    ) public onlyValidTransaction(_transactionID, _transaction) {
        arbitrableStorage.batchWithdrawFeesAndRewards(_transactionID, _beneficiary, _cursor, _count);
    }

    /** @dev Give a ruling for a dispute. Must be called by the arbitrator to enforce the final ruling.
     *  The purpose of this function is to ensure that the address calling it has the right to rule on the contract.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Not able/wanting to make a decision".
     */
    function rule(uint256 _disputeID, uint256 _ruling) public override {
        arbitrableStorage.processRuling(_disputeID, _ruling);
    }
    
    /** @dev Execute a ruling of a dispute. It reimburses the fee to the winning party.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function executeRuling(uint256 _transactionID, Transaction memory _transaction) public onlyValidTransaction(_transactionID, _transaction) {

        Party ruling = Party(arbitrableStorage.getFinalRuling(_transactionID));

        // Give the arbitration fee back.
        // Note that we use send to prevent a party from blocking the execution.
        if (ruling == Party.Sender) {
            _transaction.sender.send(_transaction.senderFee + _transaction.amount);
        } else if (ruling == Party.Receiver) {
            _transaction.receiver.send(_transaction.receiverFee + _transaction.amount);
        } else {
            uint256 splitAmount = (_transaction.senderFee + _transaction.amount) / 2;
            _transaction.sender.send(splitAmount);
            _transaction.receiver.send(splitAmount);
        }

        _transaction.amount = 0;
        _transaction.senderFee = 0;
        _transaction.receiverFee = 0;
        _transaction.status = Status.Resolved;

        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction); // solhint-disable-line
        emit TransactionStateUpdated(_transactionID, _transaction);
        emit TransactionResolved(_transactionID, Resolution.RulingEnforced);
    }

    // **************************** //
    // *     Constant getters     * //
    // **************************** //
    
    /** @dev Returns the sum of withdrawable wei from appeal rounds. 
     *  This function is O(n), where n is the number of rounds of the task. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  Beware that withdrawals are allowed only after the dispute gets Resolved. 
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _beneficiary The contributor for which to query.
     *  @return total The total amount of wei available to withdraw.
     */
    function getTotalWithdrawableAmount(
        uint256 _transactionID, 
        Transaction calldata _transaction, 
        address _beneficiary
    ) public view onlyValidTransaction(_transactionID, _transaction) returns (uint256 total) {
        uint256 totalRounds = arbitrableStorage.disputes[_transactionID].roundCounter;
        for (uint256 roundI; roundI < totalRounds; roundI++) {
            (uint256 rewardA, uint256 rewardB) = arbitrableStorage.getWithdrawableAmount(_transactionID, _beneficiary, roundI);
            total += rewardA + rewardB;
        }
    }

    /** @dev Getter to know the count of transactions.
     *  @return The count of transactions.
     */
    function getCountTransactions() public view returns (uint256) {
        return transactionHashes.length;
    }

    /** @dev Gets the number of rounds of the specific transaction.
     *  @param _transactionID The ID of the transaction.
     *  @return The number of rounds.
     */
    function getNumberOfRounds(uint256 _transactionID) public view returns (uint256) {
        return arbitrableStorage.getNumberOfRounds(_transactionID);
    }

    /** @dev Gets the contributions made by a party for a given round of the appeal.
     *  @param _transactionID The ID of the transaction.
     *  @param _round The position of the round.
     *  @param _contributor The address of the contributor.
     *  @return contributions The contributions.
     */
    function getContributions(
        uint256 _transactionID,
        uint256 _round,
        address _contributor
    ) public view returns(uint256[3] memory contributions) {
        return arbitrableStorage.getContributions(_transactionID, _round, _contributor);
    }

    /** @dev Gets the information on a round of a transaction.
     *  @param _transactionID The ID of the transaction.
     *  @param _round The round to query.
     *  @return paidFees rulingFunded feeRewards appealed The round information.
     */
    function getRoundInfo(uint256 _transactionID, uint256 _round)
        public
        view
        returns (
            uint256[3] memory paidFees,
            uint256 rulingFunded,
            uint256 feeRewards,
            bool appealed
        )
    {
        return arbitrableStorage.getRoundInfo(_transactionID, _round);
    }

    /**
     * @dev Gets the hashed version of the transaction state.
     * If the caller function is using a Transaction object stored in calldata, this function is unnecessarily expensive, use hashTransactionStateCD instead.
     * @param _transaction The transaction state.
     * @return The hash of the transaction state.
     */
    function hashTransactionState(Transaction memory _transaction) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    _transaction.sender,
                    _transaction.receiver,
                    _transaction.amount,
                    _transaction.deadline,
                    _transaction.senderFee,
                    _transaction.receiverFee,
                    _transaction.lastInteraction,
                    _transaction.status
                )
            );
    }
}