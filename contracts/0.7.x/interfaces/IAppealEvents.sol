/**
 *  @authors: [@fnanni-0]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity >=0.7;


/**
 *  @title Interface that is implemented on resolve.kleros.io
 *  Sets a standard arbitrable contract implementation to provide a general purpose user interface.
 */
interface IAppealEvents {


    /** @dev To be emitted when the appeal fees of one of the parties are fully funded.
     *  @param _itemID The ID of the respective transaction.
     *  @param _ruling The ruling that is fully funded.
     *  @param _round The appeal round fully funded by _party. Starts from 0.
     */
    event HasPaidAppealFee(uint256 indexed _itemID, uint256 _ruling, uint256 _round);

    /**
     *  @dev To be emitted when someone contributes to the appeal process.
     *  @param _itemID The ID of the respective transaction.
     *  @param _ruling The ruling which received the contribution.
     *  @param _contributor The address of the contributor.
     *  @param _round The appeal round to which the contribution is going. Starts from 0.
     *  @param _amount The amount contributed.
     */
    event AppealContribution(uint256 indexed _itemID, uint256 _ruling, address indexed _contributor, uint256 _round, uint256 _amount);

}