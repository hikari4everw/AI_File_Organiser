import Foundation
import Testing

@testable import AIFileOrganizerCore

private actor ExecutionProgressRecorder {
  private var values: [OrganizationProgress] = []

  func record(_ value: OrganizationProgress) { values.append(value) }
  func snapshot() -> [OrganizationProgress] { values }
}

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
    let storedUndo = try #require(try fixture.database.receipt(planID: plan.id))
    #expect(storedUndo.results.allSatisfy { $0.state == .undone })
    var secondUndoTotal: Int?
    for try await event in executor.undo(plan: plan, receipt: storedUndo) {
      if case .started(let total) = event { secondUndoTotal = total }
    }
    #expect(secondUndoTotal == 0)
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

  @Test func preflightProgressReachesOperationTotalAndReportsIssues() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("same.txt")
    let destinationURL = fixture.docs.appendingPathComponent("same.txt")
    try Data("source".utf8).write(to: source)
    try Data("destination".utf8).write(to: destinationURL)
    let operation = PlannedOperation(
      sequence: 0,
      kind: .move,
      sourcePath: source.path,
      destinationPath: destinationURL.path,
      preSnapshot: try .capture(source)
    )
    let recorder = ExecutionProgressRecorder()

    _ = await SafePlanExecutor(workspace: fixture.workspace, database: fixture.database).preflight(
      OrganizationPlan(sessionID: fixture.sessionID, operations: [operation]),
      progress: { value in await recorder.record(value) }
    )

    let values = await recorder.snapshot()
    #expect(values.first?.completed == 0)
    #expect(values.last?.completed == 1)
    #expect(values.last?.total == 1)
    #expect(values.last?.failed == 1)
    #expect(values.allSatisfy { !$0.isCancellable })
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
    var undoReceipt: ExecutionReceipt?
    for try await event in executor.undo(plan: plan, receipt: unwrapped) {
      if case .finished(let value) = event { undoReceipt = value }
    }
    #expect(undoReceipt?.results.first { $0.operationID == plan.operations[0].id }?.error == nil)
    #expect(undoReceipt?.results.allSatisfy { $0.state == .undone } == true)
    #expect(!FileManager.default.fileExists(atPath: created.path))
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test func directorySnapshotDetectsChangedChildrenBeforeUndo() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Comic", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("page-one".utf8).write(to: folder.appendingPathComponent("01.txt"))
    let snapshot = try FileSnapshot.capture(folder)

    try Data("page-two".utf8).write(to: folder.appendingPathComponent("02.txt"))

    #expect(!snapshot.matches(folder))
  }

  @Test func successfulMoveLearnsOnceAndUndoRetractsSample() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("score.pdf")
    try Data("piano score".utf8).write(to: source)
    let item = ItemSnapshot(
      sessionID: fixture.sessionID,
      path: source.path,
      name: source.lastPathComponent,
      kind: .file,
      fileExtension: "pdf"
    )
    let destination = DestinationProfile(relativePath: "Docs", displayName: "Docs")
    let proposal = ClassificationProposal(
      sessionID: fixture.sessionID,
      itemID: item.id,
      action: .move,
      destinationID: destination.id,
      source: .user,
      reviewDecision: .ready,
      status: .approved,
      reason: "user"
    )
    let plan = try PlanBuilder().build(
      sessionID: fixture.sessionID,
      workspace: fixture.workspace,
      items: [item],
      destinations: [destination],
      proposals: [proposal],
      folderProposals: []
    )
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
    var receipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { receipt = value }
    }
    let completedReceipt = try #require(receipt)
    #expect(
      try LearningService(database: fixture.database).activeSamples(libraryID: fixture.workspace.id)
        .count == 1
    )

    for try await _ in executor.execute(plan) {}
    #expect(
      try LearningService(database: fixture.database).activeSamples(libraryID: fixture.workspace.id)
        .count == 1
    )
    for try await _ in executor.undo(plan: plan, receipt: completedReceipt) {}
    #expect(
      try LearningService(database: fixture.database).activeSamples(libraryID: fixture.workspace.id)
        .isEmpty
    )
    for try await _ in executor.execute(plan) {}
    #expect(
      try LearningService(database: fixture.database).activeSamples(libraryID: fixture.workspace.id)
        .count == 1
    )
  }

  @Test func cancellationFinishesAndPersistsReceiptBeforeStreamEnds() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("cancel.txt")
    try Data("cancel".utf8).write(to: source)
    let operation = PlannedOperation(
      sequence: 0, kind: .move, sourcePath: source.path,
      destinationPath: fixture.docs.appendingPathComponent("cancel.txt").path,
      preSnapshot: try .capture(source))
    let plan = OrganizationPlan(sessionID: fixture.sessionID, operations: [operation])
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
    executor.cancel()
    var finished: ExecutionReceipt?
    do {
      for try await event in executor.execute(plan) {
        if case .finished(let receipt) = event { finished = receipt }
      }
    } catch is CancellationError {}
    let receipt = try #require(finished)
    #expect(receipt.wasCancelled)
    #expect(try fixture.database.receipt(planID: plan.id)?.id == receipt.id)
  }

  @Test func blockedUndoReceiptKeepsOperationRetryable() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("retry.txt")
    try Data("original".utf8).write(to: source)
    let operation = PlannedOperation(
      sequence: 0,
      kind: .move,
      sourcePath: source.path,
      destinationPath: fixture.docs.appendingPathComponent("retry.txt").path,
      preSnapshot: try .capture(source)
    )
    let plan = OrganizationPlan(sessionID: fixture.sessionID, operations: [operation])
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
    var executionReceipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { executionReceipt = value }
    }
    try Data("occupied".utf8).write(to: source)
    var blockedReceipt: ExecutionReceipt?
    for try await event in executor.undo(plan: plan, receipt: try #require(executionReceipt)) {
      if case .finished(let value) = event { blockedReceipt = value }
    }
    let blocked = try #require(blockedReceipt)
    #expect(blocked.isUndoReceipt)
    #expect(blocked.results.first?.state == .blocked)

    try FileManager.default.removeItem(at: source)
    var retriedReceipt: ExecutionReceipt?
    for try await event in executor.undo(plan: plan, receipt: blocked) {
      if case .finished(let value) = event { retriedReceipt = value }
    }
    #expect(retriedReceipt?.results.first?.state == .undone)
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test func staleFolderProposalCannotOverrideManualDestination() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("manual.pdf")
    try Data("manual".utf8).write(to: source)
    let item = ItemSnapshot(
      sessionID: fixture.sessionID, path: source.path, name: source.lastPathComponent,
      kind: .file, fileExtension: "pdf")
    let manualDestination = DestinationProfile(relativePath: "Docs", displayName: "Docs")
    let manual = ClassificationProposal(
      sessionID: fixture.sessionID, itemID: item.id, action: .move,
      destinationID: manualDestination.id, source: .user, reviewDecision: .ready,
      status: .overridden, reason: "manual")
    let stale = FolderProposal(
      sessionID: fixture.sessionID, normalizedName: "research", displayName: "Research",
      status: .approved, relatedItemIDs: [item.id])

    let plan = try PlanBuilder().build(
      sessionID: fixture.sessionID, workspace: fixture.workspace,
      items: [item], destinations: [manualDestination], proposals: [manual],
      folderProposals: [stale])

    let move = try #require(plan.operations.first { $0.kind == .move })
    #expect(move.destinationPath == fixture.docs.appendingPathComponent("manual.pdf").path)
    #expect(!plan.operations.contains { $0.kind == .createDirectory })
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
