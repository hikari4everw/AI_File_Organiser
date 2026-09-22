import Foundation
import Testing

@testable import AIFileOrganizerCore

/// `DefaultDecisionPolicy` 决定"本地模型给出的移动建议能否直接标为就绪"：
/// 只有首选候选与模型提议同一目标、分数 ≥ 0.65 且领先第二名 ≥ 0.15 时才
/// 返回 `.ready`，否则一律 `.needsReview`。
///
/// 在此之前**没有任何测试**引用它——尽管它是模型输出能否免于人工审核的
/// 唯一闸门（`ClassificationPipeline.swift:268`）。
@Suite struct DefaultDecisionPolicyTests {
  private func candidate(_ destinationID: UUID, score: Double) -> RankedCandidate {
    RankedCandidate(
      destinationID: destinationID, score: score,
      evidence: [Evidence(kind: "test", detail: "d", weight: score)])
  }

  private func moveProposal(to destinationID: UUID?) -> ModelProposal {
    ModelProposal(
      itemID: UUID(), action: .move, destinationID: destinationID, reason: "test")
  }

  @Test func keepActionIsKeepRegardlessOfCandidates() {
    let policy = DefaultDecisionPolicy()
    let keep = ModelProposal(itemID: UUID(), action: .keep, reason: "用户保留")
    #expect(policy.evaluate(proposal: keep, deterministicCandidates: []) == .keep)
    #expect(
      policy.evaluate(
        proposal: keep,
        deterministicCandidates: [candidate(UUID(), score: 1.0)]) == .keep)
  }

  @Test func suggestedFolderAlwaysNeedsReview() {
    let policy = DefaultDecisionPolicy()
    let proposal = ModelProposal(
      itemID: UUID(), action: .suggestFolder, suggestedFolderName: "新目录", reason: "新建")
    #expect(policy.evaluate(proposal: proposal, deterministicCandidates: []) == .needsReview)
    #expect(
      policy.evaluate(
        proposal: proposal,
        deterministicCandidates: [candidate(UUID(), score: 1.0)]) == .needsReview)
  }

  @Test func moveWithoutDestinationNeedsReview() {
    let policy = DefaultDecisionPolicy()
    #expect(
      policy.evaluate(
        proposal: moveProposal(to: nil),
        deterministicCandidates: [candidate(UUID(), score: 0.99)]) == .needsReview)
  }

  @Test func moveWithoutDeterministicCandidatesNeedsReview() {
    let policy = DefaultDecisionPolicy()
    #expect(
      policy.evaluate(proposal: moveProposal(to: UUID()), deterministicCandidates: [])
        == .needsReview)
  }

  /// 模型选的目标与确定性排序的首选不一致时，即使分数很高也不能直接就绪。
  @Test func moveMustAgreeWithTopDeterministicCandidate() {
    let policy = DefaultDecisionPolicy()
    let top = UUID()
    let other = UUID()
    let result = policy.evaluate(
      proposal: moveProposal(to: other),
      deterministicCandidates: [candidate(top, score: 0.95), candidate(other, score: 0.10)])
    #expect(result == .needsReview)
  }

  @Test func scoreThresholdBoundaryIsInclusiveAtZeroPointSixFive() {
    let policy = DefaultDecisionPolicy()
    let destination = UUID()

    // 差值足够（0.65 - 0.00 = 0.65 ≥ 0.15），只测分数边界。
    #expect(
      policy.evaluate(
        proposal: moveProposal(to: destination),
        deterministicCandidates: [candidate(destination, score: 0.65)]) == .ready)
    #expect(
      policy.evaluate(
        proposal: moveProposal(to: destination),
        deterministicCandidates: [candidate(destination, score: 0.649)]) == .needsReview)
  }

  @Test func marginThresholdBoundaryIsInclusiveAtZeroPointOneFive() {
    let policy = DefaultDecisionPolicy()
    let destination = UUID()
    let runnerUp = UUID()

    // 分数足够（0.80 ≥ 0.65），只测差值边界。
    #expect(
      policy.evaluate(
        proposal: moveProposal(to: destination),
        deterministicCandidates: [
          candidate(destination, score: 0.80), candidate(runnerUp, score: 0.65),
        ]) == .ready)
    #expect(
      policy.evaluate(
        proposal: moveProposal(to: destination),
        deterministicCandidates: [
          candidate(destination, score: 0.80), candidate(runnerUp, score: 0.651),
        ]) == .needsReview)
  }

  /// 候选顺序由调用方保证（DeterministicClassifier 已按分数降序返回）；
  /// 这里固化"只信任首选"的契约，避免将来误以为它会自行重排。
  @Test func onlyTheFirstCandidateIsConsidered() {
    let policy = DefaultDecisionPolicy()
    let destination = UUID()
    let result = policy.evaluate(
      proposal: moveProposal(to: destination),
      deterministicCandidates: [
        candidate(UUID(), score: 0.10), candidate(destination, score: 0.90),
      ])
    #expect(result == .needsReview)
  }
}
