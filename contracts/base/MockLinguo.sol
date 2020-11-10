/**
 * @authors: []
 * @reviewers: []
 * @auditors: []
 * @bounties: []
 * @deployments: []
 *
 * SPDX-License-Identifier: MIT
 */
pragma solidity >=0.7;

import "./BinaryAppealable.sol";
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

/** @title Linguo
 *  @notice Linguo is a decentralized platform where anyone can submit a document for translation and have it translated by freelancers.
 *  It has no platform fees and disputes about translation quality are handled by Kleros jurors.
 *  @dev This contract trusts that the Arbitrator is honest and will not reenter or modify its costs during a call.
 *  The arbitrator must support appeal periods.
 */
contract Linguo is IArbitrable, IEvidence, BinaryAppealable {
    using CappedMath for uint256;

    /* *** Contract variables *** */
    uint8 public constant VERSION_ID = 0; // Value that represents the version of the contract. The value is incremented each time the new version is deployed. Range for LinguoETH: 0-127, LinguoToken: 128-255.
    uint256 private constant NOT_PAYABLE_VALUE = (2**256 - 2) / 2; // A value depositors won't be able to pay.

    enum Status {Created, Assigned, AwaitingReview, DisputeCreated, Resolved}

    enum Party {
        None, // Party that is mapped with a 0 dispute ruling.
        Translator, // Party performing translation task.
        Challenger // Party challenging translated text in the review period.
    }

    // Arrays of 3 elements in the Task and Round structs map to the parties. Index "0" is not used, "1" is used for the translator and "2" for the challenger.
    struct Task {
        uint256 submissionTimeout; // Time in seconds allotted for submitting a translation. The end of this period is considered a deadline.
        uint256 minPrice; // Minimum price for the translation. When the task is created it has this minimum price that gradually increases such that it reaches the maximum price at the deadline.
        uint256 maxPrice; // Maximum price for the translation and also the value that must be deposited by the requester.
        Status status; // Status of the task.
        uint256 lastInteraction; // The time of the last action performed on the task. Note that lastInteraction is updated only during timeout-related actions such as the creation of the task and the submission of the translation.
        address payable requester; // The party requesting the translation.
        uint256 requesterDeposit; // The deposit requester makes when creating the task. Once the task is assigned this deposit will be partially reimbursed and its value replaced by the task price.
        uint256 sumDeposit; // The sum of the deposits of the translator and the challenger, if any. This value (minus arbitration fees) will be paid to the party that wins the dispute.
        address payable[3] parties; // Translator and challenger of the task.
        uint256 disputeID; // The ID of the dispute created in the arbitrator contract.
        BinaryAppealable.Round[] rounds; // Tracks each appeal round of a dispute.
        uint256 ruling; // Ruling given to the dispute of the task by the arbitrator.
    }

    address public governor = msg.sender; // The governor of the contract.
    uint256 public reviewTimeout; // Time in seconds, during which the submitted translation can be challenged.
    // All multipliers below are in basis points.

    IArbitrator public arbitrator; // Address of the arbitrator contract. TRUSTED.
    bytes public arbitratorExtraData; // Extra data to set up the arbitration.
    uint256 public translationMultiplier; // Multiplier for calculating the value of the deposit translator must pay to self-assign a task.
    uint256 public challengeMultiplier; // Multiplier for calculating the value of the deposit challenger must pay to challenge a translation.
    uint256 public sharedStakeMultiplier; // Multiplier for calculating the appeal fee that must be paid by the submitter in the case where there is no winner or loser (e.g. when the arbitrator ruled "refuse to arbitrate").
    uint256 public winnerStakeMultiplier; // Multiplier for calculating the appeal fee of the party that won the previous round.
    uint256 public loserStakeMultiplier; // Multiplier for calculating the appeal fee of the party that lost the previous round.
    
    Task[] public tasks; // Stores all created tasks.

    mapping(uint256 => uint256) public disputeIDtoTaskID; // Maps a disputeID to its respective task.

    /* *** Events *** */

    /** @dev To be emitted when a new task is created.
     *  @param _taskID The ID of the newly created task.
     *  @param _requester The address that created the task.
     *  @param _timestamp When the task was created.
     */
    event TaskCreated(uint256 indexed _taskID, address indexed _requester, uint256 _timestamp);

    /** @dev To be emitted when a translator assigns a task to himself.
     *  @param _taskID The ID of the assigned task.
     *  @param _translator The address that was assigned to the task.
     *  @param _price The task price at the moment it was assigned.
     *  @param _timestamp When the task was assigned.
     */
    event TaskAssigned(uint256 indexed _taskID, address indexed _translator, uint256 _price, uint256 _timestamp);

    /** @dev To be emitted when a translation is submitted.
     *  @param _taskID The ID of the respective task.
     *  @param _translator The address that performed the translation.
     *  @param _translatedText A URI to the translated text.
     *  @param _timestamp When the translation was submitted.
     */
    event TranslationSubmitted(
        uint256 indexed _taskID,
        address indexed _translator,
        string _translatedText,
        uint256 _timestamp
    );

    /** @dev To be emitted when a translation is challenged.
     *  @param _taskID The ID of the respective task.
     *  @param _challenger The address of the challenger.
     *  @param _timestamp When the task was challenged.
     */
    event TranslationChallenged(uint256 indexed _taskID, address indexed _challenger, uint256 _timestamp);

    /** @dev To be emitted when a task is resolved, either by the translation being accepted, the requester being reimbursed or a dispute being settled.
     *  @param _taskID The ID of the respective task.
     *  @param _reason Short description of what caused the task to be solved. One of: 'translation-accepted' | 'requester-reimbursed' | 'dispute-settled'
     *  @param _timestamp When the task was resolved.
     */
    event TaskResolved(uint256 indexed _taskID, string _reason, uint256 _timestamp);

    /** @dev To be emitted when someone contributes to the appeal process.
     *  @param _taskID The ID of the respective task.
     *  @param _party The party which received the contribution.
     *  @param _contributor The address of the contributor.
     *  @param _amount The amount contributed.
     */
    event AppealContribution(uint256 indexed _taskID, Party _party, address indexed _contributor, uint256 _amount);

    /** @dev To be emitted when the appeal fees of one of the parties are fully funded.
     *  @param _taskID The ID of the respective task.
     *  @param _party The party that is fully funded.
     */
    event HasPaidAppealFee(uint256 indexed _taskID, Party _party);

    /* *** Modifiers *** */
    modifier onlyGovernor() {
        require(msg.sender == governor, "Only governor is allowed to perform this.");
        _;
    }

    /** @dev Constructor.
     *  @param _arbitrator The arbitrator of the contract.
     *  @param _arbitratorExtraData Extra data for the arbitrator.
     *  @param _reviewTimeout Time in seconds during which a translation can be challenged.
     *  @param _translationMultiplier Multiplier for calculating translator's deposit. In basis points.
     *  @param _challengeMultiplier Multiplier for calculating challenger's deposit. In basis points.
     *  @param _sharedStakeMultiplier Multiplier of the appeal cost that submitter must pay for a round when there is no winner/loser in the previous round. In basis points.
     *  @param _winnerStakeMultiplier Multiplier of the appeal cost that the winner has to pay for a round. In basis points.
     *  @param _loserStakeMultiplier Multiplier of the appeal cost that the loser has to pay for a round. In basis points.
     */
    constructor(
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        uint256 _reviewTimeout,
        uint256 _translationMultiplier,
        uint256 _challengeMultiplier,
        uint256 _sharedStakeMultiplier,
        uint256 _winnerStakeMultiplier,
        uint256 _loserStakeMultiplier
    ) BinaryAppealable() {
        reviewTimeout = _reviewTimeout;
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        translationMultiplier = _translationMultiplier;
        challengeMultiplier = _challengeMultiplier;
        sharedStakeMultiplier = _sharedStakeMultiplier;
        winnerStakeMultiplier = _winnerStakeMultiplier;
        loserStakeMultiplier = _loserStakeMultiplier;
    }

    // ******************** //
    // *    Governance    * //
    // ******************** //

    /** @dev Changes the governor of this contract.
     *  @param _governor A new governor.
     */
    function changeGovernor(address _governor) public onlyGovernor {
        governor = _governor;
    }

    /** @dev Changes the time allocated for the review phase.
     *  @param _reviewTimeout A new value of the time allotted for reviewing a translation. In seconds.
     */
    function changeReviewTimeout(uint256 _reviewTimeout) public onlyGovernor {
        reviewTimeout = _reviewTimeout;
    }

    /** @dev Changes the multiplier for translators' deposit.
     *  @param _translationMultiplier A new value of the multiplier for calculating translator's deposit. In basis points.
     */
    function changeTranslationMultiplier(uint256 _translationMultiplier) public onlyGovernor {
        translationMultiplier = _translationMultiplier;
    }

    /** @dev Changes the multiplier for challengers' deposit.
     *  @param _challengeMultiplier A new value of the multiplier for calculating challenger's deposit. In basis points.
     */
    function changeChallengeMultiplier(uint256 _challengeMultiplier) public onlyGovernor {
        challengeMultiplier = _challengeMultiplier;
    }

    /** @dev Changes the percentage of arbitration fees that must be paid by parties as a fee stake if there was no winner and loser in the previous round.
     *  @param _sharedStakeMultiplier A new value of the multiplier of the appeal cost in case where there was no winner/loser in previous round. In basis point.
     */
    function changeSharedStakeMultiplier(uint256 _sharedStakeMultiplier) public onlyGovernor {
        sharedStakeMultiplier = _sharedStakeMultiplier;
    }

    /** @dev Changes the percentage of arbitration fees that must be paid as a fee stake by the party that won the previous round.
     *  @param _winnerStakeMultiplier A new value of the multiplier of the appeal cost that the winner of the previous round has to pay. In basis points.
     */
    function changeWinnerStakeMultiplier(uint256 _winnerStakeMultiplier) public onlyGovernor {
        winnerStakeMultiplier = _winnerStakeMultiplier;
    }

    /** @dev Changes the percentage of arbitration fees that must be paid as a fee stake by the party that lost the previous round.
     *  @param _loserStakeMultiplier A new value for the multiplier of the appeal cost that the party that lost the previous round has to pay. In basis points.
     */
    function changeLoserStakeMultiplier(uint256 _loserStakeMultiplier) public onlyGovernor {
        loserStakeMultiplier = _loserStakeMultiplier;
    }

    // **************************** //
    // *    Modifying the state   * //
    // **************************** //

    /** @dev Creates a task based on provided details. Requires a value of maximum price to be deposited.
     *  @param _deadline The deadline for the translation to be completed.
     *  @param _minPrice A minimum price of the translation. In wei.
     *  @param _metaEvidence A URI of a meta-evidence object for task submission.
     *  @return taskID The ID of the created task.
     */
    function createTask(
        uint256 _deadline,
        uint256 _minPrice,
        string calldata _metaEvidence
    ) external payable returns (uint256 taskID) {
        require(msg.value >= _minPrice, "Deposited value should be greater than or equal to the min price.");
        require(_deadline > block.timestamp, "The deadline should be in the future.");

        taskID = tasks.length;

        Task storage task = tasks.push();
        task.submissionTimeout = _deadline - block.timestamp;
        task.minPrice = _minPrice;
        task.maxPrice = msg.value;
        task.lastInteraction = block.timestamp;
        task.requester = msg.sender;
        task.requesterDeposit = msg.value;

        emit MetaEvidence(taskID, _metaEvidence);
        emit TaskCreated(taskID, msg.sender, block.timestamp);
    }

    /** @dev Assigns a specific task to the sender. Requires a translator's deposit.
     *  Note that the deposit should be a little higher than the required value because of the price increase during the time the transaction is mined. The surplus will be reimbursed.
     *  @param _taskID The ID of the task.
     */
    function assignTask(uint256 _taskID) external payable {
        Task storage task = tasks[_taskID];
        require(block.timestamp - task.lastInteraction <= task.submissionTimeout, "The deadline has already passed.");

        uint256 price = task.minPrice +
            ((task.maxPrice - task.minPrice) * (block.timestamp - task.lastInteraction)) /
            task.submissionTimeout;
        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        uint256 translatorDeposit = arbitrationCost.addCap((translationMultiplier.mulCap(price)) / MULTIPLIER_DIVISOR);

        require(task.status == Status.Created, "Task has already been assigned or reimbursed.");
        require(msg.value >= translatorDeposit, "Not enough ETH to reach the required deposit value.");

        task.parties[uint256(Party.Translator)] = msg.sender;
        task.status = Status.Assigned;

        uint256 remainder = task.maxPrice - price;
        task.requester.send(remainder);
        // Update requester's deposit since we reimbursed him the difference between maximum and actual price.
        task.requesterDeposit = price;
        task.sumDeposit = translatorDeposit;

        remainder = msg.value - translatorDeposit;
        msg.sender.send(remainder);

        emit TaskAssigned(_taskID, msg.sender, price, block.timestamp);
    }

    /** @dev Submits translated text for a specific task.
     *  @param _taskID The ID of the task.
     *  @param _translation A URI to the translated text.
     */
    function submitTranslation(uint256 _taskID, string calldata _translation) external {
        Task storage task = tasks[_taskID];
        require(
            task.status == Status.Assigned,
            "The task is either not assigned or translation has already been submitted."
        );
        require(block.timestamp - task.lastInteraction <= task.submissionTimeout, "The deadline has already passed.");
        require(
            msg.sender == task.parties[uint256(Party.Translator)],
            "Can't submit translation to a task that wasn't assigned to you."
        );
        task.status = Status.AwaitingReview;
        task.lastInteraction = block.timestamp;

        emit TranslationSubmitted(_taskID, msg.sender, _translation, block.timestamp);
    }

    /** @dev Reimburses the requester if no one picked the task or the translator failed to submit the translation before deadline.
     *  @param _taskID The ID of the task.
     */
    function reimburseRequester(uint256 _taskID) external {
        Task storage task = tasks[_taskID];
        require(task.status < Status.AwaitingReview, "Can't reimburse if translation was submitted.");
        require(
            block.timestamp - task.lastInteraction > task.submissionTimeout,
            "Can't reimburse if the deadline hasn't passed yet."
        );
        task.status = Status.Resolved;
        // Requester gets his deposit back and also the deposit of the translator, if there was one.
        // Note that sumDeposit can't contain challenger's deposit until the task is in DisputeCreated status.
        uint256 amount = task.requesterDeposit + task.sumDeposit;
        task.requester.send(amount);

        task.requesterDeposit = 0;
        task.sumDeposit = 0;

        emit TaskResolved(_taskID, "requester-reimbursed", block.timestamp);
    }

    /** @dev Pays the translator for completed task if no one challenged the translation during the review period.
     *  @param _taskID The ID of the task.
     */
    function acceptTranslation(uint256 _taskID) external {
        Task storage task = tasks[_taskID];
        require(task.status == Status.AwaitingReview, "The task is in the wrong status.");
        require(block.timestamp - task.lastInteraction > reviewTimeout, "The review phase hasn't passed yet.");
        task.status = Status.Resolved;
        // Translator gets the price of the task and his deposit back. Note that sumDeposit can't contain challenger's deposit until the task has DisputeCreated status.
        uint256 amount = task.requesterDeposit + task.sumDeposit;
        task.parties[uint256(Party.Translator)].send(amount);

        task.requesterDeposit = 0;
        task.sumDeposit = 0;

        emit TaskResolved(_taskID, "translation-accepted", block.timestamp);
    }

    /** @dev Challenges the translation of a specific task. Requires challenger's deposit.
     *  @param _taskID The ID of the task.
     *  @param _evidence A link to evidence using its URI. Ignored if not provided.
     */
    function challengeTranslation(uint256 _taskID, string calldata _evidence) external payable {
        Task storage task = tasks[_taskID];

        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        uint256 challengeDeposit = arbitrationCost.addCap(
            (challengeMultiplier.mulCap(task.requesterDeposit)) / MULTIPLIER_DIVISOR
        );

        require(task.status == Status.AwaitingReview, "The task is in the wrong status.");
        require(block.timestamp - task.lastInteraction <= reviewTimeout, "The review phase has already passed.");
        require(msg.value >= challengeDeposit, "Not enough ETH to cover challenge deposit.");

        task.status = Status.DisputeCreated;
        task.parties[uint256(Party.Challenger)] = msg.sender;

        task.disputeID = arbitrator.createDispute{value: arbitrationCost}(2, arbitratorExtraData);
        disputeIDtoTaskID[task.disputeID] = _taskID;
        task.rounds.push();
        task.sumDeposit = task.sumDeposit.addCap(challengeDeposit).subCap(arbitrationCost);

        uint256 remainder = msg.value - challengeDeposit;
        msg.sender.send(remainder);

        emit Dispute(arbitrator, task.disputeID, _taskID, _taskID);
        emit TranslationChallenged(_taskID, msg.sender, block.timestamp);

        if (bytes(_evidence).length > 0) emit Evidence(arbitrator, _taskID, msg.sender, _evidence);
    }

    /** @dev Takes up to the total amount required to fund a side of an appeal. Reimburses the rest. Creates an appeal if all sides are fully funded.
     *  @param _taskID The ID of challenged task.
     *  @param _side The party that pays the appeal fee.
     */
    function fundAppeal(uint256 _taskID, Party _side) external payable {
        Task storage task = tasks[_taskID];
        require(task.status == Status.DisputeCreated, "No dispute to appeal.");

        BinaryAppealable.Round[] storage rounds = task.rounds;
        (uint256 contribution, bool sideFullyFunded, bool appealCreated) = _fundAppeal(
            rounds,
            BinaryAppealable.BaseParty(uint256(_side)), 
            task.disputeID, 
            arbitrator, 
            arbitratorExtraData, 
            loserStakeMultiplier,
            winnerStakeMultiplier,
            sharedStakeMultiplier
        );
        emit AppealContribution(_taskID, _side, msg.sender, contribution);
        if (sideFullyFunded)
            emit HasPaidAppealFee(_taskID, _side);

    }

    /** @dev Withdraws contributions of appeal rounds. Reimburses contributions if no disputes were raised. If a dispute was raised, sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute.
     *  @param _beneficiary The address that made contributions.
     *  @param _taskID The ID of the associated task.
     *  @param _round The round from which to withdraw.
     */
    function withdrawFeesAndRewards(
        address payable _beneficiary,
        uint256 _taskID,
        uint256 _round
    ) public {
        Task storage task = tasks[_taskID];
        require(task.status == Status.Resolved, "The task should be resolved.");

        BinaryAppealable.Round[] storage rounds = task.rounds;
        uint256 reward = _withdrawFeesAndRewards(rounds, _beneficiary, _round, uint256(task.ruling));
        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }

    /** @dev Withdraws contributions of multiple appeal rounds at once. This function is O(n) where n is the number of rounds. This could exceed the gas limit, therefore this function should be used only as a utility and not be relied upon by other contracts.
     *  @param _beneficiary The address that made contributions.
     *  @param _taskID The ID of the associated task.
     *  @param _cursor The round from where to start withdrawing.
     *  @param _count The number of rounds to iterate. If set to 0 or a value larger than the number of rounds, iterates until the last round.
     */
    function batchRoundWithdraw(
        address payable _beneficiary,
        uint256 _taskID,
        uint256 _cursor,
        uint256 _count
    ) public {
        Task storage task = tasks[_taskID];
        require(task.status == Status.Resolved, "The task should be resolved.");
        
        BinaryAppealable.Round[] storage rounds = task.rounds;
        uint256 reward = _withdrawRoundBatch(rounds, _beneficiary, _cursor, _count, uint256(task.ruling));
        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }

    /** @dev Gives the ruling for a dispute. Can only be called by the arbitrator.
     *  The purpose of this function is to ensure that the address calling it has the right to rule on the contract and to invert the ruling in the case a party loses from lack of appeal fees funding.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refuse to arbitrate".
     */
    function rule(uint256 _disputeID, uint256 _ruling) external override {
        Party resultRuling = Party(_ruling);
        uint256 taskID = disputeIDtoTaskID[_disputeID];
        Task storage task = tasks[taskID];
        BinaryAppealable.Round storage round = task.rounds[task.rounds.length - 1];
        require(msg.sender == address(arbitrator), "Must be called by the arbitrator.");
        require(task.status == Status.DisputeCreated, "The dispute has already been resolved.");

        // If only one side paid its fees we assume the ruling to be in its favor.
        if (round.sideFunded == BinaryAppealable.BaseParty(uint256(Party.Translator))) resultRuling = Party.Translator;
        else if (round.sideFunded == BinaryAppealable.BaseParty(uint256(Party.Challenger))) resultRuling = Party.Challenger;

        emit Ruling(IArbitrator(msg.sender), _disputeID, uint256(resultRuling));
        executeRuling(_disputeID, uint256(resultRuling));
    }

    /** @dev Executes the ruling of a dispute.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refuse to arbitrate".
     */
    function executeRuling(uint256 _disputeID, uint256 _ruling) internal {
        uint256 taskID = disputeIDtoTaskID[_disputeID];
        Task storage task = tasks[taskID];
        task.status = Status.Resolved;
        task.ruling = _ruling;
        uint256 amount;

        if (_ruling == uint256(Party.None)) {
            task.requester.send(task.requesterDeposit);
            // The value of sumDeposit is split among parties in this case. If the sum is uneven the value of 1 wei can be burnt.
            amount = task.sumDeposit / 2;
            task.parties[uint256(Party.Translator)].send(amount);
            task.parties[uint256(Party.Challenger)].send(amount);
        } else if (_ruling == uint256(Party.Translator)) {
            amount = task.requesterDeposit + task.sumDeposit;
            task.parties[uint256(Party.Translator)].send(amount);
        } else {
            task.requester.send(task.requesterDeposit);
            task.parties[uint256(Party.Challenger)].send(task.sumDeposit);
        }

        task.requesterDeposit = 0;
        task.sumDeposit = 0;

        emit TaskResolved(taskID, "dispute-settled", block.timestamp);
    }

    /** @dev Submit a reference to evidence. EVENT.
     *  @param _taskID The ID of the task.
     *  @param _evidence A link to evidence using its URI.
     */
    function submitEvidence(uint256 _taskID, string calldata _evidence) external {
        Task storage task = tasks[_taskID];
        require(task.status != Status.Resolved, "The task must not already be resolved.");
        emit Evidence(arbitrator, _taskID, msg.sender, _evidence);
    }

    // ******************** //
    // *      Getters     * //
    // ******************** //

    /** @dev Returns the sum of withdrawable wei from appeal rounds. This function is O(n), where n is the number of rounds of the task. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  @param _taskID The ID of the associated task.
     *  @param _beneficiary The contributor for which to query.
     *  @return total The total amount of wei available to withdraw.
     */
    function amountWithdrawable(uint256 _taskID, address payable _beneficiary) external view returns (uint256 total) {
        Task storage task = tasks[_taskID];
        if (task.status != Status.Resolved) return total;

        total = _amountWithdrawable(task.rounds, _beneficiary, uint256(task.ruling));
    }

    /** @dev Gets the deposit required for self-assigning the task.
     *  @param _taskID The ID of the task.
     *  @return deposit The translator's deposit.
     */
    function getDepositValue(uint256 _taskID) public view returns (uint256 deposit) {
        Task storage task = tasks[_taskID];
        if (block.timestamp - task.lastInteraction > task.submissionTimeout || task.status != Status.Created) {
            deposit = NOT_PAYABLE_VALUE;
        } else {
            uint256 price = task.minPrice +
                ((task.maxPrice - task.minPrice) * (block.timestamp - task.lastInteraction)) /
                task.submissionTimeout;
            uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
            deposit = arbitrationCost.addCap((translationMultiplier.mulCap(price)) / MULTIPLIER_DIVISOR);
        }
    }

    /** @dev Gets the deposit required for challenging the translation.
     *  @param _taskID The ID of the task.
     *  @return deposit The challengers's deposit.
     */
    function getChallengeValue(uint256 _taskID) public view returns (uint256 deposit) {
        Task storage task = tasks[_taskID];
        if (block.timestamp - task.lastInteraction > reviewTimeout || task.status != Status.AwaitingReview) {
            deposit = NOT_PAYABLE_VALUE;
        } else {
            uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
            deposit = arbitrationCost.addCap((challengeMultiplier.mulCap(task.requesterDeposit)) / MULTIPLIER_DIVISOR);
        }
    }

    /** @dev Gets the current price of a specified task.
     *  @param _taskID The ID of the task.
     *  @return price The price of the task.
     */
    function getTaskPrice(uint256 _taskID) public view returns (uint256 price) {
        Task storage task = tasks[_taskID];
        if (block.timestamp - task.lastInteraction > task.submissionTimeout || task.status != Status.Created) {
            price = 0;
        } else {
            price =
                task.minPrice +
                ((task.maxPrice - task.minPrice) * (block.timestamp - task.lastInteraction)) /
                task.submissionTimeout;
        }
    }

    /** @dev Gets the total number of created tasks.
     *  @return The number of created tasks.
     */
    function getTaskCount() public view returns (uint256) {
        return tasks.length;
    }

    /** @dev Gets the addresses of parties of a specified task.
     *  @param _taskID The ID of the task.
     *  @return parties The addresses of translator and challenger as [ZERO_ADDRESS, translator, challenger].
     */
    function getTaskParties(uint256 _taskID) public view returns (address payable[3] memory parties) {
        Task storage task = tasks[_taskID];
        parties = task.parties;
    }
}