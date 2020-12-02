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

Let's rewrite this [Escrow](https://developer.kleros.io/en/latest/implementing-an-arbitrable.html) contract using the [BinaryArbitrable](https://github.com/kleros/appeal-utils/blob/main/contracts/0.7.x/libraries/Binary/BinaryArbitrable.sol) library. We are going to see how to easily:
- handle the entire arbitration cycle.
- let users submit evidence.
- add support for appeals which can be crowdfunded.
- let appeal funders withdraw their rewards if they funded the winning side.
- add getters to keep track of the appeal status of disputes.

### Arbitration cycle

TODO.

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
