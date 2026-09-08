import Foundation

public protocol InboxScanner: Sendable {
  func scan(_ workspace: Workspace, sessionID: UUID) -> AsyncThrowingStream<ScanEvent, Error>
}

public protocol ContentExtractor: Sendable {
  func extractContext(for item: ItemSnapshot) async -> ExtractedContext
}

public protocol ClassificationProvider: Sendable {
  var availabilityDescription: String { get }
  var isAvailable: Bool { get }
  func classify(items: [ItemContext], destinations: [DestinationProfile]) async throws
    -> [ModelProposal]
}

public protocol DecisionPolicy: Sendable {
  func evaluate(proposal: ModelProposal, deterministicCandidates: [RankedCandidate])
    -> ReviewDecision
}

public protocol PlanExecutor: Sendable {
  func preflight(_ plan: OrganizationPlan) async -> PreflightReport
  func execute(_ plan: OrganizationPlan) -> AsyncThrowingStream<ExecutionEvent, Error>
  func undo(plan: OrganizationPlan, receipt: ExecutionReceipt) -> AsyncThrowingStream<
    ExecutionEvent, Error
  >
}
