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

import "./MultiOutcomeUpgradableArbitrable.sol";
import "../.././interfaces/IAppealEvents.sol";
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

contract MockQuizUpgradable is IArbitrable, IEvidence, IAppealEvents {
    using CappedMath for uint256;
    using MultiOutcomeUpgradableArbitrable for MultiOutcomeUpgradableArbitrable.ArbitrableStorage;

    /* *** Contract variables *** */
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.
    uint256 private constant NOT_PAYABLE_VALUE = (2**256 - 2) / 2; // A value depositors won't be able to pay.

    enum Status {Created, Answered, Challenged, Resolved}

    struct Question {
        uint256 submissionTimeout; // Time in seconds allotted for submitting an answer. The end of this period is considered a deadline.
        uint256 prize; // The prize that someone can win if they answers the question correctly.
        Status status; // Status of the question.
        uint256 lastInteraction; // The time of the last action performed on the question.
        address payable host; // The address submitting the question.
        address payable guest; // The address submitting an answer to the question.
        uint256 guestAnswer; // Answer submitted by the guest. 
        uint256 hostAnswer; // Answer submitted by the host if they decides to challenge it.
        uint256 sumDeposit; // The deposit the guest makes when submitting an answer.
    }

    uint256 public challengeTimeout; // Time in seconds, during which the submitted answer can be challenged.

    Question[] public questions; // Stores all created questions.

    /// @dev Contains most of the data related to arbitration.
    MultiOutcomeUpgradableArbitrable.ArbitrableStorage public arbitrableStorage;

    /* *** Events *** */

    /** @dev To be emitted when a new question is created.
     *  @param _questionID The ID of the newly created question.
     *  @param _submitter The address that created the question.
     */
    event QuestionCreated(uint256 indexed _questionID, address indexed _submitter);

    /** @dev To be emitted when an answer is submitted.
     *  @param _questionID The ID of the respective question.
     *  @param _guest The address that answered the question.
     *  @param _answer The answer.
     */
    event QuestionSubmitted(uint256 indexed _questionID, address indexed _guest, uint256 _answer);

    /** @dev To be emitted when an answer is challenged.
     *  @param _questionID The ID of the respective question.
     *  @param _answer The answer deemed correct.
     */
    event QuestionChallenged(uint256 indexed _questionID, uint256 _answer);

    /** @dev To be emitted when a question is resolved.
     *  @param _questionID The ID of the respective question.
     *  @param _answer Answer deemed correct. 0 if no one answered or if jurors refused to rule.
     */
    event QuestionResolved(uint256 indexed _questionID, uint256 _answer);

    /** @dev Constructor.
     *  @param _arbitrator The arbitrator of the contract.
     *  @param _arbitratorExtraData Extra data for the arbitrator.
     *  @param _challengeTimeout Time in seconds during which an answer to a question can be challenged.
     *  @param _sharedStakeMultiplier Multiplier of the appeal cost that submitter must pay for a round when there is no winner/loser in the previous round. In basis points.
     *  @param _winnerStakeMultiplier Multiplier of the appeal cost that the winner has to pay for a round. In basis points.
     *  @param _loserStakeMultiplier Multiplier of the appeal cost that the loser has to pay for a round. In basis points.
     */
    constructor(
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        uint256 _challengeTimeout,
        uint256 _sharedStakeMultiplier,
        uint256 _winnerStakeMultiplier,
        uint256 _loserStakeMultiplier
    ) {
        challengeTimeout = _challengeTimeout;
        arbitrableStorage.setMultipliers(_sharedStakeMultiplier, _winnerStakeMultiplier, _loserStakeMultiplier);
        arbitrableStorage.setArbitrator(_arbitrator, _arbitratorExtraData);
    }

    // **************************** //
    // *    Modifying the state   * //
    // **************************** //

    function changeArbitrator(IArbitrator _arbitrator, bytes memory _arbitratorExtraData) external {
        arbitrableStorage.setArbitrator(_arbitrator, _arbitratorExtraData);
    }

    /** @dev Creates a question based on provided details.
     *  @param _deadline The deadline for the question to be answered.
     *  @param _metaEvidence A URI of a meta-evidence object for question submission.
     *  @return questionID The ID of the created question.
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

    /** @dev Assigns a specific question to the sender. Requires a deposit to cover potential arbitration costs.
     *  @param _questionID The ID of the question.
     *  @param _answer The answer to the question.
     */
    function submitAnswer(uint256 _questionID, uint256 _answer) external payable {
        Question storage question = questions[_questionID];
        require(block.timestamp - question.lastInteraction <= question.submissionTimeout, "The deadline has already passed.");

        uint256 arbitrationCost = arbitrableStorage.getArbitrationCost(_questionID);

        require(question.status == Status.Created, "Invalid status.");
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

    /** @dev Reimburses the host if no one picked the question.
     *  @param _questionID The ID of the question.
     */
    function reimburseHost(uint256 _questionID) external {
        Question storage question = questions[_questionID];
        require(question.status == Status.Created, "Can't reimburse if answer was submitted.");
        require(
            block.timestamp - question.lastInteraction > question.submissionTimeout,
            "Can't reimburse if the deadline hasn't passed yet."
        );
        question.status = Status.Resolved;
        question.host.send(question.prize);

        emit QuestionResolved(_questionID, 0);
    }

    /** @dev Pays the guest for answering the question if the challenge period has passed.
     *  @param _questionID The ID of the question.
     */
    function rewardGuest(uint256 _questionID) external {
        Question storage question = questions[_questionID];
        require(question.status == Status.Answered, "Invalid status.");
        require(block.timestamp - question.lastInteraction > challengeTimeout, "The challenge phase hasn't passed yet.");
        
        question.status = Status.Resolved;
        question.host.send(question.prize + question.sumDeposit);

        emit QuestionResolved(_questionID, question.guestAnswer);
    }

    /** @dev Challenges the translation of a specific question. Requires challenger's deposit.
     *  @param _questionID The ID of the question.
     *  @param _answer The ID of the question.
     *  @param _evidence A link to evidence using its URI. Ignored if not provided.
     */
    function challengeAnswer(uint256 _questionID, uint256 _answer, string calldata _evidence) external payable returns(uint256) {
        Question storage question = questions[_questionID];
        require(msg.sender == question.host, "Only the host can challenge");
        // Status not checked on purpose, in order to test that createDispute(...) reverts if called twice with the same _questionID
        // require(question.status == Status.Answered, "Invalid status.");
        require(block.timestamp - question.lastInteraction <= challengeTimeout, "The challenge phase has already passed.");
        require(_answer != 0, "0 is reserved for refuse to rule.");

        uint256 arbitrationCost = arbitrableStorage.getArbitrationCost(_questionID);
        require(msg.value >= arbitrationCost, "Not enough ETH to cover challenge deposit.");

        question.status = Status.Challenged;
        question.hostAnswer = _answer;

        uint256 disputeID = arbitrableStorage.createDispute(_questionID, arbitrationCost, _questionID, _questionID);

        emit QuestionChallenged(_questionID, _answer);
        arbitrableStorage.submitEvidence(_questionID, _questionID, _evidence);

        return disputeID;
    }

    /** @dev Takes up to the total amount required to fund a side of an appeal. Reimburses the rest. Creates an appeal if two sides are fully funded.
     *  @param _questionID The ID of disputed question.
     *  @param _answer The answer that pays the appeal fee.
     */
    function fundAppeal(uint256 _questionID, uint256 _answer) external payable {
        arbitrableStorage.fundAppeal(_questionID, _answer);
    }

    /** @dev Withdraws contributions of appeal rounds. Reimburses contributions if funding was unsuccessful. If a dispute was raised, sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute.
     *  @param _beneficiary The address that made contributions.
     *  @param _questionID The ID of the associated question.
     *  @param _round The round from which to withdraw.
     *  @param _answer The answer that pays the appeal fee.
     */
    function withdrawFeesAndRewards(
        address payable _beneficiary,
        uint256 _questionID,
        uint256 _round,
        uint256 _answer
    ) public {
        arbitrableStorage.withdrawFeesAndRewards(_questionID, _beneficiary, _round, _answer);
    }

    /** @dev Withdraws contributions of multiple appeal rounds at once. This function is O(n) where n is the number of rounds. This could exceed the gas limit, therefore this function should be used only as a utility and not be relied upon by other contracts.
     *  @param _beneficiary The address that made contributions.
     *  @param _questionID The ID of the associated question.
     *  @param _cursor The round from where to start withdrawing.
     *  @param _count The number of rounds to iterate. If set to 0 or a value larger than the number of rounds, iterates until the last round.
     *  @param _answer The answer that pays the appeal fee.
     */
    function batchWithdrawFeesAndRewards(
        address payable _beneficiary,
        uint256 _questionID,
        uint256 _cursor,
        uint256 _count,
        uint256 _answer
    ) public {
        arbitrableStorage.batchWithdrawFeesAndRewards(_questionID, _beneficiary, _cursor, _count, _answer);
    }

    /** @dev Gives the ruling for a dispute. Can only be called by the arbitrator.
     *  The purpose of this function is to ensure that the address calling it has the right to rule on the contract and to invert the ruling in the case a party loses from lack of appeal fees funding.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refuse to arbitrate".
     */
    function rule(uint256 _disputeID, uint256 _ruling) external override {
        uint256 finalAnswer = arbitrableStorage.processRuling(_disputeID, _ruling);
        uint256 questionID = arbitrableStorage.externalIDtoLocalID[_disputeID];
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
     *  @param _questionID The ID of the question.
     *  @param _evidence A link to evidence using its URI.
     */
    function submitEvidence(uint256 _questionID, string calldata _evidence) external {
        arbitrableStorage.submitEvidence(_questionID, _questionID, _evidence);
    }

    // ******************** //
    // *      Getters     * //
    // ******************** //

    /** @dev Returns the sum of withdrawable wei from appeal rounds. This function is O(n), where n is the number of rounds of the question. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  @param _questionID The ID of the associated question.
     *  @param _beneficiary The contributor for which to query.
     *  @param _answer The answer that pays the appeal fee.
     *  @return total The total amount of wei available to withdraw.
     */
    function getTotalWithdrawableAmount(
        uint256 _questionID, 
        address _beneficiary,
        uint256 _answer
    ) external view returns (uint256 total) {
        if (arbitrableStorage.disputes[_questionID].status != MultiOutcomeUpgradableArbitrable.Status.Resolved) return total;

        uint256 totalRounds = arbitrableStorage.disputes[_questionID].roundCounter;
        for (uint256 roundI; roundI < totalRounds; roundI++)
            total += arbitrableStorage.getWithdrawableAmount(_questionID, _beneficiary, roundI, _answer);
    }

    /** @dev Gets the total number of created questions.
     *  @return The number of created questions.
     */
    function getQuestionCount() public view returns (uint256) {
        return questions.length;
    }

    /** @dev Gets the number of rounds of the specific question.
     *  @param _questionID The ID of the question.
     *  @return The number of rounds.
     */
    function getNumberOfRounds(uint256 _questionID) public view returns (uint256) {
        return arbitrableStorage.getNumberOfRounds(_questionID);
    }

    /** @dev Gets the contributions made by a party for a given round of appeal of a question.
     *  @param _questionID The ID of the question.
     *  @param _round The position of the round.
     *  @param _contributor The address of the contributor.
     *  @param _answer The answer that pays the appeal fee.
     *  @return contribution made by _contributor.
     *  @return rulingContributions sum of all contributions to _ruling.
     */
    function getContribution(
        uint256 _questionID,
        uint256 _round,
        address _contributor,
        uint256 _answer
    ) public view returns (uint256 contribution, uint256 rulingContributions) {
        return arbitrableStorage.getContribution(_questionID, _round, _contributor, _answer);
    }

    /** @dev Gets the information on a round of a question.
     *  @param _questionID The ID of the question.
     *  @param _round The round to be queried.
     *  @return rulingFunded feeRewards appealCostPaid appealed The round information.
     */
    function getRoundInfo(uint256 _questionID, uint256 _round)
        public
        view
        returns (
        uint256 rulingFunded,
        uint256 feeRewards,
        uint256 appealCostPaid,
        bool appealed
        )
    {
        return arbitrableStorage.getRoundInfo(_questionID, _round);
    }
}