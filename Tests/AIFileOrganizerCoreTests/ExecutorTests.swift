import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct ExecutorTests {
  @Test func executeAndUndoMoveWithoutOverwrite() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("report.txt")
    try Data("original".utf8).write(to: source)
    let item = ItemSnapshot(
      sessionID: fixture.sessionID, path: source.path, name: source.lastPathComponent, kind: .file)
    let destination = DestinationProfile(
      relativePath: "Docs", displayName: "Docs", keywords: ["docs"])
    let proposal = ClassificationProposal(
      sessionID: fixture.sessionID, itemID: item.id, action: .move,
      destinationID: destination.id, source: .user, reviewDecision: .ready,
      status: .approved, reason: "test"
    )
    let plan = try PlanBuilder().build(
      sessionID: fixture.sessionID, workspace: fixture.workspace,
      items: [item], destinations: [destination], proposals: [proposal], folderProposals: []
    )
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
    #expect((await executor.preflight(plan)).isReady)
    var receipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { receipt = value }
    }
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(
      FileManager.default.fileExists(atPath: fixture.docs.appendingPathComponent("report.txt").path)
    )
    let unwrapped = try #require(receipt)
    for try await _ in executor.undo(plan: plan, receipt: unwrapped) {}
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test func preflightBlocksExistingDestination() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("same.txt")
    let destinationURL = fixture.docs.appendingPathComponent("same.txt")
    try Data("source".utf8).write(to: source)
    try Data("destination".utf8).write(to: destinationURL)
    let operation = PlannedOperation(
      sequence: 0, kind: .move, sourcePath: source.path,
      destinationPath: destinationURL.path, preSnapshot: try .capture(source)
    )
    let report = await SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
      .preflight(OrganizationPlan(sessionID: fixture.sessionID, operations: [operation]))
    #expect(!report.isReady)
    #expect(report.issues.contains { $0.message.contains("目标已存在") })
  }

  @Test func approvedFolderIsCreatedAndRemovedOnUndo() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("paper.pdf")
    try Data("pdf".utf8).write(to: source)
    let item = ItemSnapshot(
      sessionID: fixture.sessionID, path: source.path, name: source.lastPathComponent, kind: .file)
    let classification = ClassificationProposal(
      sessionID: fixture.sessionID, itemID: item.id, action: .suggestFolder,
      suggestedFolderName: "Research", source: .foundationModel,
      reviewDecision: .needsReview, reason: "test"
    )
    let folder = FolderProposal(
      sessionID: fixture.sessionID, normalizedName: "research",
      displayName: "Research", status: .approved, relatedItemIDs: [item.id]
    )
    let plan = try PlanBuilder().build(
      sessionID: fixture.sessionID, workspace: fixture.workspace,
      items: [item], destinations: [], proposals: [classification], folderProposals: [folder]
    )
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
    var receipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { receipt = value }
    }
    let created = fixture.library.appendingPathComponent("Research", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: created.path))
    let unwrapped = try #require(receipt)
    for try await _ in executor.undo(plan: plan, receipt: unwrapped) {}
    #expect(!FileManager.default.fileExists(atPath: created.path))
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  private func makeFixture() throws -> (
    root: URL, inbox: URL, library: URL, docs: URL,
    workspace: Workspace, database: AppDatabase, sessionID: UUID
  ) {
    let root = try temporaryDirectory()
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let docs = library.appendingPathComponent("Docs", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    let volume = try PathSafety.volumeIdentifier(for: inbox)
    let workspace = Workspace(
      inboxPath: inbox.path, libraryPath: library.path,
      inboxVolumeID: volume, libraryVolumeID: volume
    )
    let database = try AppDatabase.inMemory()
    try database.saveWorkspace(workspace)
    let sessionID = UUID()
    try database.saveSession(OrganizationSession(id: sessionID, workspaceID: workspace.id))
    return (root, inbox, library, docs, workspace, database, sessionID)
  }
}
