const hre = require('hardhat')
const { solidity } = require('ethereum-waffle')
const { use, expect } = require('chai')

const { getEmittedEvent } = require('../src/test-helpers')
const TransactionStatus = require('../src/entities/transaction-status')
const TransactionParty = require('../src/entities/transaction-party')
const DisputeRuling = require('../src/entities/dispute-ruling')

use(solidity)

const { BigNumber } = ethers

describe('MultipleArbitrableTransactionWithAppeals contract', async () => {
  const arbitrationFee = 20
  const arbitratorExtraData = '0x85'
  const appealTimeout = 100
  const feeTimeout = 100
  const timeoutPayment = 100
  const amount = 1000
  const sharedMultiplier = 5000
  const winnerMultiplier = 2000
  const loserMultiplier = 8000
  const metaEvidenceUri = 'https://kleros.io'
  const MULTIPLIER_DIVISOR = 10000

  let arbitrator
  let _governor
  let sender
  let receiver
  let other
  let crowdfunder1
  let crowdfunder2

  let senderAddress
  let receiverAddress

  let contract

  beforeEach('Setup contracts', async () => {
    ;[
      _governor,
      sender,
      receiver,
      other,
      crowdfunder1,
      crowdfunder2
    ] = await ethers.getSigners()
    senderAddress = await sender.getAddress()
    receiverAddress = await receiver.getAddress()

    const arbitratorArtifact = await hre.artifacts.readArtifact('EnhancedAppealableArbitrator')
    const Arbitrator = await ethers.getContractFactory(
      arbitratorArtifact.abi,
      arbitratorArtifact.bytecode
    )
    arbitrator = await Arbitrator.deploy(
      String(arbitrationFee),
      ethers.constants.AddressZero,
      arbitratorExtraData,
      appealTimeout
    )
    await arbitrator.deployed()
    // Make appeals go to the same arbitrator
    await arbitrator.changeArbitrator(arbitrator.address)

    contractArtifact = await hre.artifacts.readArtifact('MockEscrow')
    const MultipleArbitrableTransaction = await ethers.getContractFactory(
      contractArtifact.abi,
      contractArtifact.bytecode
    )
    contract = await MultipleArbitrableTransaction.deploy(
      arbitrator.address,
      arbitratorExtraData,
      feeTimeout,
      sharedMultiplier,
      winnerMultiplier,
      loserMultiplier
    )
    await contract.deployed()
  })

  describe('Disputes', () => {
    it('Should create dispute and execute ruling correctly, making the sender the winner', async () => {
      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      // Rule
      await giveFinalRulingHelper(disputeID, DisputeRuling.Sender)
      // Anyone can execute ruling
      const balancesBefore = await getBalances()
      const [_ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )
      const balancesAfter = await getBalances()

      expect(
        balancesBefore.sender.add(BigNumber.from(amount + arbitrationFee))
      ).to.equal(balancesAfter.sender, 'Sender was not rewarded correctly')
      expect(balancesBefore.receiver).to.equal(
        balancesAfter.receiver,
        'Receiver must not be rewarded'
      )

      const updatedHash = await contract.transactionHashes(transactionId - 1)
      const expectedHash = await contract.hashTransactionState(ruleTransaction)
      expect(updatedHash).to.equal(
        expectedHash,
        'Hash was not updated correctly'
      )
    })

    it('Should create dispute and execute ruling correctly, making the receiver the winner', async () => {
      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      // Rule
      await giveFinalRulingHelper(disputeID, DisputeRuling.Receiver)
      // Anyone can execute ruling
      const balancesBefore = await getBalances()
      const [_ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )
      const balancesAfter = await getBalances()

      expect(
        balancesBefore.receiver.add(BigNumber.from(amount + arbitrationFee))
      ).to.equal(balancesAfter.receiver, 'Receiver was not rewarded correctly')
      expect(balancesBefore.sender).to.equal(
        balancesAfter.sender,
        'Sender must not be rewarded'
      )

      const updatedHash = await contract.transactionHashes(transactionId - 1)
      const expectedHash = await contract.hashTransactionState(ruleTransaction)
      expect(updatedHash).to.equal(
        expectedHash,
        'Hash was not updated correctly'
      )
    })

    it('Should create dispute and execute ruling correctly when jurors refuse to rule', async () => {
      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      // Rule
      await giveFinalRulingHelper(disputeID, DisputeRuling.RefusedToRule)
      // Anyone can execute ruling
      const balancesBefore = await getBalances()
      const [_ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )
      const balancesAfter = await getBalances()

      expect(
        balancesBefore.receiver.add(
          BigNumber.from((amount + arbitrationFee) / 2)
        )
      ).to.equal(balancesAfter.receiver, 'Receiver was not rewarded correctly')
      expect(
        balancesBefore.sender.add(BigNumber.from((amount + arbitrationFee) / 2))
      ).to.equal(balancesAfter.sender, 'Sender was not rewarded correctly')

      const updatedHash = await contract.transactionHashes(transactionId - 1)
      const expectedHash = await contract.hashTransactionState(ruleTransaction)
      expect(updatedHash).to.equal(
        expectedHash,
        'Hash was not updated correctly'
      )
    })

    it('Should update Transaction state correctly when dispute is resolved', async () => {
      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      // Rule
      await giveFinalRulingHelper(disputeID, DisputeRuling.Sender)
      // Anyone can execute ruling
      const [ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )

      expect(ruleTransactionId).to.equal(
        transactionId,
        'Invalid transaction ID'
      )
      expect(ruleTransaction.status).to.equal(
        TransactionStatus.Resolved,
        'Invalid status'
      )
      expect(ruleTransaction.sender).to.equal(
        senderAddress,
        'Invalid sender address'
      )
      expect(ruleTransaction.receiver).to.equal(
        receiverAddress,
        'Invalid receiver address'
      )
      expect(ruleTransaction.amount).to.equal(0, 'Invalid transaction amount')
      expect(ruleTransaction.deadline).to.equal(
        transaction.deadline,
        'Wrong deadline'
      )
      expect(ruleTransaction.senderFee).to.equal(0, 'Invalid senderFee')
      expect(ruleTransaction.receiverFee).to.equal(0, 'Invalid receieverFee')

      const updatedHash = await contract.transactionHashes(transactionId - 1)
      const expectedHash = await contract.hashTransactionState(ruleTransaction)
      expect(updatedHash).to.equal(
        expectedHash,
        'Hash was not updated correctly'
      )
    })

    it('Should refund overpaid arbitration fees', async () => {
      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const gasPrice = 1000000000

      const balancesBefore = await getBalances()
      // Sender overpays fees
      const senderFeePromise = contract
        .connect(sender)
        .payArbitrationFeeBySender(transactionId, transaction, {
          value: arbitrationFee + 100,
          gasPrice: gasPrice
        })
      const senderFeeTx = await senderFeePromise
      const senderFeeReceipt = await senderFeeTx.wait()
      expect(senderFeePromise)
        .to.emit(contract, 'HasToPayFee')
        .withArgs(transactionId, TransactionParty.Receiver)
      const [senderFeeTransactionId, senderFeeTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        senderFeeReceipt
      ).args

      // Receiver overpays fees, dispute gets created and both parties get refunded
      const receiverFeePromise = contract
        .connect(receiver)
        .payArbitrationFeeByReceiver(
          senderFeeTransactionId,
          senderFeeTransaction,
          {
            value: arbitrationFee + 100,
            gasPrice: gasPrice
          }
        )
      const receiverFeeTx = await receiverFeePromise
      const receiverFeeReceipt = await receiverFeeTx.wait()
      const [
        receiverFeeTransactionId,
        receiverFeeTransaction
      ] = getEmittedEvent('TransactionStateUpdated', receiverFeeReceipt).args
      expect(receiverFeePromise)
        .to.emit(contract, 'Dispute')
        .withArgs(
          arbitrator.address,
          0,
          receiverFeeTransactionId,
          receiverFeeTransactionId
        )

      const balancesAfter = await getBalances()

      expect(balancesBefore.sender).to.equal(
        balancesAfter.sender
          .add(BigNumber.from(arbitrationFee))
          .add(senderFeeReceipt.gasUsed * gasPrice),
        'Sender was not refunded correctly'
      )
      expect(balancesBefore.receiver).to.equal(
        balancesAfter.receiver
          .add(BigNumber.from(arbitrationFee))
          .add(receiverFeeReceipt.gasUsed * gasPrice),
        'Receiver was not refunded correctly'
      )

      expect(receiverFeeTransaction.senderFee).to.equal(
        BigNumber.from(arbitrationFee),
        'Invalid senderFee'
      )
      expect(receiverFeeTransaction.receiverFee).to.equal(
        BigNumber.from(arbitrationFee),
        'Invalid receieverFee'
      )
    })

    it('Should reimburse the sender in case of timeout of the receiver', async () => {
      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      // Sender pays fees
      const senderFeePromise = contract
        .connect(sender)
        .payArbitrationFeeBySender(transactionId, transaction, {
          value: arbitrationFee
        })
      const senderFeeTx = await senderFeePromise
      const senderFeeReceipt = await senderFeeTx.wait()
      expect(senderFeePromise)
        .to.emit(contract, 'HasToPayFee')
        .withArgs(transactionId, TransactionParty.Receiver)
      const [senderFeeTransactionId, senderFeeTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        senderFeeReceipt
      ).args

      // feeTimeout for receiver passes and sender gets to claim amount and his fee.
      ethers.provider.send("evm_increaseTime", [feeTimeout + 1])

      const balancesBefore = await getBalances()
      // Anyone can execute the timeout
      const timeoutTx = await contract
        .connect(other)
        .timeOutBySender(senderFeeTransactionId, senderFeeTransaction)
      const timeoutReceipt = await timeoutTx.wait()
      const [timeoutTransactionId, timeoutTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        timeoutReceipt
      ).args
      const balancesAfter = await getBalances()

      expect(
        balancesBefore.sender.add(BigNumber.from(amount + arbitrationFee))
      ).to.equal(balancesAfter.sender, 'Sender was not reimbursed correctly')
      // Receiver must not be paid anything
      expect(balancesBefore.receiver).to.equal(
        balancesAfter.receiver,
        'Wrong receiver balance.'
      )

      // Receiver must not be allowed to pay his fees afterwards
      await expect(
        contract
          .connect(receiver)
          .payArbitrationFeeByReceiver(
            timeoutTransactionId,
            timeoutTransaction,
            { value: arbitrationFee }
          )
      ).to.be.revertedWith(
        'The transaction must not be executed.'
      )
    })

    it('Should pay the receiver in case of timeout of the sender', async () => {
      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      // Receiver pays fee
      const receiverFeePromise = contract
        .connect(receiver)
        .payArbitrationFeeByReceiver(transactionId, transaction, {
          value: arbitrationFee
        })
      const receiverFeeTx = await receiverFeePromise
      const receiverFeeReceipt = await receiverFeeTx.wait()
      expect(receiverFeePromise)
        .to.emit(contract, 'HasToPayFee')
        .withArgs(transactionId, TransactionParty.Sender)
      const [
        receiverFeeTransactionId,
        receiverFeeTransaction
      ] = getEmittedEvent('TransactionStateUpdated', receiverFeeReceipt).args

      // feeTimeout for sender passes and sender gets to claim amount and his fee.
      ethers.provider.send("evm_increaseTime", [feeTimeout + 1])
      const balancesBefore = await getBalances()
      // Anyone can execute the timeout
      const timeoutTx = await contract
        .connect(other)
        .timeOutByReceiver(receiverFeeTransactionId, receiverFeeTransaction)
      const timeoutReceipt = await timeoutTx.wait()
      const [timeoutTransactionId, timeoutTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        timeoutReceipt
      ).args
      const balancesAfter = await getBalances()

      expect(
        balancesBefore.receiver.add(BigNumber.from(amount + arbitrationFee))
      ).to.equal(balancesAfter.receiver, 'Receiver was not paid correctly')
      // Sender must not be paid anything
      expect(balancesBefore.sender).to.equal(
        balancesAfter.sender,
        'Wrong sender balance.'
      )

      // Sender must not be allowed to pay his fees afterwards
      await expect(
        contract
          .connect(sender)
          .payArbitrationFeeBySender(timeoutTransactionId, timeoutTransaction, {
            value: arbitrationFee
          })
      ).to.be.revertedWith(
        'The transaction must not be executed.'
      )
    })

    it(`"Shouldn't be allowed to execute the timeout before it's right (Sender)"`, async () => {
      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      await expect(
        contract.connect(other).timeOutBySender(transactionId, transaction)
      ).to.be.revertedWith('The transaction is not waiting on the receiver.')
      await expect(
        contract.connect(other).timeOutByReceiver(transactionId, transaction)
      ).to.be.revertedWith('The transaction is not waiting on the sender.')

      // Sender pays fees
      const senderFeePromise = contract
        .connect(sender)
        .payArbitrationFeeBySender(transactionId, transaction, {
          value: arbitrationFee
        })
      const senderFeeTx = await senderFeePromise
      const senderFeeReceipt = await senderFeeTx.wait()
      expect(senderFeePromise)
        .to.emit(contract, 'HasToPayFee')
        .withArgs(transactionId, TransactionParty.Receiver)
      const [senderFeeTransactionId, senderFeeTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        senderFeeReceipt
      ).args

      ethers.provider.send("evm_increaseTime", [feeTimeout / 2])
      await expect(
        contract
          .connect(other)
          .timeOutBySender(senderFeeTransactionId, senderFeeTransaction)
      ).to.be.revertedWith('Timeout has not passed yet.')
    })

    it(`"Shouldn't be allowed to execute the timeout before it's right (Receiver)"`, async () => {
      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      await expect(
        contract.connect(other).timeOutBySender(transactionId, transaction)
      ).to.be.revertedWith('The transaction is not waiting on the receiver.')
      await expect(
        contract.connect(other).timeOutByReceiver(transactionId, transaction)
      ).to.be.revertedWith('The transaction is not waiting on the sender.')

      // Receiver pays fees
      const receiverFeePromise = contract
        .connect(receiver)
        .payArbitrationFeeByReceiver(transactionId, transaction, {
          value: arbitrationFee
        })
      const receiverFeeTx = await receiverFeePromise
      const receiverFeeReceipt = await receiverFeeTx.wait()
      expect(receiverFeePromise)
        .to.emit(contract, 'HasToPayFee')
        .withArgs(transactionId, TransactionParty.Sender)
      const [
        receiverFeeTransactionId,
        receiverFeeTransaction
      ] = getEmittedEvent('TransactionStateUpdated', receiverFeeReceipt).args

      ethers.provider.send("evm_increaseTime", [feeTimeout / 2])
      await expect(
        contract
          .connect(other)
          .timeOutByReceiver(receiverFeeTransactionId, receiverFeeTransaction)
      ).to.be.revertedWith('Timeout has not passed yet.')
    })
  })

  describe('Evidence', () => {
    it('Should allow sender and receiver to submit evidence', async () => {
      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      await submitEvidenceHelper(
        transactionId,
        transaction,
        'ipfs:/evidence_001',
        sender
      )
      await submitEvidenceHelper(
        transactionId,
        transaction,
        'ipfs:/evidence_002',
        receiver
      )
      await submitEvidenceHelper(
        transactionId,
        transaction,
        'ipfs:/evidence_003',
        other
      ) // Not allowed

      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      await submitEvidenceHelper(
        disputeTransactionId,
        disputeTransaction,
        'ipfs:/evidence_004',
        sender
      )
      await submitEvidenceHelper(
        disputeTransactionId,
        disputeTransaction,
        'ipfs:/evidence_005',
        receiver
      )

      await giveFinalRulingHelper(disputeID, DisputeRuling.Sender)
      const [ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )
      await submitEvidenceHelper(
        ruleTransactionId,
        ruleTransaction,
        'ipfs:/evidence_006',
        sender
      ) // Not allowed
      await submitEvidenceHelper(
        ruleTransactionId,
        ruleTransaction,
        'ipfs:/evidence_007',
        receiver
      ) // Not allowed
    })
  })

  describe('Appeals', () => {
    it('Should revert funding of appeals when the right conditions are not met', async () => {
      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(transactionId, transaction, TransactionParty.None, {
            value: 100
          })
      ).to.be.revertedWith('No ongoing dispute to appeal.')
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(transactionId, transaction, TransactionParty.Sender, {
            value: 100
          })
      ).to.be.revertedWith('No ongoing dispute to appeal.')

      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(
            disputeTransactionId,
            disputeTransaction,
            TransactionParty.Sender,
            { value: 100 }
          )
      ).to.be.revertedWith('The specified dispute is not appealable.') // EnhancedAppealableArbitrator reverts

      // Rule against the receiver
      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      ethers.provider.send("evm_increaseTime", [appealTimeout / 2 + 1])
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(
            disputeTransactionId,
            disputeTransaction,
            TransactionParty.Receiver,
            { value: 100 }
          )
      ).to.be.revertedWith(
        'Not in loser\'s appeal period.'
      )

      ethers.provider.send("evm_increaseTime", [appealTimeout / 2 + 1])
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(
            disputeTransactionId,
            disputeTransaction,
            TransactionParty.Sender,
            { value: 100 }
          )
      ).to.be.revertedWith('Not in appeal period.')
    })

    it('Should handle appeal fees correctly while emitting the correct events', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR
      let paidFees
      let sideFunded
      let feeRewards
      let appealed

      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        _disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)

      // Round zero must be created but empty
      ;[
        paidFees,
        sideFunded,
        feeRewards,
        appealed
      ] = await contract.getRoundInfo(transactionId, 0)
      expect(paidFees[TransactionParty.None].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party None'
      )
      expect(paidFees[TransactionParty.Sender].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party Sender'
      )
      expect(paidFees[TransactionParty.Receiver].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party Receiver'
      )
      expect(sideFunded).to.be.equal(TransactionParty.None, 'Wrong sideFunded')
      expect(appealed).to.be.equal(false, 'Wrong round info: appealed')
      expect(feeRewards.toNumber()).to.be.equal(0, 'Wrong feeRewards')

      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // Fully fund the loser side
      const txPromise1 = contract
        .connect(crowdfunder1)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Receiver,
          { value: loserAppealFee }
        )
      const tx1 = await txPromise1
      const _receipt1 = await tx1.wait()
      expect(txPromise1)
        .to.emit(contract, 'AppealContribution')
        .withArgs(
          transactionId,
          TransactionParty.Receiver,
          await crowdfunder1.getAddress(),
          BigNumber.from(0),
          loserAppealFee
        )
      expect(txPromise1)
        .to.emit(contract, 'HasPaidAppealFee')
        .withArgs(transactionId, TransactionParty.Receiver, BigNumber.from(0))

      // Fully fund the winner side
      const txPromise2 = contract
        .connect(crowdfunder2)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Sender,
          {
            value: winnerAppealFee
          }
        )
      const tx2 = await txPromise2
      const _receipt2 = await tx2.wait()
      expect(txPromise2)
        .to.emit(contract, 'AppealContribution')
        .withArgs(
          transactionId,
          TransactionParty.Sender,
          await crowdfunder2.getAddress(),
          BigNumber.from(0),
          winnerAppealFee
        )
      expect(txPromise2)
        .to.emit(contract, 'HasPaidAppealFee')
        .withArgs(transactionId, TransactionParty.Sender, BigNumber.from(0))

      // Round zero must be updated correctly
      ;[
        paidFees,
        sideFunded,
        feeRewards,
        appealed
      ] = await contract.getRoundInfo(transactionId, 0)
      expect(paidFees[TransactionParty.None].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party None'
      )
      expect(paidFees[TransactionParty.Sender].toNumber()).to.be.equal(
        winnerAppealFee,
        'Wrong paidFee for party Sender'
      )
      expect(paidFees[TransactionParty.Receiver].toNumber()).to.be.equal(
        loserAppealFee,
        'Wrong paidFee for party Receiver'
      )
      expect(sideFunded).to.be.equal(TransactionParty.None, 'Wrong sideFunded')
      expect(appealed).to.be.equal(true, 'Wrong round info: appealed')
      expect(feeRewards.toNumber()).to.be.equal(
        winnerAppealFee + loserAppealFee - arbitrationFee,
        'Wrong feeRewards'
      )

      // Round one must be created but empty
      ;[
        paidFees,
        sideFunded,
        feeRewards,
        appealed
      ] = await contract.getRoundInfo(transactionId, 1)
      expect(paidFees[TransactionParty.None].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party None'
      )
      expect(paidFees[TransactionParty.Sender].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party Sender'
      )
      expect(paidFees[TransactionParty.Receiver].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party Receiver'
      )
      expect(sideFunded).to.be.equal(TransactionParty.None, 'Wrong sideFunded')
      expect(appealed).to.be.equal(false, 'Wrong round info: appealed')
      expect(feeRewards.toNumber()).to.be.equal(0, 'Wrong feeRewards')
    })

    it('Should handle appeal fees correctly while emitting the correct events (2)', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR
      const gasPrice = 1000000000
      let paidFees
      let sideFunded
      let feeRewards
      let appealed

      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        _disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // CROWDFUND THE RECEIVER SIDE
      // Partially fund the loser side
      const contribution1 = loserAppealFee / 2
      const txPromise1 = contract
        .connect(crowdfunder1)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Receiver,
          {
            value: contribution1
          }
        )
      const tx1 = await txPromise1
      await tx1.wait()
      expect(txPromise1)
        .to.emit(contract, 'AppealContribution')
        .withArgs(
          transactionId,
          TransactionParty.Receiver,
          await crowdfunder1.getAddress(),
          BigNumber.from(0),
          contribution1
        )
      // Round zero must be updated correctly
      ;[
        paidFees,
        sideFunded,
        feeRewards,
        appealed
      ] = await contract.getRoundInfo(transactionId, 0)
      expect(paidFees[TransactionParty.None].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party None'
      )
      expect(paidFees[TransactionParty.Sender].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party Sender'
      )
      expect(paidFees[TransactionParty.Receiver].toNumber()).to.be.equal(
        contribution1,
        'Wrong paidFee for party Receiver'
      )
      expect(sideFunded).to.be.equal(TransactionParty.None, 'Wrong sideFunded')
      expect(appealed).to.be.equal(false, 'Wrong round info: appealed')
      expect(feeRewards.toNumber()).to.be.equal(0, 'Wrong feeRewards')

      // Overpay fee and check if contributor is refunded
      const balanceBeforeContribution2 = await receiver.getBalance()
      const expectedContribution2 = loserAppealFee - contribution1
      const txPromise2 = contract
        .connect(receiver)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Receiver,
          {
            value: loserAppealFee,
            gasPrice: gasPrice
          }
        )
      const tx2 = await txPromise2
      const receipt2 = await tx2.wait()
      expect(txPromise2)
        .to.emit(contract, 'AppealContribution')
        .withArgs(
          transactionId,
          TransactionParty.Receiver,
          receiverAddress,
          BigNumber.from(0),
          expectedContribution2
        )
      expect(txPromise2)
        .to.emit(contract, 'HasPaidAppealFee')
        .withArgs(transactionId, TransactionParty.Receiver, BigNumber.from(0))
      // Contributor must be refunded correctly
      const balanceAfterContribution2 = await receiver.getBalance()
      expect(balanceBeforeContribution2).to.equal(
        balanceAfterContribution2
          .add(BigNumber.from(expectedContribution2))
          .add(receipt2.gasUsed * gasPrice),
        'Contributor was not refunded correctly'
      )
      // Round zero must be updated correctly
      ;[
        paidFees,
        sideFunded,
        feeRewards,
        appealed
      ] = await contract.getRoundInfo(transactionId, 0)
      expect(paidFees[TransactionParty.None].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party None'
      )
      expect(paidFees[TransactionParty.Sender].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party Sender'
      )
      expect(paidFees[TransactionParty.Receiver].toNumber()).to.be.equal(
        loserAppealFee,
        'Wrong paidFee for party Receiver'
      )
      expect(sideFunded).to.be.equal(
        TransactionParty.Receiver,
        'Wrong sideFunded'
      )
      expect(appealed).to.be.equal(false, 'Wrong round info: appealed')
      expect(feeRewards.toNumber()).to.be.equal(0, 'Wrong feeRewards')
      // The side is fully funded and new contributions must be reverted
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(
            transactionId,
            disputeTransaction,
            TransactionParty.Receiver,
            { value: loserAppealFee }
          )
      ).to.be.revertedWith('Appeal fee has already been paid.')

      // CROWDFUND THE SENDER SIDE
      // Partially fund the winner side
      const contribution3 = winnerAppealFee / 2
      const txPromise3 = contract
        .connect(crowdfunder2)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Sender,
          {
            value: contribution3
          }
        )
      const tx3 = await txPromise3
      await tx3.wait()
      expect(txPromise3)
        .to.emit(contract, 'AppealContribution')
        .withArgs(
          transactionId,
          TransactionParty.Sender,
          await crowdfunder2.getAddress(),
          BigNumber.from(0),
          contribution3
        )
      // Round zero must be updated correctly
      ;[
        paidFees,
        sideFunded,
        feeRewards,
        appealed
      ] = await contract.getRoundInfo(transactionId, 0)
      expect(paidFees[TransactionParty.None].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party None'
      )
      expect(paidFees[TransactionParty.Sender].toNumber()).to.be.equal(
        contribution3,
        'Wrong paidFee for party Sender'
      )
      expect(paidFees[TransactionParty.Receiver].toNumber()).to.be.equal(
        loserAppealFee,
        'Wrong paidFee for party Receiver'
      )
      expect(sideFunded).to.be.equal(
        TransactionParty.Receiver,
        'Wrong sideFunded'
      )
      expect(appealed).to.be.equal(false, 'Wrong round info: appealed')
      expect(feeRewards.toNumber()).to.be.equal(0, 'Wrong feeRewards')

      // Overpay fee and check if contributor is refunded
      const balanceBeforeContribution4 = await sender.getBalance()
      const expectedContribution4 = winnerAppealFee - contribution3
      const txPromise4 = contract
        .connect(sender)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Sender,
          {
            value: winnerAppealFee,
            gasPrice: gasPrice
          }
        )
      const tx4 = await txPromise4
      const receipt4 = await tx4.wait()
      expect(txPromise4)
        .to.emit(contract, 'AppealContribution')
        .withArgs(
          transactionId,
          TransactionParty.Sender,
          senderAddress,
          BigNumber.from(0),
          expectedContribution4
        )
      expect(txPromise4)
        .to.emit(contract, 'HasPaidAppealFee')
        .withArgs(transactionId, TransactionParty.Sender, BigNumber.from(0))
      // Contributor must be refunded correctly
      const balanceAfterContribution4 = await sender.getBalance()
      expect(balanceBeforeContribution4).to.equal(
        balanceAfterContribution4
          .add(BigNumber.from(expectedContribution4))
          .add(receipt4.gasUsed * gasPrice),
        'Contributor was not refunded correctly'
      )
      // Round zero must be updated correctly
      ;[
        paidFees,
        sideFunded,
        feeRewards,
        appealed
      ] = await contract.getRoundInfo(transactionId, 0)
      expect(paidFees[TransactionParty.None].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party None'
      )
      expect(paidFees[TransactionParty.Sender].toNumber()).to.be.equal(
        winnerAppealFee,
        'Wrong paidFee for party Sender'
      )
      expect(paidFees[TransactionParty.Receiver].toNumber()).to.be.equal(
        loserAppealFee,
        'Wrong paidFee for party Receiver'
      )
      expect(sideFunded).to.be.equal(TransactionParty.None, 'Wrong sideFunded')
      expect(appealed).to.be.equal(true, 'Wrong round info: appealed')
      expect(feeRewards.toNumber()).to.be.equal(
        loserAppealFee + winnerAppealFee - arbitrationFee,
        'Wrong feeRewards'
      )
    })

    it('Should change the ruling if loser paid appeal fee while winner did not', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR

      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        _disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      await giveRulingHelper(disputeID, DisputeRuling.Receiver)

      // Fully fund the loser side
      const tx1 = await contract
        .connect(crowdfunder1)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Sender,
          { value: loserAppealFee }
        )
      await tx1.wait()

      // Give final ruling and expect it to change
      ethers.provider.send("evm_increaseTime", [appealTimeout + 1])
      const [txPromise2, _tx2, _receipt2] = await giveRulingHelper(
        disputeID,
        DisputeRuling.Receiver
      )
      expect(txPromise2)
        .to.emit(contract, 'Ruling')
        .withArgs(arbitrator.address, disputeID, TransactionParty.Sender)
    })
  })

  describe('Withdrawals', () => {
    it('Should withdraw correct fees if dispute had winner/loser', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR

      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // Crowdfund the receiver side
      const contribution1 = loserAppealFee / 2
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder1,
        contribution1,
        TransactionParty.Receiver
      )

      const contribution2 = loserAppealFee - contribution1
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        receiver,
        contribution2,
        TransactionParty.Receiver
      )

      // Withdraw must be reverted at this point.
      await expect(
        contract
          .connect(crowdfunder1)
          .withdrawFeesAndRewards(
            await crowdfunder1.getAddress(),
            transactionId,
            disputeTransaction,
            0
          )
      ).to.be.revertedWith('Dispute not resolved.')
      await expect(
        contract
          .connect(crowdfunder1)
          .batchRoundWithdraw(
            await crowdfunder1.getAddress(),
            transactionId,
            disputeTransaction,
            0,
            0
          )
      ).to.be.revertedWith('Dispute not resolved.')

      // Crowdfund the sender side (crowdfunder1 funds both sides)
      const contribution3 = winnerAppealFee / 2
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder1,
        contribution3,
        TransactionParty.Sender
      )

      const contribution4 = winnerAppealFee - contribution3
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder2,
        contribution4 / 2,
        TransactionParty.Sender
      )
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder2,
        contribution4 / 2,
        TransactionParty.Sender
      )

      // Give and execute final ruling, then withdraw
      const appealDisputeID = await arbitrator.getAppealDisputeID(disputeID)
      await giveFinalRulingHelper(
        appealDisputeID,
        DisputeRuling.Sender,
        disputeID
      )
      const [_ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )

      const balancesBefore = await getBalances()
      await withdrawHelper(
        await crowdfunder1.getAddress(),
        transactionId,
        ruleTransaction,
        0,
        other
      )
      await withdrawHelper(
        await crowdfunder1.getAddress(),
        transactionId,
        ruleTransaction,
        0,
        other
      ) // Attempt to withdraw twice
      await withdrawHelper(
        await crowdfunder2.getAddress(),
        transactionId,
        ruleTransaction,
        0,
        other
      )
      await withdrawHelper(
        senderAddress,
        transactionId,
        ruleTransaction,
        0,
        other
      )
      await withdrawHelper(
        receiverAddress,
        transactionId,
        ruleTransaction,
        0,
        other
      )
      const balancesAfter = await getBalances()

      expect(balancesBefore.receiver).to.equal(
        balancesBefore.receiver,
        'Contributors of the loser side must not be rewarded'
      )
      expect(balancesAfter.sender).to.equal(
        balancesAfter.sender,
        'Non contributors must not be rewarded'
      )
      const [
        paidFees,
        _sideFunded,
        feeRewards,
        _appealed
      ] = await contract.getRoundInfo(transactionId, 0)
      const reward3 = BigNumber.from(contribution3)
        .mul(feeRewards)
        .div(paidFees[TransactionParty.Sender])
      expect(balancesBefore.crowdfunder1.add(reward3)).to.equal(
        balancesAfter.crowdfunder1,
        'Contributor 1 was not rewarded correctly'
      )

      const reward4 = BigNumber.from(contribution4)
        .mul(feeRewards)
        .div(paidFees[TransactionParty.Sender])
      expect(balancesBefore.crowdfunder2.add(reward4)).to.equal(
        balancesAfter.crowdfunder2,
        'Contributor 2 was not rewarded correctly'
      )
    })

    it('Should withdraw correct fees if arbitrator refused to arbitrate', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR

      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // Crowdfund the receiver side
      const contribution1 = loserAppealFee / 2
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder1,
        contribution1,
        TransactionParty.Receiver
      )

      const contribution2 = loserAppealFee - contribution1
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        receiver,
        contribution2,
        TransactionParty.Receiver
      )

      // Crowdfund the sender side (crowdfunder1 funds both sides)
      const contribution3 = winnerAppealFee / 2
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder1,
        contribution3,
        TransactionParty.Sender
      )

      const contribution4 = winnerAppealFee - contribution3
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder2,
        contribution4 / 2,
        TransactionParty.Sender
      )
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder2,
        contribution4 / 2,
        TransactionParty.Sender
      )

      // Give and execute final ruling, then withdraw
      const appealDisputeID = await arbitrator.getAppealDisputeID(disputeID)
      await giveFinalRulingHelper(
        appealDisputeID,
        DisputeRuling.RefusedToRule,
        disputeID
      )
      const [_ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )

      const balancesBefore = await getBalances()
      await withdrawHelper(
        await crowdfunder1.getAddress(),
        transactionId,
        ruleTransaction,
        0,
        other
      )
      await withdrawHelper(
        await crowdfunder1.getAddress(),
        transactionId,
        ruleTransaction,
        0,
        other
      ) // Attempt to withdraw twice
      await withdrawHelper(
        await crowdfunder2.getAddress(),
        transactionId,
        ruleTransaction,
        0,
        other
      )
      await withdrawHelper(
        senderAddress,
        transactionId,
        ruleTransaction,
        0,
        other
      )
      await withdrawHelper(
        receiverAddress,
        transactionId,
        ruleTransaction,
        0,
        other
      )
      const balancesAfter = await getBalances()

      expect(balancesBefore.sender).to.equal(
        balancesAfter.sender,
        'Non contributors must not be rewarded'
      )
      const [
        paidFees,
        _sideFunded,
        feeRewards,
        _appealed
      ] = await contract.getRoundInfo(transactionId, 0)
      const totalFeesPaid = paidFees[TransactionParty.Sender].add(
        paidFees[TransactionParty.Receiver]
      )

      const reward2 = BigNumber.from(contribution2)
        .mul(feeRewards)
        .div(totalFeesPaid)
      expect(balancesBefore.receiver.add(reward2)).to.equal(
        balancesAfter.receiver,
        'Contributor was not rewarded correctly (2)'
      )

      const reward3 = BigNumber.from(contribution1 + contribution3)
        .mul(feeRewards)
        .div(totalFeesPaid)
      expect(balancesBefore.crowdfunder1.add(reward3)).to.equal(
        balancesAfter.crowdfunder1,
        'Contributor was not rewarded correctly (3)'
      )

      const reward4 = BigNumber.from(contribution4)
        .mul(feeRewards)
        .div(totalFeesPaid)
      expect(balancesBefore.crowdfunder2.add(reward4)).to.equal(
        balancesAfter.crowdfunder2,
        'Contributor was not rewarded correctly (4)'
      )
    })

    it('Should allow many rounds and batch-withdraw the fees after the final ruling', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR
      const roundsLength = 4
      const winnerSide = TransactionParty.Sender

      const [
        _receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)

      let roundDisputeID
      roundDisputeID = disputeID
      for (var roundI = 0; roundI < roundsLength; roundI += 1) {
        await giveRulingHelper(roundDisputeID, DisputeRuling.Sender)
        // Fully fund both sides
        await fundAppealHelper(
          transactionId,
          disputeTransaction,
          crowdfunder1,
          loserAppealFee,
          TransactionParty.Receiver
        )
        await fundAppealHelper(
          transactionId,
          disputeTransaction,
          crowdfunder2,
          winnerAppealFee,
          winnerSide
        )
        roundDisputeID = await arbitrator.getAppealDisputeID(disputeID)
      }

      // Give and execute final ruling
      await giveFinalRulingHelper(
        roundDisputeID,
        DisputeRuling.Sender,
        disputeID
      )
      const [_ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )

      // Batch-withdraw (checking if _cursor and _count arguments are working as expected).
      const balancesBefore = await getBalances()
      const amountWithdrawable1 = await contract.amountWithdrawable(
        transactionId,
        ruleTransaction,
        await crowdfunder1.getAddress()
      )
      const amountWithdrawable2 = await contract.amountWithdrawable(
        transactionId,
        ruleTransaction,
        await crowdfunder2.getAddress()
      )

      const tx1 = await contract
        .connect(other)
        .batchRoundWithdraw(
          await crowdfunder1.getAddress(),
          transactionId,
          ruleTransaction,
          0,
          0
        )
      await tx1.wait()
      const tx2 = await contract
        .connect(other)
        .batchRoundWithdraw(
          await crowdfunder2.getAddress(),
          transactionId,
          ruleTransaction,
          0,
          2
        )
      await tx2.wait()
      const tx3 = await contract
        .connect(other)
        .batchRoundWithdraw(
          await crowdfunder2.getAddress(),
          transactionId,
          ruleTransaction,
          0,
          10
        )
      await tx3.wait()

      const balancesAfter = await getBalances()

      expect(amountWithdrawable1).to.equal(
        BigNumber.from(0),
        'Wrong amount withdrawable'
      )
      expect(balancesBefore.crowdfunder1).to.equal(
        balancesAfter.crowdfunder1,
        'Losers must not be rewarded.'
      )

      // In this case all rounds have equal fees and rewards to simplify calculations
      const [
        paidFees,
        _sideFunded,
        feeRewards,
        _appealed
      ] = await contract.getRoundInfo(transactionId, 0)

      const roundReward = BigNumber.from(winnerAppealFee)
        .mul(feeRewards)
        .div(paidFees[winnerSide])
      const totalReward = roundReward.mul(BigNumber.from(roundsLength))

      expect(balancesBefore.crowdfunder2.add(totalReward)).to.equal(
        balancesAfter.crowdfunder2,
        'Contributor was not rewarded correctly'
      )

      expect(amountWithdrawable2).to.equal(
        BigNumber.from(totalReward),
        'Wrong withdrawable amount'
      )
    })
  })

  /**
   * Creates a transaction by sender to receiver.
   * @param {number} _amount Amount in wei.
   * @returns {Array} Tx data.
   */
  async function createTransactionHelper(_amount) {
    const metaEvidence = metaEvidenceUri

    const tx = await contract
      .connect(sender)
      .createTransaction(timeoutPayment, receiverAddress, metaEvidence, {
        value: _amount
      })
    const receipt = await tx.wait()
    const [transactionId, transaction] = getEmittedEvent(
      'TransactionStateUpdated',
      receipt
    ).args

    return [receipt, transactionId, transaction]
  }

  /**
   * Make both sides pay arbitration fees. The transaction should have been previosuly created.
   * @param {number} _transactionId Id of the transaction.
   * @param {object} _transaction Current transaction object.
   * @param {number} fee Appeal round from which to withdraw the rewards.
   * @returns {Array} Tx data.
   */
  async function createDisputeHelper(
    _transactionId,
    _transaction,
    fee = arbitrationFee
  ) {
    // Pay fees, create dispute and validate events.
    const receiverTxPromise = contract
      .connect(receiver)
      .payArbitrationFeeByReceiver(_transactionId, _transaction, {
        value: fee
      })
    const receiverFeeTx = await receiverTxPromise
    const receiverFeeReceipt = await receiverFeeTx.wait()
    expect(receiverTxPromise)
      .to.emit(contract, 'HasToPayFee')
      .withArgs(_transactionId, TransactionParty.Sender)
    const [receiverFeeTransactionId, receiverFeeTransaction] = getEmittedEvent(
      'TransactionStateUpdated',
      receiverFeeReceipt
    ).args
    const txPromise = contract
      .connect(sender)
      .payArbitrationFeeBySender(
        receiverFeeTransactionId,
        receiverFeeTransaction,
        {
          value: fee
        }
      )
    const senderFeeTx = await txPromise
    const senderFeeReceipt = await senderFeeTx.wait()
    const [senderFeeTransactionId, senderFeeTransaction] = getEmittedEvent(
      'TransactionStateUpdated',
      senderFeeReceipt
    ).args
    expect(txPromise)
      .to.emit(contract, 'Dispute')
      .withArgs(
        arbitrator.address,
        0,
        senderFeeTransactionId,
        senderFeeTransactionId
      )
    expect(senderFeeTransaction.status).to.equal(
      TransactionStatus.Ongoing,
      'Invalid transaction status'
    )
    return [
      0,
      senderFeeTransactionId,
      senderFeeTransaction
    ]
  }

  /**
   * Submit evidence related to a given transaction.
   * @param {number} transactionId Id of the transaction.
   * @param {object} transaction Current transaction object.
   * @param {string} evidence Link to evidence.
   * @param {address} caller Can only be called by the sender or the receiver.
   */
  async function submitEvidenceHelper(
    transactionId,
    transaction,
    evidence,
    caller
  ) {
    const callerAddress = await caller.getAddress()
    if (
      callerAddress === transaction.sender ||
      callerAddress === transaction.receiver
    )
      if (transaction.status !== TransactionStatus.Resolved) {
        const txPromise = contract
          .connect(caller)
          .submitEvidence(transactionId, transaction, evidence)
        const tx = await txPromise
        await tx.wait()
        expect(txPromise)
          .to.emit(contract, 'Evidence')
          .withArgs(arbitrator.address, transactionId, callerAddress, evidence)
      } else {
        await expect(
          contract
            .connect(caller)
            .submitEvidence(transactionId, transaction, evidence)
        ).to.be.revertedWith(
          'Must not send evidence if the dispute is resolved.'
        )
      }
    else
      await expect(
        contract
          .connect(caller)
          .submitEvidence(transactionId, transaction, evidence)
      ).to.be.revertedWith('The caller must be the sender or the receiver.')
  }

  /**
   * Give ruling (not final).
   * @param {number} disputeID dispute ID.
   * @param {number} ruling Ruling: None, Sender or Receiver.
   * @returns {Array} Tx data.
   */
  async function giveRulingHelper(disputeID, ruling) {
    // Notice that rule() function is not called by the arbitrator, because the dispute is appealable.
    const txPromise = arbitrator.giveRuling(disputeID, ruling)
    const tx = await txPromise
    const receipt = await tx.wait()

    return [txPromise, tx, receipt]
  }

  /**
   * Give final ruling and enforce it.
   * @param {number} disputeID dispute ID.
   * @param {number} ruling Ruling: None, Sender or Receiver.
   * @param {number} transactionDisputeId Initial dispute ID.
   * @returns {Array} Random integer in the range (0, max].
   */
  async function giveFinalRulingHelper(
    disputeID,
    ruling,
    transactionDisputeId = disputeID
  ) {
    const firstTx = await arbitrator.giveRuling(disputeID, ruling)
    await firstTx.wait()

    ethers.provider.send("evm_increaseTime", [appealTimeout + 1])

    const txPromise = arbitrator.giveRuling(disputeID, ruling)
    const tx = await txPromise
    const receipt = await tx.wait()

    expect(txPromise)
      .to.emit(contract, 'Ruling')
      .withArgs(arbitrator.address, transactionDisputeId, ruling)

    return [txPromise, tx, receipt]
  }

  /**
   * Execute the final ruling.
   * @param {number} transactionId Id of the transaction.
   * @param {object} transaction Current transaction object.
   * @param {address} caller Can be anyone.
   * @returns {Array} Transaction ID and the updated object.
   */
  async function executeRulingHelper(transactionId, transaction, caller) {
    const tx = await contract
      .connect(caller)
      .executeRuling(transactionId, transaction)
    const receipt = await tx.wait()
    const [newTransactionId, newTransaction] = getEmittedEvent(
      'TransactionStateUpdated',
      receipt
    ).args

    return [newTransactionId, newTransaction]
  }

  /**
   * Fund new appeal round.
   * @param {number} transactionId Id of the transaction.
   * @param {object} transaction Current transaction object.
   * @param {address} caller Can be anyone.
   * @param {number} contribution Contribution amount in wei.
   * @param {number} side Side to contribute to: Sender or Receiver.
   * @returns {Array} Tx data.
   */
  async function fundAppealHelper(
    transactionId,
    transaction,
    caller,
    contribution,
    side
  ) {
    const txPromise = contract
      .connect(caller)
      .fundAppeal(transactionId, transaction, side, { value: contribution })
    const tx = await txPromise
    const receipt = await tx.wait()

    return [txPromise, tx, receipt]
  }

  /**
   * Withdraw rewards to beneficiary.
   * @param {address} beneficiary Address of the round contributor.
   * @param {number} transactionId Id of the transaction.
   * @param {object} transaction Current transaction object.
   * @param {number} round Appeal round from which to withdraw the rewards.
   * @param {address} caller Can be anyone.
   * @returns {Array} Tx data.
   */
  async function withdrawHelper(
    beneficiary,
    transactionId,
    transaction,
    round,
    caller
  ) {
    const txPromise = contract
      .connect(caller)
      .withdrawFeesAndRewards(beneficiary, transactionId, transaction, round)
    const tx = await txPromise
    const receipt = await tx.wait()

    return [txPromise, tx, receipt]
  }

  /**
   * Get wei balances of accounts and contract.
   * @returns {object} Balances.
   */
  async function getBalances() {
    const balances = {
      sender: await sender.getBalance(),
      receiver: await receiver.getBalance(),
      contract: await ethers.provider.getBalance(contract.address),
      crowdfunder1: await crowdfunder1.getBalance(),
      crowdfunder2: await crowdfunder2.getBalance()
    }
    return balances
  }
})
