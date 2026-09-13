import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct HistoryTests {
  @Test func listsLatestPlansForWorkspaceWithReceipts() throws {
    let database = try AppDatabase.inMemory()
    let workspace = Workspace(
      inboxPath: "/tmp/inbox",
      libraryPath: "/tmp/library",
      inboxVolumeID: "volume",
      libraryVolumeID: "volume"
    )
    try database.saveWorkspace(workspace)
    let session = OrganizationSession(workspaceID: workspace.id)
    try database.saveSession(session)
    let plan = OrganizationPlan(sessionID: session.id, operations: [])
    try database.savePlan(plan)
    let receipt = ExecutionReceipt(planID: plan.id, results: [])
    try database.saveReceipt(receipt)

    let entries = try HistoryStore(database: database).entries(workspaceID: workspace.id)

    #expect(entries.count == 1)
    #expect(entries[0].plan.id == plan.id)
    #expect(entries[0].receipt?.id == receipt.id)
  }

  @Test func reconcilesMoveCompletedBetweenFilesystemAndDatabaseWrites() throws {
    let database = try AppDatabase.inMemory()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let inbox = root.appendingPathComponent("Inbox")
    let library = root.appendingPathComponent("Library")
    let docs = library.appendingPathComponent("Docs")
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let volume = try PathSafety.volumeIdentifier(for: inbox)
    let workspace = Workspace(
      inboxPath: inbox.path, libraryPath: library.path,
      inboxVolumeID: volume, libraryVolumeID: volume)
    try database.saveWorkspace(workspace)
    let session = OrganizationSession(workspaceID: workspace.id)
    try database.saveSession(session)
    let source = inbox.appendingPathComponent("score.pdf")
    let destination = docs.appendingPathComponent("score.pdf")
    try Data("score".utf8).write(to: source)
    let operation = PlannedOperation(
      sequence: 0, kind: .move, sourcePath: source.path, destinationPath: destination.path,
      preSnapshot: try .capture(source), destinationID: UUID(),
      decisionFeatures: DecisionFeatures(itemKind: .file, fileExtension: "pdf"),
      learningConfirmation: .userApproved)
    let plan = OrganizationPlan(sessionID: session.id, operations: [operation])
    try database.savePlan(plan)
    try database.updateOperation(operation.id, state: .running)
    try FileManager.default.moveItem(at: source, to: destination)
    #expect(operation.preSnapshot?.matches(destination) == true)

    let entry = try #require(HistoryStore(database: database).entries(workspaceID: workspace.id).first)

    #expect(entry.receipt?.results.first?.state == .completed)
    #expect(try LearningService(database: database).activeSamples(libraryID: workspace.id).count == 1)

    try database.updateOperation(operation.id, state: .undoing)
    try FileManager.default.moveItem(at: destination, to: source)
    let reconciledUndo = try #require(
      HistoryStore(database: database).entries(workspaceID: workspace.id).first)
    #expect(reconciledUndo.receipt?.isUndoReceipt == true)
    #expect(reconciledUndo.receipt?.results.first?.state == .undone)
    #expect(try LearningService(database: database).activeSamples(libraryID: workspace.id).isEmpty)
  }

  @Test func reconcilesRenameWithoutRepeatingItAndTracksNamingLearning() throws {
    let database = try AppDatabase.inMemory()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let inbox = root.appendingPathComponent("Inbox")
    let library = root.appendingPathComponent("Library")
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let volume = try PathSafety.volumeIdentifier(for: inbox)
    let workspace = Workspace(
      inboxPath: inbox.path, libraryPath: library.path,
      inboxVolumeID: volume, libraryVolumeID: volume)
    try database.saveWorkspace(workspace)
    let session = OrganizationSession(workspaceID: workspace.id)
    try database.saveSession(session)
    let source = inbox.appendingPathComponent("8f14e45f.pdf")
    let destination = inbox.appendingPathComponent("Moonlight Sonata.pdf")
    try Data("score".utf8).write(to: source)
    let operation = PlannedOperation(
      sequence: 0, kind: .rename, sourcePath: source.path,
      destinationPath: destination.path, preSnapshot: try .capture(source),
      namingDecisionFeatures: NamingDecisionFeatures(
        itemKind: .file, fileExtension: "pdf", originalBaseName: "8f14e45f",
        finalBaseName: "Moonlight Sonata", templatePattern: "{标题}"),
      namingSampleSource: .acceptedSuggestion)
    let plan = OrganizationPlan(sessionID: session.id, operations: [operation])
    try database.savePlan(plan)
    try database.updateOperation(operation.id, state: .running)
    try FileManager.default.moveItem(at: source, to: destination)

    let entry = try #require(HistoryStore(database: database).entries(workspaceID: workspace.id).first)
    #expect(entry.receipt?.results.first?.state == .completed)
    #expect(try NamingLearningService(database: database).activeSamples(workspaceID: workspace.id).count == 1)

    try database.updateOperation(operation.id, state: .undoing)
    try FileManager.default.moveItem(at: destination, to: source)
    let undone = try #require(HistoryStore(database: database).entries(workspaceID: workspace.id).first)
    #expect(undone.receipt?.results.first?.state == .undone)
    #expect(try NamingLearningService(database: database).activeSamples(workspaceID: workspace.id).isEmpty)
  }

  @Test func ambiguousUndoCrashRemainsRetryable() throws {
    let database = try AppDatabase.inMemory()
    let workspace = Workspace(
      inboxPath: "/tmp/inbox", libraryPath: "/tmp/library",
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    try database.saveWorkspace(workspace)
    let session = OrganizationSession(workspaceID: workspace.id)
    try database.saveSession(session)
    let operation = PlannedOperation(
      sequence: 0, kind: .move, sourcePath: "/tmp/inbox/missing.txt",
      destinationPath: "/tmp/library/missing.txt",
      preSnapshot: FileSnapshot(
        resourceIdentifier: "missing", volumeIdentifier: "volume", size: 1,
        modificationDate: Date()))
    let plan = OrganizationPlan(sessionID: session.id, operations: [operation])
    try database.savePlan(plan)
    try database.saveReceipt(ExecutionReceipt(
      planID: plan.id,
      results: [.init(operationID: operation.id, state: .completed)]))
    try database.updateOperation(operation.id, state: .undoing)

    let entry = try #require(HistoryStore(database: database).entries(workspaceID: workspace.id).first)
    #expect(entry.receipt?.isUndoReceipt == true)
    #expect(entry.receipt?.results.first?.state == .blocked)
    #expect(try database.operationStates(planID: plan.id)[operation.id] == .undoBlocked)
  }

  @Test func recoversOwnedDirectoryCreatedBeforeDatabaseCompletion() throws {
    let database = try AppDatabase.inMemory()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let inbox = root.appendingPathComponent("Inbox")
    let library = root.appendingPathComponent("Library")
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let volume = try PathSafety.volumeIdentifier(for: inbox)
    let workspace = Workspace(
      inboxPath: inbox.path, libraryPath: library.path,
      inboxVolumeID: volume, libraryVolumeID: volume)
    try database.saveWorkspace(workspace)
    let session = OrganizationSession(workspaceID: workspace.id)
    try database.saveSession(session)
    let operation = PlannedOperation(
      sequence: 0, kind: .createDirectory,
      destinationPath: library.appendingPathComponent("Research").path,
      createdByApp: true)
    let plan = OrganizationPlan(sessionID: session.id, operations: [operation])
    try database.savePlan(plan)
    try database.updateOperation(operation.id, state: .running)
    try DirectoryOwnership.install(operation)

    let entry = try #require(HistoryStore(database: database).entries(workspaceID: workspace.id).first)
    #expect(entry.receipt?.results.first?.state == .completed)
    #expect(try database.operationStates(planID: plan.id)[operation.id] == .completed)
  }

  @Test func crashBetweenOperationsKeepsReceiptIncomplete() throws {
    let database = try AppDatabase.inMemory()
    let workspace = Workspace(
      inboxPath: "/tmp/inbox", libraryPath: "/tmp/library",
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    try database.saveWorkspace(workspace)
    let session = OrganizationSession(workspaceID: workspace.id)
    try database.saveSession(session)
    let first = PlannedOperation(
      sequence: 0, kind: .move, sourcePath: "/tmp/inbox/a",
      destinationPath: "/tmp/library/a")
    let second = PlannedOperation(
      sequence: 1, kind: .move, sourcePath: "/tmp/inbox/b",
      destinationPath: "/tmp/library/b")
    let plan = OrganizationPlan(sessionID: session.id, operations: [first, second])
    try database.savePlan(plan)
    try database.updateOperation(first.id, state: .completed)
    try database.saveReceipt(ExecutionReceipt(
      planID: plan.id,
      results: [.init(operationID: first.id, state: .completed)]))

    let entry = try #require(HistoryStore(database: database).entries(workspaceID: workspace.id).first)
    #expect(entry.receipt?.isFinal == false)
    #expect(entry.receipt?.wasCancelled == true)
  }
}
