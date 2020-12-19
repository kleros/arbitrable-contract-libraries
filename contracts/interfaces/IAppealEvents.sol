/**
 *  @authors: [@fnanni-0]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity >=0.7;

interface IAppealEvents {

    /** @dev To be emitted when the appeal fees of one of the parties are fully funded.
     *  @param _itemID The ID of the respective dispute.
     *  @param _round The appeal round fully funded by _ruling. Starts from 0.
     *  @param _ruling Indicates the ruling option which got fully funded.
     */
    event HasPaidAppealFee(uint256 indexed _itemID, uint256 _round, uint256 indexed _ruling);

    /**
     *  @dev To be emitted when someone contributes to the appeal process.
     *  @param _itemID The ID of the respective dispute.
     *  @param _round The appeal round to which the contribution is going. Starts from 0.
     *  @param _ruling Indicates the ruling option which got the contribution.
     *  @param _contributor Caller of fundAppeal function.
     *  @param _amount The amount contributed.
     */
    event AppealContribution(uint256 indexed _itemID, uint256 _round, uint256 indexed _ruling, address indexed _contributor, uint256 _amount);

    /** @dev To be raised inside withdrawFeesAndRewards function.
     *  @param _itemID The ID of the respective dispute.
     *  @param _round The appeal round to from which rewards are withdrawn. Starts from 0.
     *  @param _ruling Indicates the ruling option which got the contribution.
     *  @param _contributor Caller of fundAppeal function.
     *  @param _reward Total amount of deposits reimbursed plus rewards.
     */
    event Withdrawal(uint256 indexed _itemID, uint256 indexed _round, uint256 _ruling, address indexed _contributor, uint256 _reward);
}