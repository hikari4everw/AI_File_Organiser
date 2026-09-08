import Foundation

public struct DefaultDecisionPolicy: DecisionPolicy {
  public init() {}

  public func evaluate(proposal: ModelProposal, deterministicCandidates: [RankedCandidate])
    -> ReviewDecision
  {
    switch proposal.action {
    case .keep:
      return .keep
    case .suggestFolder:
      return .needsReview
    case .move:
      guard let destination = proposal.destinationID else { return .needsReview }
      guard let first = deterministicCandidates.first else { return .needsReview }
      let margin = first.score - (deterministicCandidates.dropFirst().first?.score ?? 0)
      return first.destinationID == destination && first.score >= 0.65 && margin >= 0.15
        ? .ready
        : .needsReview
    }
  }
}
