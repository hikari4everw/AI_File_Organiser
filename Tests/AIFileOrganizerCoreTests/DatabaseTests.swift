import Foundation
import GRDB
import Testing

@testable import AIFileOrganizerCore

@Suite struct DatabaseTests {
  @Test func migratesLegacyRulesToNullableDestinationsWithoutDataLoss() throws {
    let databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: databaseURL)
      try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
      try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
    }
    let workspaceID = UUID()
    let destinationID = UUID()
    let rule = OrganizationRule(
      workspaceID: workspaceID,
      originalText: "PDF 放文档",
      condition: RuleCondition(fileExtensions: ["pdf"]),
      destinationID: destinationID
    )
    let encoded = try JSONEncoder().encode(rule)
    var legacyObject = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacyObject.removeValue(forKey: "action")
    let legacyPayload = try JSONSerialization.data(withJSONObject: legacyObject)
    let legacyDatabase = try DatabaseQueue(path: databaseURL.path)
    try legacyDatabase.write { db in
      try db.execute(
        sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
      for identifier in ["v1-native", "v2.1-catalog-learning", "v2.1-active-workspace"] {
        try db.execute(
          sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
          arguments: [identifier])
      }
      try db.execute(
        sql: """
          CREATE TABLE organization_rules (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            destination_id TEXT NOT NULL,
            is_enabled BOOLEAN NOT NULL,
            payload_json BLOB NOT NULL
          )
          """)
      try db.execute(
        sql: """
          INSERT INTO organization_rules
          (id, workspace_id, destination_id, is_enabled, payload_json)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          rule.id.uuidString, workspaceID.uuidString, destinationID.uuidString, true,
          legacyPayload,
        ])
    }

    let migratedDatabase = try AppDatabase(path: databaseURL.path)

    let loaded = try #require(migratedDatabase.rules(workspaceID: workspaceID).first)
    #expect(loaded.id == rule.id)
    #expect(loaded.action == .move)
    #expect(loaded.destinationID == destinationID)
    let destinationColumnIsNullable = try migratedDatabase.queue.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(organization_rules)")
        .first { ($0["name"] as String) == "destination_id" }
        .map { ($0["notnull"] as Int) == 0 }
    }
    #expect(destinationColumnIsNullable == true)
  }

  @Test func createsExactlyTheV2EntityTables() throws {
    let database = try AppDatabase.inMemory()
    for table in [
      "workspaces", "sessions", "item_snapshots", "proposals", "folder_proposals", "plans",
      "operations", "decision_records", "libraries", "destinations", "organization_rules",
      "learning_events", "learning_samples", "rule_suggestions",
      "rename_proposals", "naming_rules", "naming_samples", "naming_rule_suggestions",
    ] {
      #expect(try database.rowCount(table) == 0)
    }
  }

  @Test func persistsRenameProposalsAndNamingRules() throws {
    let database = try AppDatabase.inMemory()
    let workspace = Workspace(
      inboxPath: "/tmp/inbox", libraryPath: "/tmp/library",
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    let session = OrganizationSession(workspaceID: workspace.id)
    let item = ItemSnapshot(
      sessionID: session.id, path: "/tmp/inbox/hash.pdf", name: "hash.pdf", kind: .file,
      fileExtension: "pdf")
    let proposal = RenameProposal(
      sessionID: session.id, itemID: item.id, originalName: item.name,
      suggestedBaseName: "Annual Report", source: .foundationModel, reason: "title")
    let rule = NamingRule(
      workspaceID: workspace.id, originalText: "PDF 命名为标题",
      condition: RuleCondition(fileExtensions: ["pdf"]),
      template: FilenameTemplate(pattern: "{标题}"))
    try database.saveWorkspace(workspace)
    try database.saveSession(session)
    try database.saveSnapshots([item])

    try database.saveRenameProposals([proposal])
    try database.saveNamingRule(rule)

    #expect(try database.renameProposals(sessionID: session.id) == [proposal])
    #expect(try database.namingRules(workspaceID: workspace.id) == [rule])
  }

  @Test func persistsWorkspaceAndSession() throws {
    let database = try AppDatabase.inMemory()
    let workspace = Workspace(
      inboxPath: "/tmp/inbox", libraryPath: "/tmp/library",
      inboxVolumeID: "volume", libraryVolumeID: "volume"
    )
    try database.saveWorkspace(workspace)
    #expect(try database.latestWorkspace()?.id == workspace.id)
    try database.saveSession(OrganizationSession(workspaceID: workspace.id))
    #expect(try database.rowCount("sessions") == 1)
  }

  @Test func deactivatingWorkspacePreservesItsHistory() throws {
    let database = try AppDatabase.inMemory()
    let workspace = Workspace(
      inboxPath: "/tmp/inbox", libraryPath: "/tmp/library",
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    try database.saveWorkspace(workspace)
    try database.saveSession(OrganizationSession(workspaceID: workspace.id))
    try database.deactivateWorkspaces()
    #expect(try database.latestWorkspace() == nil)
    #expect(try database.rowCount("workspaces") == 1)
    #expect(try database.rowCount("sessions") == 1)
  }

  @Test func reloadsSavedPlanAndItsPartialReceipt() throws {
    let database = try AppDatabase.inMemory()
    let workspaceID = UUID()
    let workspace = Workspace(
      id: workspaceID,
      inboxPath: "/tmp/inbox",
      libraryPath: "/tmp/library",
      inboxVolumeID: "volume",
      libraryVolumeID: "volume"
    )
    let session = OrganizationSession(workspaceID: workspaceID)
    let operation = PlannedOperation(
      sequence: 0,
      kind: .move,
      sourcePath: "/tmp/inbox/a.txt",
      destinationPath: "/tmp/library/Docs/a.txt"
    )
    let plan = OrganizationPlan(sessionID: session.id, operations: [operation])
    let receipt = ExecutionReceipt(
      planID: plan.id,
      results: [OperationResult(operationID: operation.id, state: .completed)]
    )
    try database.saveWorkspace(workspace)
    try database.saveSession(session)
    try database.savePlan(plan)
    try database.saveReceipt(receipt)

    let storedPlan = try database.plan(id: plan.id)
    let loaded = try #require(storedPlan)
    #expect(loaded.id == plan.id)
    #expect(loaded.sessionID == plan.sessionID)
    #expect(loaded.operations == plan.operations)
    #expect(try database.plans(workspaceID: workspaceID).map(\.id) == [plan.id])
    let storedReceipt = try database.receipt(planID: plan.id)
    let loadedReceipt = try #require(storedReceipt)
    #expect(loadedReceipt.id == receipt.id)
    #expect(loadedReceipt.planID == receipt.planID)
    #expect(loadedReceipt.results == receipt.results)
  }

  @Test func snapshotDatesRoundTripWithoutLosingSubsecondPrecision() throws {
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
    let session = OrganizationSession(workspaceID: workspace.id)
    try database.saveWorkspace(workspace)
    try database.saveSession(session)
    let source = inbox.appendingPathComponent("same-size.txt")
    try Data("aaaa".utf8).write(to: source)
    let firstDate = Date(timeIntervalSince1970: 2_000_000_000.125)
    try FileManager.default.setAttributes([.modificationDate: firstDate], ofItemAtPath: source.path)
    let operation = PlannedOperation(
      sequence: 0, kind: .move, sourcePath: source.path,
      destinationPath: library.appendingPathComponent("same-size.txt").path,
      preSnapshot: try .capture(source))
    let plan = OrganizationPlan(sessionID: session.id, operations: [operation])
    try database.savePlan(plan)

    let loaded = try #require(database.plan(id: plan.id)?.operations.first?.preSnapshot)
    #expect(loaded.matches(source))
    try Data("bbbb".utf8).write(to: source)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000.625)],
      ofItemAtPath: source.path)
    #expect(!loaded.matches(source))
  }

  @Test func legacySnapshotWithoutPrecisionMarkerIsConservativelyRejected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("legacy.txt")
    try Data("legacy".utf8).write(to: file)
    let current = try FileSnapshot.capture(file)
    let legacy = FileSnapshot(
      resourceIdentifier: current.resourceIdentifier,
      volumeIdentifier: current.volumeIdentifier,
      size: current.size,
      modificationDate: current.modificationDate,
      formatVersion: 1)
    #expect(!legacy.matches(file))
  }

  @Test func directoryManifestRoundTripsWithPreciseDates() throws {
    let database = try AppDatabase.inMemory()
    let workspace = Workspace(
      inboxPath: "/tmp/inbox", libraryPath: "/tmp/library",
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    try database.saveWorkspace(workspace)
    let session = OrganizationSession(workspaceID: workspace.id)
    try database.saveSession(session)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("Comic")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("page".utf8).write(to: folder.appendingPathComponent("01.jpg"))
    let operation = PlannedOperation(
      sequence: 0, kind: .move, sourcePath: folder.path,
      destinationPath: "/tmp/library/Comic", preSnapshot: try .capture(folder))
    let plan = OrganizationPlan(sessionID: session.id, operations: [operation])
    try database.savePlan(plan)

    let loaded = try #require(database.plan(id: plan.id)?.operations.first?.preSnapshot)
    let current = try FileSnapshot.capture(folder)
    #expect(loaded.resourceIdentifier == current.resourceIdentifier)
    #expect(loaded.size == current.size)
    #expect(loaded.modificationDate == current.modificationDate)
    #expect(loaded.directoryManifest?.entries == current.directoryManifest?.entries)
    #expect(loaded.matches(folder))
  }
}
