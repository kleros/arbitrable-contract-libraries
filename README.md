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

Here you are going to find solidity libraries that help you create arbitrable contracts compliant with ERC-792 and ERC-1497 standards in a glimpse.  

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
- let appeal funders withdraw their rewards if they funded the winning ruling.
- add getters to keep track of the appeal status of disputes.

You can find the finished sample contract [here](https://github.com/kleros/appeal-utils/blob/main/contracts/0.7.x/libraries/Binary/SimpleEscrow.sol).

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

    enum RulingOptions {RefusedToArbitrate, PayerWins, PayeeWins}
    enum Status {Initial, Reclaimed, Resolved}
    Status public status;

    uint256 public reclaimedAt;
```

To begin with, make sure your arbitrable contract inherits from IArbitrable, IEvidence and IAppealEvents. Even though the library takes care of emitting some of the events defined in the interfaces, Solidity requires events to be defined both in the library and in the contract using the library.

Notice that `arbitrator` and `numberOfRulingOptions` are taken care of inside the library. We define the transaction ID (`TX_ID`) and the MetaEvidence ID (`META_EVIDENCE_ID`) as constants, because this contract only handles a single transaction.

From now on, every time we interact with the arbitrator, we will do so through `arbitrableStorage`. As we will see, we won't have to worry about managing the dispute data. The library will manage it for us. However, before we start, `arbitrableStorage` needs to be set up:

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

First, we set the arbitrator data: its address and the extra data if needed. Beware that this library is designed taking into account that the arbitrator **won't** change. If you need such flexibility, either deploy new contracts for each arbitrator or consider modifying the library to safely handle changes in arbitrator's data.

Second, we set the multipliers. The multipliers are only used during appeals. If you set them to values higher than zero, the cost of appealing is going to be adjusted depending on whether you are funding the loser's or the winner's ruling. More on that later.

Let's adapt `reclaimFunds()` now:

```js
    function reclaimFunds() public payable {
        BinaryArbitrable.Status disputeStatus = arbitrableStorage.items[TX_ID].status;
        require(disputeStatus == BinaryArbitrable.Status.None, "Dispute has already been created.");
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

We can access the dispute data of the transaction by reading its ItemData. This information is stored in the items mapping by the id we have provided (`TX_ID`). Above we check that the transaction was not disputed. 

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

While creating the dispute, the library will update all necesary information and emit the `Dispute` event as defined in the ERC-792 standard.

Lastly, we need to update `rule()` in order to let the arbitrator enforce a ruling.

```js
    function rule(uint256 _disputeID, uint256 _ruling) public override {
        RulingOptions _finalRuling = RulingOptions(arbitrableStorage.processRuling(_disputeID, _ruling));

        if (_finalRuling == RulingOptions.PayerWins) payer.send(address(this).balance);
        else if (_finalRuling == RulingOptions.PayeeWins) payee.send(address(this).balance);

        status = Status.Resolved;
    }
```

All the important sanity checks and the emission of the `Ruling` event are done inside `processRuling()`. Beware that `_ruling` and `_finalRuling` can differ if appeals were funded.

### Evidence

In many cases, it is very important that parties in dispute are allowed to defend their positions by providing evidence to the jurors. We can add this feature with a few lines of code:

```js
    function submitEvidence(string calldata _evidence) external {
        require(msg.sender == payer || msg.sender == payee, "Invalid caller.");
        arbitrableStorage.submitEvidence(TX_ID, TX_ID, _evidence);
    }
```

For this use case, let's restrict the submission of evidence to the parties involved (payer and payee) and then we let the library do the rest. The `Evidence` event is going to be emitted, which will make the evidence visible to the arbitrator. It is assumed that evidence can only be submitted until the dispute is resolved.

### Crowdfunded appeals

One thing you might be wondering is what happens if the ruling given by the arbitrator does not feel right. At Kleros, we believe that allowing rulings to be appealable is an important feature that increases arbitration quality and makes it more robust against dishonest behaviors. 

If you decide to use an appealable arbitrator, you can easily add the appeal feature with a function like the following:

```js
    function fundAppeal(uint256 _ruling) external payable {
        arbitrableStorage.fundAppeal(TX_ID, _ruling);
    } 
```

What you have to be aware of:
- Because the library we are using only supports binary rulings, _ruling must be 1 or 2.
- The appeal is created only if both rulings get funded.
- The appeal can be crowdfunded, i.e. **anyone** can call `fundAppeal()` during the appeal period.
- If you want to make it more costly/risky for a ruling to get funded, you can set the multipliers (in the constructor in this case).
- If only one ruling is fully funded, then the appeal is not created and that ruling is considered the winner.
- There can be as many appeal rounds as the arbitrator allows.
- You don't have too worry about sanity checks or sending overpaid fees back. The library takes care of this.
- `AppealContribution` and `HasPaidAppealFee` events are emitted. Check them out in `fundAppeal()` and in [IAppealEvents](https://github.com/kleros/appeal-utils/blob/main/contracts/0.7.x/interfaces/IAppealEvents.sol).
- The arbitrator is only going to invoke `rule()` once the ruling is decisive, which means that all appeals are solved and it is not possible to continue appealing.
- Funding appeals is profitable to winning parties and crowdfunders.

### Withdrawal of appeal rewards

Crowdfunders who won are rewarded. How much they get will depend on the contribution made, the appeal cost, and the multipliers. If the arbitrator refuses tu rule, rewards are split equally and proportionally among all crowfunders.

In order to allow withdrawals we add the following:

```js
    function withdrawFeesAndRewards(address payable _beneficiary, uint256 _round) external {
        arbitrableStorage.withdrawFeesAndRewards(TX_ID, _beneficiary, _round);
    }
```

Withdrawals are performed per crowdfunder and is their responsibility to claim the rewards. `_beneficiary` is the crowdfunder address and `_round` the appeal round they contributed to. For the sake of efficiency and simplicity, we also provide a method to withdraw from many rounds at once:

```js
    function batchWithdrawFeesAndRewards(address payable _beneficiary, uint256 _cursor, uint256 _count) external {
        arbitrableStorage.batchWithdrawFeesAndRewards(TX_ID, _beneficiary, _cursor, _count);
    }
```

As stated in [BinaryArbitrable](https://github.com/kleros/appeal-utils/blob/main/contracts/0.7.x/libraries/Binary/BinaryArbitrable.sol):

```js
 /**
  *  ...
  *  @param _cursor The round from where to start withdrawing.
  *  @param _count The number of rounds to iterate. If set to 0 or a value larger than the number of rounds, iterates until the last round.
  */
```


### Getters

We are almost done! Let's finish our Escrow contract by adding some useful getters to track the status of the dispute and the corresponding appeals:

```js
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
        uint256 totalRounds = arbitrableStorage.items[TX_ID].rounds.length;
        for (uint256 roundI; roundI < totalRounds; roundI++)
            total += arbitrableStorage.getWithdrawableAmount(TX_ID, _beneficiary, roundI);
    }
```

And that’s it! We turned a very simple arbitrable escrow into a contract with complex arbitration features compliant with ERC-792 and ERC-1497.

# Contribute

Check out the [kleros gitbook](https://klerosio.gitbook.io/contributing-md/code-style-and-guidelines/solidity).

## Test

Run the following commands:

```sh
npm install
npx hardhat test
```
