<p align="center"><img width="15%" src="./assets/images/logo-kleros.svg"></p>

<div align="center">
  <h4>
    <a href="https://kleros.io/">
      Kleros
    </a>
    <span> | </span>
    <a href="https://developer.kleros.io/en/latest/index.html">
      Documentation
    </a>
    <span> | </span>
    <a href="https://kleros.slack.com/archives/C65N18PT3">
      Slack
    </a>
  </h4>
</div>

# Overview

Create dispute. Wait for ruling. Appeal. Enforce final ruling. Make justice.

Here you are going to find solidity libraries that help you create arbitrable contracts compliant with erc-792 and erc-1497 standards in a glimpse.  

# Getting started

If you haven't already, we recommend you to go through the [ERC-792 Arbitration Standard docs](https://developer.kleros.io/en/latest/index.html). Even though libraries in this repo abstract most of the arbitration related interactions, you will need to know some of the features and the vocabulary introduced by the standard to properly understand what is going on.

There is not a single way to implement arbitrable contracts. For this reason, we provide opinionated libraries that suit different use cases. At the moment you can find:
- [BinaryArbitrable](https://github.com/kleros/appeal-utils/blob/main/contracts/0.7.x/libraries/Binary) for disputes in which there are only two parties involved (or two possible rulings).
- [MultiOutcome](https://github.com/kleros/appeal-utils/blob/main/contracts/0.7.x/libraries/MultiOutcome) for disputes in which support for more complex ruling options is needed.

# Implementing an appealable arbitrable contract

> :warning: **WARNING:** Smart contracts in this tutorial are not intended for production but educational purposes. Beware of using them on the main network.

Let's rewrite this [Escrow](https://developer.kleros.io/en/latest/implementing-an-arbitrable.html) contract using the [BinaryArbitrable](https://github.com/kleros/appeal-utils/blob/main/contracts/0.7.x/libraries/Binary/BinaryArbitrable.sol) library. We are going to see how to easily:
- handle the entire arbitration cycle.
- let users submit evidence.
- add support for appeals which can be crowdfunded.
- let appeal funders withdraw their rewards if they funded the winning side.
- add getters to keep track of the appeal status of disputes.

### Arbitration cycle

In order to make the SimpleEscrow contract arbitrable we need to be able to (1) store and update data related to arbitration, such as the arbitrator address, the dispute ID or the dispute status, (2) create a dispute and (3) let the arbitrator enforce a ruling.

Let's start by importing the BinaryArbitrable library and using it to give super powers to the variable `arbitrableStorage`:

```js
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
```

Notice that `arbitrator`, `numberOfRulingOptions` and `RulingOptions` are taken care of inside the library. We define the transaction ID (`TX_ID`) and the MetaEvidence ID (`META_EVIDENCE_ID`) as constants, because the contract only handles a single transaction.

From now on, every time we interact with the arbitrator we will do so through `arbitrableStorage`. However, before we start doing so, `arbitrableStorage` needs to be set up:

```js
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
```

First, we set the arbitrator data: its address and the extra data if needed. Second, we set the multipliers. The multipliers are only used during appeals. If you set them to values higher than zero, the cost of appealing is going to be adjusted depending on whether you are funding the loser's or the winner's side. More on that later.

Let's adapt `reclaimFunds()` now:

```js
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
```

We can access the dispute data of the transaction by reading its ItemData. This informations is stored in the items mapping by the id we have provided (`TX_ID`). Above we check that the transaction was not disputed. 

We are ready to create disputes now. If the `payer` reclaimed the funds, by sending the cost of arbitration to the contract, the `payee` can ask for arbitration: 

```js
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
```

Lastly, we need to adapt `rule()` in order to let the arbitrator enforce a ruling.

```js
    function rule(uint256 _disputeID, uint256 _ruling) public override {
        BinaryArbitrable.Party _finalRuling = arbitrableStorage.processRuling(_disputeID, _ruling);

        if (_finalRuling == BinaryArbitrable.Party.Requester) payer.send(address(this).balance);
        else if (_finalRuling == BinaryArbitrable.Party.Respondent) payee.send(address(this).balance);

        status = Status.Resolved;
    }
```

All the important sanity checks and the emission of the `Ruling` event is done inside `processRuling()`. Beware that `_ruling` and `_finalRuling` can difer if appeals were funded.

### Evidence

TODO.

### Crowdfunded appeals

TODO.

### Withdrawal of appeal rewards

TODO.

### Getters

TODO.



# Contribute

TODO.
