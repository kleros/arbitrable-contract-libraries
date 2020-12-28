/**
 *  @authors: [@fnanni-0]
 *  @reviewers: [@epiqueras]
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity >=0.7;

interface IAppealEvents {

    /** @dev To be emitted when the appeal fees of one of the parties are fully funded.
     *  @param _localDisputeID The dispute ID as defined in the arbitrable contract.
     *  @param _round The appeal round fully funded for _ruling. Starts from 0.
     *  @param _ruling Indicates the ruling option which got fully funded.
     */
    event HasPaidAppealFee(uint256 indexed _localDisputeID, uint256 _round, uint256 indexed _ruling);

    /**
     *  @dev To be emitted when someone contributes to the appeal process.
     *  @param _localDisputeID The dispute ID as defined in the arbitrable contract.
     *  @param _round The appeal round to which the contribution is going. Starts from 0.
     *  @param _ruling Indicates the ruling option which got the contribution.
     *  @param _contributor The address contributing.
     *  @param _amount The amount contributed.
     */
    event AppealContribution(uint256 indexed _localDisputeID, uint256 _round, uint256 indexed _ruling, address indexed _contributor, uint256 _amount);

    /** @dev Raised for withdrawals of appeal contribution rewards.
     *  @param _localDisputeID The dispute ID as defined in the arbitrable contract.
     *  @param _round The appeal round from which rewards are withdrawn. Starts from 0.
     *  @param _ruling Indicates the ruling option which got the contribution.
     *  @param _contributor The address contributing.
     *  @param _reward Total amount of deposits reimbursed plus rewards.
     */
    event Withdrawal(uint256 indexed _localDisputeID, uint256 indexed _round, uint256 _ruling, address indexed _contributor, uint256 _reward);
}