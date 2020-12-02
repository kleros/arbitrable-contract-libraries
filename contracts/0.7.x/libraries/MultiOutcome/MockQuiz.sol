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

import "./MultiOutcomeArbitrable.sol";
import "../.././interfaces/IAppealEvents.sol";
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

contract MockQuiz is IArbitrable, IEvidence, IAppealEvents {
    using CappedMath for uint256;
    using MultiOutcomeArbitrable for MultiOutcomeArbitrable.ArbitrableStorage;

    /* *** Contract variables *** */
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.
    uint256 private constant NOT_PAYABLE_VALUE = (2**256 - 2) / 2; // A value depositors won't be able to pay.

    enum Status {Created, Answered, Challenged, Resolved}

    // Arrays of 3 elements in the Task and Round structs map to the parties. Index "0" is not used, "1" is used for the translator and "2" for the challenger.
    struct Question {
        uint256 submissionTimeout; // Time in seconds allotted for submitting a translation. The end of this period is considered a deadline.
        uint256 prize; // Minimum price for the translation. When the task is created it has this minimum price that gradually increases such that it reaches the maximum price at the deadline.
        Status status; // Status of the task.
        uint256 lastInteraction; // The time of the last action performed on the task. Note that lastInteraction is updated only during timeout-related actions such as the creation of the task and the submission of the translation.
        address payable host; // The party requesting the translation.
        address payable guest; // The party requesting the translation.
        uint256 guestAnswer;
        uint256 hostAnswer;
        uint256 sumDeposit; // The deposit requester makes when creating the task. Once the task is assigned this deposit will be partially reimbursed and its value replaced by the task price.
    }

    uint256 public challengeTimeout; // Time in seconds, during which the submitted translation can be challenged.
    // All multipliers below are in basis points.
    uint256 public translationMultiplier; // Multiplier for calculating the value of the deposit translator must pay to self-assign a task.
    uint256 public challengeMultiplier; // Multiplier for calculating the value of the deposit challenger must pay to challenge a translation.

    Question[] public questions; // Stores all created tasks.

    /// @dev Contains most of the data related to arbitration.
    MultiOutcomeArbitrable.ArbitrableStorage public arbitrableStorage;

    /* *** Events *** */

    /** @dev To be emitted when a new task is created.
     *  @param _questionID The ID of the newly created task.
     *  @param _submitter The address that created the task.
     */
    event QuestionCreated(uint256 indexed _questionID, address indexed _submitter);

    /** @dev To be emitted when a translation is submitted.
     *  @param _questionID The ID of the respective task.
     *  @param _guest The address that performed the translation.
     *  @param _answer A URI to the translated text.
     */
    event QuestionSubmitted(uint256 indexed _questionID, address indexed _guest, uint256 _answer);

    /** @dev To be emitted when a translation is challenged.
     *  @param _questionID The ID of the respective task.
     *  @param _answer A URI to the translated text.
     */
    event QuestionChallenged(uint256 indexed _questionID, uint256 _answer);

    /** @dev To be emitted when a task is resolved, either by the translation being accepted, the requester being reimbursed or a dispute being settled.
     *  @param _questionID The ID of the respective task.
     *  @param _answer Short description of what caused the task to be solved. One of: 'translation-accepted' | 'requester-reimbursed' | 'dispute-settled'
     */
    event QuestionResolved(uint256 indexed _questionID, uint256 _answer);

    /** @dev Constructor.
     *  @param _arbitrator The arbitrator of the contract.
     *  @param _arbitratorExtraData Extra data for the arbitrator.
     *  @param _challengeTimeout Time in seconds during which a translation can be challenged.
     *  @param _translationMultiplier Multiplier for calculating translator's deposit. In basis points.
     *  @param _challengeMultiplier Multiplier for calculating challenger's deposit. In basis points.
     *  @param _sharedStakeMultiplier Multiplier of the appeal cost that submitter must pay for a round when there is no winner/loser in the previous round. In basis points.
     *  @param _winnerStakeMultiplier Multiplier of the appeal cost that the winner has to pay for a round. In basis points.
     *  @param _loserStakeMultiplier Multiplier of the appeal cost that the loser has to pay for a round. In basis points.
     */
    constructor(
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        uint256 _challengeTimeout,
        uint256 _translationMultiplier,
        uint256 _challengeMultiplier,
        uint256 _sharedStakeMultiplier,
        uint256 _winnerStakeMultiplier,
        uint256 _loserStakeMultiplier
    ) {
        challengeTimeout = _challengeTimeout;
        translationMultiplier = _translationMultiplier;
        challengeMultiplier = _challengeMultiplier;
        arbitrableStorage.setMultipliers(_sharedStakeMultiplier, _winnerStakeMultiplier, _loserStakeMultiplier);
        arbitrableStorage.setArbitrator(_arbitrator, _arbitratorExtraData);
    }

    // **************************** //
    // *    Modifying the state   * //
    // **************************** //

    /** @dev Creates a task based on provided details. Requires a value of maximum price to be deposited.
     *  @param _deadline The deadline for the translation to be completed.
     *  @param _metaEvidence A URI of a meta-evidence object for task submission.
     *  @return questionID The ID of the created task.
     */
    function createQuestion(
        uint256 _deadline,
        string calldata _metaEvidence
    ) external payable returns (uint256 questionID) {
        require(_deadline > block.timestamp, "The deadline should be in the future.");

        questionID = questions.length;

        Question storage question = questions.push();
        question.submissionTimeout = _deadline - block.timestamp;
        question.prize = msg.value;
        question.lastInteraction = block.timestamp;
        question.host = msg.sender;

        emit MetaEvidence(questionID, _metaEvidence);
        emit QuestionCreated(questionID, msg.sender);
    }

    /** @dev Assigns a specific task to the sender. Requires a translator's deposit.
     *  Note that the deposit should be a little higher than the required value because of the price increase during the time the transaction is mined. The surplus will be reimbursed.
     *  @param _questionID The ID of the task.
     *  @param _answer The ID of the task.
     */
    function submitAnswer(uint256 _questionID, uint256 _answer) external payable {
        Question storage question = questions[_questionID];
        require(block.timestamp - question.lastInteraction <= question.submissionTimeout, "The deadline has already passed.");

        uint256 arbitrationCost = arbitrableStorage.getArbitrationCost();

        require(question.status == Status.Created, "Invalid staus.");
        require(msg.value >= arbitrationCost, "Not enough ETH to reach the required deposit value.");
        require(_answer != 0, "0 is reserved for refuse to rule");

        question.guest = msg.sender;
        question.guestAnswer = _answer;
        question.status = Status.Answered;
        question.sumDeposit = arbitrationCost;
        question.lastInteraction = block.timestamp;

        uint256 remainder = msg.value - arbitrationCost;
        msg.sender.send(remainder);

        emit QuestionSubmitted(_questionID, msg.sender, _answer);
    }

    /** @dev Reimburses the requester if no one picked the task or the translator failed to submit the translation before deadline.
     *  @param _questionID The ID of the task.
     */
    function reimburseHost(uint256 _questionID) external {
        Question storage question = questions[_questionID];
        require(question.status == Status.Created, "Can't reimburse if translation was submitted.");
        require(
            block.timestamp - question.lastInteraction > question.submissionTimeout,
            "Can't reimburse if the deadline hasn't passed yet."
        );
        question.status = Status.Resolved;
        question.host.send(question.prize);

        emit QuestionResolved(_questionID, 0);
    }

    /** @dev Pays the translator for completed task if no one challenged the translation during the review period.
     *  @param _questionID The ID of the task.
     */
    function rewardGuest(uint256 _questionID) external {
        Question storage question = questions[_questionID];
        require(question.status == Status.Answered, "The task is in the wrong status.");
        require(block.timestamp - question.lastInteraction > challengeTimeout, "The review phase hasn't passed yet.");
        
        question.status = Status.Resolved;
        question.host.send(question.prize + question.sumDeposit);

        emit QuestionResolved(_questionID, question.guestAnswer);
    }

    /** @dev Challenges the translation of a specific task. Requires challenger's deposit.
     *  @param _questionID The ID of the task.
     *  @param _answer The ID of the task.
     *  @param _evidence A link to evidence using its URI. Ignored if not provided.
     */
    function challengeAnswer(uint256 _questionID, uint256 _answer, string calldata _evidence) external payable {
        Question storage question = questions[_questionID];
        require(msg.sender == question.host, "Only the host can challenge");
        require(question.status == Status.Answered, "The task is in the wrong status.");
        require(block.timestamp - question.lastInteraction <= challengeTimeout, "The review phase has already passed.");
        require(_answer != 0, "0 is reserved for refuse to rule");

        uint256 arbitrationCost = arbitrableStorage.getArbitrationCost();
        require(msg.value >= arbitrationCost, "Not enough ETH to cover challenge deposit.");

        question.status = Status.Challenged;
        question.hostAnswer = _answer;

        arbitrableStorage.createDispute(_questionID, arbitrationCost, _questionID, _questionID);

        emit QuestionChallenged(_questionID, _answer);
        arbitrableStorage.submitEvidence(_questionID, _questionID, _evidence);
    }

    /** @dev Takes up to the total amount required to fund a side of an appeal. Reimburses the rest. Creates an appeal if all sides are fully funded.
     *  @param _questionID The ID of challenged task.
     *  @param _answer The answer that pays the appeal fee.
     */
    function fundAppeal(uint256 _questionID, uint256 _answer) external payable {
        arbitrableStorage.fundAppeal(_questionID, _answer);
    }

    /** @dev Withdraws contributions of appeal rounds. Reimburses contributions if no disputes were raised. If a dispute was raised, sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute.
     *  @param _beneficiary The address that made contributions.
     *  @param _questionID The ID of the associated task.
     *  @param _answer The answer that pays the appeal fee.
     *  @param _round The round from which to withdraw.
     */
    function withdrawFeesAndRewards(
        address payable _beneficiary,
        uint256 _questionID,
        uint256 _answer,
        uint256 _round
    ) public {
        arbitrableStorage.withdrawFeesAndRewards(_questionID, _beneficiary, _answer, _round);
    }

    /** @dev Withdraws contributions of multiple appeal rounds at once. This function is O(n) where n is the number of rounds. This could exceed the gas limit, therefore this function should be used only as a utility and not be relied upon by other contracts.
     *  @param _beneficiary The address that made contributions.
     *  @param _questionID The ID of the associated task.
     *  @param _answer The answer that pays the appeal fee.
     *  @param _cursor The round from where to start withdrawing.
     *  @param _count The number of rounds to iterate. If set to 0 or a value larger than the number of rounds, iterates until the last round.
     */
    function batchRoundWithdraw(
        address payable _beneficiary,
        uint256 _questionID,
        uint256 _answer,
        uint256 _cursor,
        uint256 _count
    ) public {
        arbitrableStorage.withdrawRoundBatch(_questionID, _beneficiary, _answer, _cursor, _count);
    }

    /** @dev Withdraws contributions of multiple appeal rounds at once. This function is O(n) where n is the number of rounds. This could exceed the gas limit, therefore this function should be used only as a utility and not be relied upon by other contracts.
     *  @param _beneficiary The address that made contributions.
     *  @param _questionID The ID of the associated task.
     *  @param _answers The answers that pays the appeal fee.
     *  @param _round The round from which to withdraw.
     */
    function withdrawMultipleRulings(
        address payable _beneficiary,
        uint256 _questionID,
        uint256[] memory _answers,
        uint256 _round
    ) public {
        arbitrableStorage.withdrawMultipleRulings(_questionID, _beneficiary, _answers, _round);
    }

    /** @dev Gives the ruling for a dispute. Can only be called by the arbitrator.
     *  The purpose of this function is to ensure that the address calling it has the right to rule on the contract and to invert the ruling in the case a party loses from lack of appeal fees funding.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refuse to arbitrate".
     */
    function rule(uint256 _disputeID, uint256 _ruling) external override {
        uint256 finalAnswer = arbitrableStorage.processRuling(_disputeID, _ruling);
        uint256 questionID = arbitrableStorage.disputeIDtoItemID[_disputeID];
        Question storage question = questions[questionID];
        question.status = Status.Resolved;

        if (finalAnswer == question.guestAnswer) {
            question.guest.send(question.prize + question.sumDeposit);
        } else if (finalAnswer == question.hostAnswer) {
            question.host.send(question.prize + question.sumDeposit);
        } else {
            uint256 splitAmount = (question.prize + question.sumDeposit) / 2;
            question.host.send(splitAmount);
            question.guest.send(splitAmount);
        }

        emit QuestionResolved(questionID, _ruling);
    }

    /** @dev Submit a reference to evidence. EVENT.
     *  @param _taskID The ID of the task.
     *  @param _evidence A link to evidence using its URI.
     */
    function submitEvidence(uint256 _taskID, string calldata _evidence) external {
        arbitrableStorage.submitEvidence(_taskID, _taskID, _evidence);
    }

    // ******************** //
    // *      Getters     * //
    // ******************** //

    /** @dev Returns the sum of withdrawable wei from appeal rounds. This function is O(n), where n is the number of rounds of the task. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  @param _questionID The ID of the associated task.
     *  @param _beneficiary The contributor for which to query.
     *  @param _answer The answer that pays the appeal fee.
     *  @return total The total amount of wei available to withdraw.
     */
    function amountWithdrawable(
        uint256 _questionID, 
        address payable _beneficiary,
        uint256 _answer
    ) external view returns (uint256 total) {
        total = arbitrableStorage.amountWithdrawable(_questionID, _beneficiary, _answer);
    }

    /** @dev Gets the total number of created tasks.
     *  @return The number of created tasks.
     */
    function getQuestionCount() public view returns (uint256) {
        return questions.length;
    }

    /** @dev Gets the number of rounds of the specific task.
     *  @param _questionID The ID of the task.
     *  @return The number of rounds.
     */
    function getNumberOfRounds(uint256 _questionID) public view returns (uint256) {
        return arbitrableStorage.getNumberOfRounds(_questionID);
    }

    /** @dev Gets the contributions made by a party for a given round of appeal of a task.
     *  @param _questionID The ID of the task.
     *  @param _round The position of the round.
     *  @param _contributor The address of the contributor.
     *  @return answersFunded contributions The answers currently funded and their respective contributions.
     */
    function getContributions(
        uint256 _questionID,
        uint256 _round,
        address _contributor
    ) public view returns (uint256[2] memory answersFunded, uint256[2] memory contributions) {
        return arbitrableStorage.getContributionsToSuccessfulFundings(_questionID, _round, _contributor);
    }

    /** @dev Gets the information on a round of a task.
     *  @param _questionID The ID of the task.
     *  @param _round The round to be queried.
     *  @return paidFees sideFunded feeRewards appealed The round information.
     */
    function getRoundInfo(uint256 _questionID, uint256 _round)
        public
        view
        returns (
            uint256[2] memory paidFees,
            uint256[2] memory answersFunded,
            uint256 feeRewards,
            bool appealed
        )
    {
        return arbitrableStorage.getRoundInfo(_questionID, _round);
    }
}