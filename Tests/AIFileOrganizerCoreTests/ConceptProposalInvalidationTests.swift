import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct ConceptProposalInvalidationTests {
  @Test func invalidatedApprovedRouteProducesNoExecutableOperation() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = inbox.appendingPathComponent("one.pdf")
    try Data("one".utf8).write(to: source)
    let sessionID = UUID()
    let item = ItemSnapshot(
      sessionID: sessionID, path: source.path, name: source.lastPathComponent,
      kind: .file, fileExtension: "pdf")
    let destination = DestinationProfile(
      relativePath: "Finance", displayName: "Finance")
    let ruleID = UUID()
    let stale = ClassificationProposal(
      sessionID: sessionID, itemID: item.id, action: .move,
      destinationID: destination.id, source: .user, reviewDecision: .ready,
      status: .approved, reason: "old",
      evidence: [Evidence(kind: "rule", detail: ruleID.uuidString, weight: 1)])
    let invalidated = ConceptProposalInvalidator().invalidate(
      proposals: [stale], renames: [], moveRuleIDs: [ruleID], namingRuleIDs: [])
    let workspace = Workspace(
      inboxPath: inbox.path, libraryPath: library.path,
      inboxVolumeID: "test", libraryVolumeID: "test")
    let plan = try PlanBuilder().build(
      sessionID: sessionID, workspace: workspace, items: [item],
      destinations: [destination], proposals: invalidated.proposals,
      folderProposals: [], renameProposals: invalidated.renames)
    #expect(plan.operations.isEmpty)
  }

  @Test func obsoleteConceptRulesCannotRemainSelectedForExecution() {
    let sessionID = UUID()
    let itemID = UUID()
    let moveRuleID = UUID()
    let nameRuleID = UUID()
    let proposal = ClassificationProposal(
      sessionID: sessionID, itemID: itemID, action: .move,
      destinationID: UUID(), source: .user, reviewDecision: .ready,
      status: .approved,
      reason: "old", evidence: [Evidence(
        kind: "rule", detail: moveRuleID.uuidString, weight: 1)])
    let rename = RenameProposal(
      sessionID: sessionID, itemID: itemID, originalName: "old.pdf",
      suggestedBaseName: "new", source: .namingRule,
      disposition: .selectedByRule, ruleID: nameRuleID, reason: "old")
    let result = ConceptProposalInvalidator().invalidate(
      proposals: [proposal], renames: [rename],
      moveRuleIDs: [moveRuleID], namingRuleIDs: [nameRuleID])

    #expect(result.proposals.first?.action == .keep)
    #expect(result.proposals.first?.reviewDecision == .needsReview)
    #expect(result.proposals.first?.status == .pending)
    #expect(result.proposals.first?.destinationID == nil)
    #expect(result.renames.first?.selectedBaseName == nil)
  }
}
