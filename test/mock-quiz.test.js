const hre = require('hardhat')
const { solidity } = require('ethereum-waffle')
const { use, expect } = require('chai')

const { latestTime } = require('../src/test-helpers')

use(solidity)

const { BigNumber } = ethers

describe('MockQuiz contract', async () => {
  const arbitrationFee = 20
  const arbitratorExtraData = '0x85'
  const appealTimeout = 100
  const submissionTimeout = 100
  const challengeTimeout = 100
  const amount = 1000
  const sharedMultiplier = 5000
  const winnerMultiplier = 2000
  const loserMultiplier = 8000
  const metaEvidenceUri = 'In what year was the bitcoin paper published?'
  const correctAnswer = BigNumber.from(2008)
  const correctEvidence = 'https://bitcoin.org/bitcoin.pdf'
  const wrongAnswer = BigNumber.from(1973)
  const MULTIPLIER_DIVISOR = 10000

  let arbitrator
  let _governor
  let host
  let guest
  let other
  let crowdfunder1
  let crowdfunder2

  let hostAddress
  let guestAddress

  let contract
  let currentTime

  beforeEach('Setup contracts', async () => {
    ;[
      _governor,
      host,
      guest,
      other,
      crowdfunder1,
      crowdfunder2
    ] = await ethers.getSigners()
    hostAddress = await host.getAddress()
    guestAddress = await guest.getAddress()

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

    contractArtifact = await hre.artifacts.readArtifact('MockQuiz')
    const MockQuiz = await ethers.getContractFactory(
      contractArtifact.abi,
      contractArtifact.bytecode
    )
    contract = await MockQuiz.deploy(
      arbitrator.address,
      arbitratorExtraData,
      challengeTimeout,
      sharedMultiplier,
      winnerMultiplier,
      loserMultiplier
    )
    await contract.deployed()

    currentTime = await latestTime()
  })

  describe('Disputes', () => {

    it('Should create dispute and execute ruling correctly, making the host the winner', async () => {
      const [
        _receipt,
        questionId
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      const exptectedDisputeID = 0
      await createDisputeHelper(questionId, exptectedDisputeID)
      // Rule
      const balancesBefore = await getBalances()
      await giveFinalRulingHelper(exptectedDisputeID, correctAnswer)
      const balancesAfter = await getBalances()

      expect(
        balancesBefore.host.add(BigNumber.from(amount + arbitrationFee))
      ).to.equal(balancesAfter.host, 'Host was not rewarded correctly')
      expect(balancesBefore.guest).to.equal(
        balancesAfter.guest,
        'Guest must not be rewarded'
      )
    })

    it('Should create dispute and execute ruling correctly, making the guest the winner', async () => {
      const [
        _receipt,
        questionId
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      const exptectedDisputeID = 0
      await createDisputeHelper(questionId, exptectedDisputeID)
      // Rule
      const balancesBefore = await getBalances()
      await giveFinalRulingHelper(exptectedDisputeID, wrongAnswer)
      const balancesAfter = await getBalances()

      expect(
        balancesBefore.guest.add(BigNumber.from(amount + arbitrationFee))
      ).to.equal(balancesAfter.guest, 'Guest was not rewarded correctly')
      expect(balancesBefore.host).to.equal(
        balancesAfter.host,
        'Host must not be rewarded'
      )
    })

    it('Should create dispute and execute ruling correctly when jurors rule against both parties', async () => {
      const [
        _receipt,
        questionId
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      const exptectedDisputeID = 0
      await createDisputeHelper(questionId, exptectedDisputeID)
      // Rule
      const balancesBefore = await getBalances()
      const randomRuling = BigNumber.from(123456789)
      await giveFinalRulingHelper(exptectedDisputeID, randomRuling)
      const balancesAfter = await getBalances()

      const splitAmount = BigNumber.from((amount + arbitrationFee) / 2)
      expect(
        balancesBefore.guest.add(splitAmount)
      ).to.equal(balancesAfter.guest, 'Guest was not rewarded correctly')
      expect(
        balancesBefore.host.add(splitAmount)
      ).to.equal(balancesAfter.host, 'Host was not rewarded correctly')
    })

    it('Should revert if createDispute is called more than once on the same item', async () => {
      const [
        _receipt,
        questionId
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      const exptectedDisputeID = 0
      await createDisputeHelper(questionId, exptectedDisputeID)

      // Challenge again
      await expect(contract
        .connect(host)
        .challengeAnswer(questionId, correctAnswer, correctEvidence, { value: arbitrationFee })
      ).to.be.revertedWith('Item already disputed.')
    })

    it('Should handle multiple dispute at the same', async () => {
      // Question 1
      const [
        _receipt1,
        questionId1
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      const exptectedDisputeID1 = 0
      await createDisputeHelper(questionId1, exptectedDisputeID1)

      // Question 2
      currentTime = await latestTime()
      const [
        _receipt2,
        questionId2
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      const exptectedDisputeID2 = 1
      await createDisputeHelper(questionId2, exptectedDisputeID2)

      // Rule 1
      await giveFinalRulingHelper(exptectedDisputeID1, correctAnswer)

      // Question 3
      currentTime = await latestTime()
      const [
        _receipt3,
        questionId3
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      const exptectedDisputeID3 = 2
      await createDisputeHelper(questionId3, exptectedDisputeID3)

      // Rule 3
      await giveFinalRulingHelper(exptectedDisputeID3, correctAnswer)
      // Rule 2
      await giveFinalRulingHelper(exptectedDisputeID2, correctAnswer)

    })
  })

  describe('Evidence', () => {
    it('Should allow host and guest to submit evidence', async () => {
      const [
        _receipt,
        questionId
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      await submitEvidenceHelper(questionId, 'ipfs:/evidence_001', host)
      await submitEvidenceHelper(questionId, 'ipfs:/evidence_002', guest)
      await submitEvidenceHelper(questionId, 'ipfs:/evidence_003', other)

      const exptectedDisputeID = 0
      await createDisputeHelper(questionId, exptectedDisputeID)
      await submitEvidenceHelper(questionId, 'ipfs:/evidence_004', host)
      await submitEvidenceHelper(questionId, 'ipfs:/evidence_005', guest)

      await giveFinalRulingHelper(exptectedDisputeID, correctAnswer)
      // Evidence submissions not allowed from now on
      await submitEvidenceHelper(questionId, 'ipfs:/evidence_006', host, isResolved = true) 
      await submitEvidenceHelper(questionId, 'ipfs:/evidence_007', guest, isResolved = true) 
    })
  })

  describe('Appeals', () => {
    it('Should revert funding of appeals when the right conditions are not met', async () => {
      const [
        _receipt,
        questionId
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(questionId, correctAnswer, { value: 100 })
      ).to.be.revertedWith('No ongoing dispute to appeal.')

      const exptectedDisputeID = 0
      await createDisputeHelper(questionId, exptectedDisputeID)
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(questionId, BigNumber.from(0), { value: 100 })
      ).to.be.revertedWith('Invalid ruling.')
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(questionId, correctAnswer, { value: 100 })
      ).to.be.revertedWith('The specified dispute is not appealable.') // EnhancedAppealableArbitrator reverts

      // Rule in favor of the correct answer (host's answer)
      await giveRulingHelper(exptectedDisputeID, correctAnswer)

      ethers.provider.send("evm_increaseTime", [appealTimeout / 2 + 1])
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(questionId, wrongAnswer, { value: 100 })
      ).to.be.revertedWith('Not in loser\'s appeal period.')
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(questionId, BigNumber.from(123456789), { value: 100 })
      ).to.be.revertedWith('Not in loser\'s appeal period.')

      ethers.provider.send("evm_increaseTime", [appealTimeout / 2 + 1])
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(questionId, correctAnswer, { value: 100 })
      ).to.be.revertedWith('Not in appeal period.')
    })

    it('Should handle appeal fees correctly while emitting the correct events', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR
      let paidFees
      let answersFunded
      let feeRewards
      let appealed

      const [
        _receipt,
        questionId
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      const exptectedDisputeID = 0
      await createDisputeHelper(questionId, exptectedDisputeID)

      // Round zero must be created but empty
      ;[
        paidFees,
        answersFunded,
        feeRewards,
        appealed
      ] = await contract.getRoundInfo(questionId, 0)
      expect(paidFees[0].toNumber()).to.be.equal(0, 'Wrong paidFee for ruling at position 0')
      expect(paidFees[1].toNumber()).to.be.equal(0, 'Wrong paidFee for ruling at position 1')
      expect(answersFunded[0]).to.be.equal(0, 'Wrong ruling funded')
      expect(answersFunded[1]).to.be.equal(0, 'Wrong ruling funded')
      expect(appealed).to.be.equal(false, 'Wrong round info: appealed')
      expect(feeRewards.toNumber()).to.be.equal(0, 'Wrong feeRewards')

      await giveRulingHelper(exptectedDisputeID, correctAnswer)

      // Fully fund the loser side
      const txPromise1 = contract
        .connect(crowdfunder1)
        .fundAppeal(questionId, wrongAnswer, { value: loserAppealFee })
      const tx1 = await txPromise1
      const _receipt1 = await tx1.wait()
      expect(txPromise1)
        .to.emit(contract, 'AppealContribution')
        .withArgs(
          questionId,
          BigNumber.from(0),
          wrongAnswer,
          await crowdfunder1.getAddress(),
          loserAppealFee
        )
      expect(txPromise1)
        .to.emit(contract, 'HasPaidAppealFee')
        .withArgs(questionId, BigNumber.from(0), wrongAnswer)

      // Fully fund the winner side
      const txPromise2 = contract
        .connect(crowdfunder2)
        .fundAppeal(questionId, correctAnswer, { value: winnerAppealFee })
      const tx2 = await txPromise2
      const _receipt2 = await tx2.wait()
      expect(txPromise2)
        .to.emit(contract, 'AppealContribution')
        .withArgs(
          questionId,
          BigNumber.from(0),
          correctAnswer,
          await crowdfunder2.getAddress(),
          winnerAppealFee
        )
      expect(txPromise2)
        .to.emit(contract, 'HasPaidAppealFee')
        .withArgs(questionId, BigNumber.from(0), correctAnswer)

      // Round zero must be updated correctly
      const totalRewards = winnerAppealFee + loserAppealFee - arbitrationFee
      ;[
        paidFees,
        answersFunded,
        feeRewards,
        appealed
      ] = await contract.getRoundInfo(questionId, 0)
      expect(paidFees[0].toNumber()).to.be.equal(loserAppealFee, 'Wrong paidFee for party Guest')
      expect(paidFees[1].toNumber()).to.be.equal(winnerAppealFee, 'Wrong paidFee for party Host')
      expect(answersFunded[0]).to.be.equal(wrongAnswer, 'Wrong ruling funded')
      expect(answersFunded[1]).to.be.equal(correctAnswer, 'Wrong ruling funded')
      expect(appealed).to.be.equal(true, 'Wrong round info: appealed')
      expect(feeRewards.toNumber()).to.be.equal(totalRewards, 'Wrong feeRewards')

      // Round one must be created but empty
      ;[
        paidFees,
        answersFunded,
        feeRewards,
        appealed
      ] = await contract.getRoundInfo(questionId, 1)
      expect(paidFees[0].toNumber()).to.be.equal(0, 'Wrong paidFee for ruling at position 0')
      expect(paidFees[1].toNumber()).to.be.equal(0, 'Wrong paidFee for ruling at position 1')
      expect(answersFunded[0]).to.be.equal(0, 'Wrong ruling funded')
      expect(answersFunded[1]).to.be.equal(0, 'Wrong ruling funded')
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
      let answersFunded
      let feeRewards
      let appealed

      const [
        _receipt,
        questionId
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      const exptectedDisputeID = 0
      await createDisputeHelper(questionId, exptectedDisputeID)
      await giveRulingHelper(exptectedDisputeID, correctAnswer)

      // CROWDFUND THE GUEST SIDE
      // Partially fund the loser side
      const contribution1 = loserAppealFee / 2
      const txPromise1 = contract
        .connect(crowdfunder1)
        .fundAppeal(questionId, wrongAnswer, { value: contribution1 })
      const tx1 = await txPromise1
      await tx1.wait()
      expect(txPromise1)
        .to.emit(contract, 'AppealContribution')
        .withArgs(
          questionId,
          BigNumber.from(0),
          wrongAnswer,
          await crowdfunder1.getAddress(),
          contribution1
        )
      // Round zero must be updated correctly
      ;[
        paidFees,
        answersFunded,
        feeRewards,
        appealed
      ] = await contract.getRoundInfo(questionId, 0)
      expect(paidFees[0].toNumber()).to.be.equal(0, 'Wrong paidFee for party Guest')
      expect(paidFees[1].toNumber()).to.be.equal(0, 'Wrong paidFee for party Host')
      expect(answersFunded[0]).to.be.equal(0, 'Wrong ruling funded')
      expect(answersFunded[1]).to.be.equal(0, 'Wrong ruling funded')
      expect(appealed).to.be.equal(false, 'Wrong round info: appealed')
      expect(feeRewards.toNumber()).to.be.equal(0, 'Wrong feeRewards')

      // Overpay fee and check if contributor is refunded
      const balanceBeforeContribution2 = await guest.getBalance()
      const expectedContribution2 = loserAppealFee - contribution1
      const txPromise2 = contract
        .connect(guest)
        .fundAppeal(questionId, wrongAnswer, { value: loserAppealFee, gasPrice: gasPrice })
      const tx2 = await txPromise2
      const receipt2 = await tx2.wait()
      expect(txPromise2)
        .to.emit(contract, 'AppealContribution')
        .withArgs(
          questionId,
          BigNumber.from(0),
          wrongAnswer,
          guestAddress,
          expectedContribution2
        )
      expect(txPromise2)
        .to.emit(contract, 'HasPaidAppealFee')
        .withArgs(questionId, BigNumber.from(0), wrongAnswer)
      // Contributor must be refunded correctly
      const balanceAfterContribution2 = await guest.getBalance()
      expect(balanceBeforeContribution2).to.equal(
        balanceAfterContribution2
          .add(BigNumber.from(expectedContribution2))
          .add(receipt2.gasUsed * gasPrice),
        'Contributor was not refunded correctly'
      )
      // Round zero must be updated correctly
      ;[
        paidFees,
        answersFunded,
        feeRewards,
        appealed
      ] = await contract.getRoundInfo(questionId, 0)
      expect(paidFees[0].toNumber()).to.be.equal(loserAppealFee, 'Wrong paidFee for party Guest')
      expect(paidFees[1].toNumber()).to.be.equal(0, 'Wrong paidFee for party Host')
      expect(answersFunded[0]).to.be.equal(wrongAnswer, 'Wrong ruling funded')
      expect(answersFunded[1]).to.be.equal(0, 'Wrong ruling funded')
      expect(appealed).to.be.equal(false, 'Wrong round info: appealed')
      expect(feeRewards.toNumber()).to.be.equal(0, 'Wrong feeRewards')

      // The side is fully funded and new contributions must be reverted
      await expect(
        contract
          .connect(crowdfunder2)
          .fundAppeal(questionId, wrongAnswer, { value: loserAppealFee })
      ).to.be.revertedWith('Appeal fee has already been paid.')

      // CROWDFUND THE HOST SIDE
      // Partially fund the winner side
      const contribution3 = winnerAppealFee / 2
      const txPromise3 = contract
        .connect(crowdfunder2)
        .fundAppeal(questionId, correctAnswer, { value: contribution3 })
      const tx3 = await txPromise3
      await tx3.wait()
      expect(txPromise3)
        .to.emit(contract, 'AppealContribution')
        .withArgs(
          questionId,
          BigNumber.from(0),
          correctAnswer,
          await crowdfunder2.getAddress(),
          contribution3
        )
      // Round zero must be updated correctly
      ;[
        paidFees,
        answersFunded,
        feeRewards,
        appealed
      ] = await contract.getRoundInfo(questionId, 0)
      expect(paidFees[0].toNumber()).to.be.equal(loserAppealFee, 'Wrong paidFee for party Guest')
      expect(paidFees[1].toNumber()).to.be.equal(0, 'Wrong paidFee for party Host')
      expect(answersFunded[0]).to.be.equal(wrongAnswer, 'Wrong ruling funded')
      expect(answersFunded[1]).to.be.equal(0, 'Wrong ruling funded')
      expect(appealed).to.be.equal(false, 'Wrong round info: appealed')
      expect(feeRewards.toNumber()).to.be.equal(0, 'Wrong feeRewards')

      // Overpay fee and check if contributor is refunded
      const balanceBeforeContribution4 = await host.getBalance()
      const expectedContribution4 = winnerAppealFee - contribution3
      const txPromise4 = contract
        .connect(host)
        .fundAppeal(questionId, correctAnswer, { value: winnerAppealFee, gasPrice: gasPrice })
      const tx4 = await txPromise4
      const receipt4 = await tx4.wait()
      expect(txPromise4)
        .to.emit(contract, 'AppealContribution')
        .withArgs(
          questionId,
          BigNumber.from(0),
          correctAnswer,
          hostAddress,
          expectedContribution4
        )
      expect(txPromise4)
        .to.emit(contract, 'HasPaidAppealFee')
        .withArgs(questionId, BigNumber.from(0), correctAnswer)
      // Contributor must be refunded correctly
      const balanceAfterContribution4 = await host.getBalance()
      expect(balanceBeforeContribution4).to.equal(
        balanceAfterContribution4
          .add(BigNumber.from(expectedContribution4))
          .add(receipt4.gasUsed * gasPrice),
        'Contributor was not refunded correctly'
      )
      // Round zero must be updated correctly
      const totalRewards = loserAppealFee + winnerAppealFee - arbitrationFee
      ;[
        paidFees,
        answersFunded,
        feeRewards,
        appealed
      ] = await contract.getRoundInfo(questionId, 0)
      expect(paidFees[0].toNumber()).to.be.equal(loserAppealFee, 'Wrong paidFee for party Guest')
      expect(paidFees[1].toNumber()).to.be.equal(winnerAppealFee, 'Wrong paidFee for party Host')
      expect(answersFunded[0]).to.be.equal(wrongAnswer, 'Wrong ruling funded')
      expect(answersFunded[1]).to.be.equal(correctAnswer, 'Wrong ruling funded')
      expect(appealed).to.be.equal(true, 'Wrong round info: appealed')
      expect(feeRewards.toNumber()).to.be.equal(totalRewards, 'Wrong feeRewards')
    })

    it('Should change the ruling if loser paid appeal fee while winner did not', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR

      
      const [
        _receipt,
        questionId
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      const exptectedDisputeID = 0
      await createDisputeHelper(questionId, exptectedDisputeID)
      await giveRulingHelper(exptectedDisputeID, wrongAnswer)

      // Fully fund the loser side
      const tx1 = await contract
        .connect(crowdfunder1)
        .fundAppeal(questionId, correctAnswer, { value: loserAppealFee })
      await tx1.wait()

      // Give final ruling and expect it to change
      ethers.provider.send("evm_increaseTime", [appealTimeout + 1])
      const [txPromise2, _tx2, _receipt2] = await giveRulingHelper(exptectedDisputeID, wrongAnswer)
      expect(txPromise2)
        .to.emit(contract, 'Ruling')
        .withArgs(arbitrator.address, exptectedDisputeID, correctAnswer)
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
        questionId
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      const exptectedDisputeID = 0
      await createDisputeHelper(questionId, exptectedDisputeID)
      await giveRulingHelper(exptectedDisputeID, correctAnswer)

      // Crowdfund the guest side
      const contribution1 = loserAppealFee / 2
      await fundAppealHelper(questionId, crowdfunder1, contribution1, wrongAnswer)

      const contribution2 = loserAppealFee - contribution1
      await fundAppealHelper(questionId, guest, contribution2, wrongAnswer)

      // Withdraw must be reverted at this point.
      await expect(
        contract
          .connect(crowdfunder1)
          .withdrawFeesAndRewards(await crowdfunder1.getAddress(), questionId, wrongAnswer, 0)
      ).to.be.revertedWith('Dispute not resolved.')
      await expect(
        contract
          .connect(crowdfunder1)
          .batchRoundWithdraw(await crowdfunder1.getAddress(), questionId, wrongAnswer, 0, 0)
      ).to.be.revertedWith('Dispute not resolved.')
      await expect(
        contract
          .connect(crowdfunder1)
          .withdrawMultipleRulings(await crowdfunder1.getAddress(), questionId, [correctAnswer, wrongAnswer], 0)
      ).to.be.revertedWith('Dispute not resolved.')

      // Crowdfund the host side (crowdfunder1 funds both sides)
      const contribution3 = winnerAppealFee / 2
      await fundAppealHelper(questionId, crowdfunder1, contribution3, correctAnswer)

      const contribution4 = winnerAppealFee - contribution3
      await fundAppealHelper(questionId, crowdfunder2, contribution4 / 2, correctAnswer)
      await fundAppealHelper(questionId, crowdfunder2, contribution4 / 2, correctAnswer)

      // Give and execute final ruling, then withdraw
      const appealDisputeID = await arbitrator.getAppealDisputeID(exptectedDisputeID)
      await giveFinalRulingHelper(appealDisputeID, correctAnswer, exptectedDisputeID)

      const balancesBefore = await getBalances()
      await withdrawHelper(await crowdfunder1.getAddress(), questionId, wrongAnswer, 0, other) // Should withdraw 0
      await withdrawHelper(await crowdfunder1.getAddress(), questionId, correctAnswer, 0, other)
      await withdrawHelper(await crowdfunder2.getAddress(), questionId, correctAnswer, 0, other)
      await withdrawHelper(await crowdfunder2.getAddress(), questionId, correctAnswer, 0, other) // Attempt to withdraw twice
      await withdrawHelper(await crowdfunder2.getAddress(), questionId, correctAnswer, 1, other) // Should withdraw 0
      await withdrawHelper(hostAddress, questionId, correctAnswer, 0, other) // Should withdraw 0
      const manyRulings = [BigNumber.from(0), BigNumber.from(123456), correctAnswer, wrongAnswer]
      await contract.connect(other).withdrawMultipleRulings(guestAddress, questionId, manyRulings, 0) // Should withdraw 0
      const balancesAfter = await getBalances()

      expect(balancesBefore.guest).to.equal(
        balancesBefore.guest,
        'Contributors of the loser side must not be rewarded'
      )
      expect(balancesAfter.host).to.equal(
        balancesAfter.host,
        'Non contributors must not be rewarded'
      )
      const [
        paidFees,
        _answersFunded,
        feeRewards,
        _appealed
      ] = await contract.getRoundInfo(questionId, 0)
      const reward3 = BigNumber.from(contribution3)
        .mul(feeRewards)
        .div(paidFees[1])
      expect(balancesBefore.crowdfunder1.add(reward3)).to.equal(
        balancesAfter.crowdfunder1,
        'Contributor 1 was not rewarded correctly'
      )

      const reward4 = BigNumber.from(contribution4)
        .mul(feeRewards)
        .div(paidFees[1])
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
        questionId
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      const exptectedDisputeID = 0
      await createDisputeHelper(questionId, exptectedDisputeID)
      await giveRulingHelper(exptectedDisputeID, correctAnswer)

      // Crowdfund the guest side
      const contribution1 = loserAppealFee / 2
      await fundAppealHelper(questionId, crowdfunder1, contribution1, wrongAnswer)

      const contribution2 = loserAppealFee - contribution1
      await fundAppealHelper(questionId, guest, contribution2, wrongAnswer)

      // Crowdfund the host side (crowdfunder1 funds both sides)
      const contribution3 = winnerAppealFee / 2
      await fundAppealHelper(questionId, crowdfunder1, contribution3, correctAnswer)

      const contribution4 = winnerAppealFee - contribution3
      await fundAppealHelper(questionId, crowdfunder2, contribution4 / 2, correctAnswer)
      await fundAppealHelper(questionId, crowdfunder2, contribution4 / 2, correctAnswer)

      // Give and execute final ruling, then withdraw
      const appealDisputeID = await arbitrator.getAppealDisputeID(exptectedDisputeID)
      await giveFinalRulingHelper(appealDisputeID, BigNumber.from(0), exptectedDisputeID)

      const balancesBefore = await getBalances()
      await withdrawHelper(await crowdfunder1.getAddress(), questionId, wrongAnswer, 0, other) // Should withdraw correctAnswer contribution too
      await withdrawHelper(await crowdfunder1.getAddress(), questionId, correctAnswer, 0, other) // Should withdraw 0
      await withdrawHelper(await crowdfunder2.getAddress(), questionId, correctAnswer, 0, other)
      await withdrawHelper(await crowdfunder2.getAddress(), questionId, correctAnswer, 0, other) // Attempt to withdraw twice
      await withdrawHelper(await crowdfunder2.getAddress(), questionId, correctAnswer, 1, other) // Should withdraw 0
      await withdrawHelper(hostAddress, questionId, correctAnswer, 0, other) // Should withdraw 0
      const manyRulings = [BigNumber.from(0), BigNumber.from(123456), correctAnswer, wrongAnswer]
      await contract.connect(other).withdrawMultipleRulings(guestAddress, questionId, manyRulings, 0) // Should withdraw wrongAnswer contribution
      const balancesAfter = await getBalances()

      expect(balancesBefore.host).to.equal(
        balancesAfter.host,
        'Non contributors must not be rewarded'
      )
      const [
        paidFees,
        _answersFunded,
        feeRewards,
        _appealed
      ] = await contract.getRoundInfo(questionId, 0)
      const totalFeesPaid = paidFees[1].add(paidFees[0])

      const reward2 = BigNumber.from(contribution2)
        .mul(feeRewards)
        .div(totalFeesPaid)
      expect(balancesBefore.guest.add(reward2)).to.equal(
        balancesAfter.guest,
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

    it('Should register/get contributions right', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR
      let answersFunded
      let contributions

      const [
        _receipt,
        questionId
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      const exptectedDisputeID = 0
      await createDisputeHelper(questionId, exptectedDisputeID)
      await giveRulingHelper(exptectedDisputeID, correctAnswer)

      // Crowdfund the guest side
      const contribution1 = loserAppealFee / 2
      await fundAppealHelper(questionId, crowdfunder1, contribution1, wrongAnswer)

      const contribution2 = loserAppealFee - contribution1
      await fundAppealHelper(questionId, guest, contribution2, wrongAnswer)

      ;[
        answersFunded,
        contributions
      ] = await contract.getContributions(questionId, 0, await crowdfunder1.getAddress())
      expect(answersFunded[0]).to.equal(wrongAnswer, 'Wrong answer funded')
      expect(answersFunded[1]).to.equal(BigNumber.from(0), 'Wrong answer funded')
      expect(contributions[0]).to.equal(BigNumber.from(contribution1), 'Wrong contribution registered')
      expect(contributions[1]).to.equal(BigNumber.from(0), 'Wrong contribution registered')

      // Crowdfund the host side (crowdfunder1 funds both sides)
      const contribution3 = winnerAppealFee / 2
      await fundAppealHelper(questionId, crowdfunder1, contribution3, correctAnswer)

      const contribution4 = winnerAppealFee - contribution3
      await fundAppealHelper(questionId, crowdfunder2, contribution4 / 2, correctAnswer)
      await fundAppealHelper(questionId, crowdfunder2, contribution4 / 2, correctAnswer)

      ;[
        answersFunded,
        contributions
      ] = await contract.getContributions(questionId, 0, await crowdfunder1.getAddress())
      expect(answersFunded[0]).to.equal(wrongAnswer, 'Wrong answer funded')
      expect(answersFunded[1]).to.equal(correctAnswer, 'Wrong answer funded')
      expect(contributions[0]).to.equal(BigNumber.from(contribution1), 'Wrong contribution registered')
      expect(contributions[1]).to.equal(BigNumber.from(contribution3), 'Wrong contribution registered')

      // Give and execute final ruling, then withdraw
      const appealDisputeID = await arbitrator.getAppealDisputeID(exptectedDisputeID)
      await giveFinalRulingHelper(appealDisputeID, correctAnswer, exptectedDisputeID)

      await withdrawHelper(await crowdfunder1.getAddress(), questionId, correctAnswer, 0, other)
      await withdrawHelper(await crowdfunder2.getAddress(), questionId, correctAnswer, 0, other)

      ;[
        answersFunded,
        contributions
      ] = await contract.getContributions(questionId, 0, await crowdfunder1.getAddress())
      expect(answersFunded[0]).to.equal(wrongAnswer, 'Wrong answer funded')
      expect(answersFunded[1]).to.equal(correctAnswer, 'Wrong answer funded')
      expect(contributions[0]).to.equal(BigNumber.from(contribution1), 'Wrong contribution registered')
      expect(contributions[1]).to.equal(BigNumber.from(0), 'Wrong contribution registered')

    })

    it('Should allow many rounds and batch-withdraw the fees after the final ruling', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR
      const totalAppeals = 4

      const [
        _receipt,
        questionId
      ] = await createQuestionHelper(BigNumber.from(currentTime + submissionTimeout), amount)
      const exptectedDisputeID = 0
      await createDisputeHelper(questionId, exptectedDisputeID)

      let roundDisputeID
      roundDisputeID = exptectedDisputeID
      for (var roundI = 0; roundI < totalAppeals; roundI += 1) {
        await giveRulingHelper(roundDisputeID, correctAnswer)
        // Fully fund both sides
        await fundAppealHelper(questionId, crowdfunder1, loserAppealFee, wrongAnswer)
        await fundAppealHelper(questionId, crowdfunder2, winnerAppealFee, correctAnswer)
        roundDisputeID = await arbitrator.getAppealDisputeID(exptectedDisputeID)
      }
      expect((await contract.getNumberOfRounds(questionId)).toNumber()).to.equal(
        totalAppeals + 1,
        'Wrong number of rounds'
      )
      
      // Give and execute final ruling
      await giveFinalRulingHelper(roundDisputeID, correctAnswer, exptectedDisputeID)

      // Batch-withdraw (checking if _cursor and _count arguments are working as expected).
      const balancesBefore = await getBalances()
      const withdrawableAmount1 = await contract.getTotalWithdrawableAmount(
        questionId, 
        await crowdfunder1.getAddress(),
        wrongAnswer
      )
      const withdrawableAmount2 = await contract.getTotalWithdrawableAmount(
        questionId,
        await crowdfunder2.getAddress(),
        correctAnswer
      )

      const tx1 = await contract
        .connect(other)
        .batchRoundWithdraw(await crowdfunder1.getAddress(), questionId, wrongAnswer, 0, 0)
      await tx1.wait()
      const tx2 = await contract
        .connect(other)
        .batchRoundWithdraw(await crowdfunder2.getAddress(), questionId, correctAnswer, 0, 2)
      await tx2.wait()
      const tx3 = await contract
        .connect(other)
        .batchRoundWithdraw(await crowdfunder2.getAddress(), questionId, correctAnswer, 0, 10)
      await tx3.wait()

      const balancesAfter = await getBalances()

      expect(withdrawableAmount1).to.equal(
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
        _answersFunded,
        feeRewards,
        _appealed
      ] = await contract.getRoundInfo(questionId, 0)

      const roundReward = BigNumber.from(winnerAppealFee)
        .mul(feeRewards)
        .div(paidFees[1])
      const totalReward = roundReward.mul(BigNumber.from(totalAppeals))

      expect(balancesBefore.crowdfunder2.add(totalReward)).to.equal(
        balancesAfter.crowdfunder2,
        'Contributor was not rewarded correctly'
      )

      expect(withdrawableAmount2).to.equal(
        BigNumber.from(totalReward),
        'Wrong withdrawable amount'
      )
    })
  })
  
  /**
   * Creates a transaction by host to guest.
   * @param {number} _amount Amount in wei.
   * @returns {Array} Tx data.
   */
  async function createQuestionHelper(_deadline, _amount) {
    const metaEvidence = metaEvidenceUri

    const tx = await contract
      .connect(host)
      .createQuestion(_deadline, metaEvidence, {
        value: _amount
      })
    const receipt = await tx.wait()
    const [questionID, _hostAddress] = receipt.events[1].args

    return [receipt, questionID]
  }

  /**
   * Make both sides pay arbitration fees. The transaction should have been previosuly created.
   * @param {number} questionID Id of the question.
   * @param {number} expectedDisputeID Expected id of the dispute to be created.
   * @param {number} fee Appeal round from which to withdraw the rewards.
   * @returns {Array} Tx data.
   */
  async function createDisputeHelper(
    questionID,
    expectedDisputeID,
    fee = arbitrationFee
  ) {
    // Pay fees, create dispute and validate events.
    const submissionTx = await contract
      .connect(guest)
      .submitAnswer(questionID, wrongAnswer, { value: fee })
    const submissionReceipt = await submissionTx.wait()
    
    const challengeTxPromise = contract
      .connect(host)
      .challengeAnswer(questionID, correctAnswer, correctEvidence, {
        value: fee
      })
    const challengeTx = await challengeTxPromise
    const challengeReceipt = await challengeTx.wait()

    // Check events: Dispute and Evidence
    expect(challengeTxPromise)
      .to.emit(contract, 'Dispute')
      .withArgs(
        arbitrator.address,
        expectedDisputeID,
        questionID,
        questionID
      )

    expect(challengeTxPromise)
    .to.emit(contract, 'Evidence')
    .withArgs(
      arbitrator.address,
      questionID,
      hostAddress,
      correctEvidence
    )
  }

  /**
   * Submit evidence related to a given transaction.
   * @param {number} questionID Id of the question.
   * @param {string} evidence Link to evidence.
   * @param {address} caller Can only be called by the host or the guest.
   * @param {boolean} isResolved If the dispute is resolved, submitEvidence is expected to revert.
   */
  async function submitEvidenceHelper(
    questionID,
    evidence,
    caller,
    isResolved = false
  ) {
    const txPromise = contract.connect(caller).submitEvidence(questionID, evidence)

    if (isResolved === false) {
      const callerAddress = await caller.getAddress()
      await expect(txPromise)
        .to.emit(contract, 'Evidence')
        .withArgs(arbitrator.address, questionID, callerAddress, evidence)
    } else {
      await expect(txPromise).to.be.revertedWith('Must not send evidence if the dispute is resolved.')
    }
  }

  /**
   * Give ruling (not final).
   * @param {number} disputeID dispute ID.
   * @param {number} ruling Ruling: None, Host or Guest.
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
   * @param {number} ruling Ruling: None, Host or Guest.
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
   * Fund new appeal round.
   * @param {number} questionID Id of the question.
   * @param {address} caller Can be anyone.
   * @param {number} contribution Contribution amount in wei.
   * @param {number} answer Ruling to contribute to: [1, 2^256 - 1].
   * @returns {Array} Tx data.
   */
  async function fundAppealHelper(
    questionID,
    caller,
    contribution,
    answer
  ) {
    const txPromise = contract
      .connect(caller)
      .fundAppeal(questionID, answer, { value: contribution })
    const tx = await txPromise
    const receipt = await tx.wait()

    return [txPromise, tx, receipt]
  }

  /**
   * Withdraw rewards to beneficiary.
   * @param {address} beneficiary Address of the round contributor.
   * @param {number} questionID Id of the question.
   * @param {number} answer Ruling to contribute to: [1, 2^256 - 1].
   * @param {number} round Appeal round from which to withdraw the rewards.
   * @param {address} caller Can be anyone.
   * @returns {Array} Tx data.
   */
  async function withdrawHelper(
    beneficiary,
    questionID,
    answer,
    round,
    caller
  ) {
    const txPromise = contract
      .connect(caller)
      .withdrawFeesAndRewards(beneficiary, questionID, answer, round)
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
      host: await host.getBalance(),
      guest: await guest.getBalance(),
      contract: await ethers.provider.getBalance(contract.address),
      crowdfunder1: await crowdfunder1.getBalance(),
      crowdfunder2: await crowdfunder2.getBalance()
    }
    return balances
  }
})
