import Foundation
import GRDB

public final class AppDatabase: @unchecked Sendable {
  public let queue: DatabaseQueue
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(path: String) throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      try db.execute(sql: "PRAGMA busy_timeout = 5000")
    }
    queue = try DatabaseQueue(path: path, configuration: configuration)
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = Self.preciseDateEncodingStrategy
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = Self.compatibleDateDecodingStrategy
    try migrate()
  }

  public static func applicationDatabase() throws -> AppDatabase {
    let fileManager = FileManager.default
    let base = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("AIFileOrganizerV2", isDirectory: true)
    try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    return try AppDatabase(path: base.appendingPathComponent("organizer.sqlite").path)
  }

  public static func inMemory() throws -> AppDatabase {
    var configuration = Configuration()
    configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
    let instance = try AppDatabase(queue: DatabaseQueue(configuration: configuration))
    return instance
  }

  private init(queue: DatabaseQueue) throws {
    self.queue = queue
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = Self.preciseDateEncodingStrategy
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = Self.compatibleDateDecodingStrategy
    try migrate()
  }

  private static var preciseDateEncodingStrategy: JSONEncoder.DateEncodingStrategy {
    .custom { date, encoder in
      var container = encoder.singleValueContainer()
      let bits = String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
      try container.encode("date-bits:\(bits)")
    }
  }

  private static var compatibleDateDecodingStrategy: JSONDecoder.DateDecodingStrategy {
    .custom { decoder in
      let container = try decoder.singleValueContainer()
      if let value = try? container.decode(String.self) {
        if value.hasPrefix("date-bits:"),
          let bits = UInt64(value.dropFirst("date-bits:".count), radix: 16)
        {
          return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let legacy = ISO8601DateFormatter()
        legacy.formatOptions = [.withInternetDateTime]
        if let date = legacy.date(from: value) { return date }
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "无法解析日期：\(value)")
      }
      if let seconds = try? container.decode(Double.self) {
        return Date(timeIntervalSince1970: seconds)
      }
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "无法解析日期")
    }
  }

  private func migrate() throws {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1-native") { db in
      try db.create(table: "workspaces") { table in
        table.column("id", .text).primaryKey()
        table.column("inbox_path", .text).notNull()
        table.column("library_path", .text).notNull()
        table.column("inbox_bookmark", .blob).notNull()
        table.column("library_bookmark", .blob).notNull()
        table.column("inbox_volume_id", .text).notNull()
        table.column("library_volume_id", .text).notNull()
        table.column("payload_json", .blob).notNull()
        table.column("created_at", .datetime).notNull()
      }
      try db.create(table: "sessions") { table in
        table.column("id", .text).primaryKey()
        table.column("workspace_id", .text).notNull().indexed()
          .references("workspaces", onDelete: .cascade)
        table.column("state", .text).notNull()
        table.column("payload_json", .blob).notNull()
        table.column("started_at", .datetime).notNull()
        table.column("finished_at", .datetime)
      }
      try db.create(table: "item_snapshots") { table in
        table.column("id", .text).primaryKey()
        table.column("session_id", .text).notNull().indexed()
          .references("sessions", onDelete: .cascade)
        table.column("path", .text).notNull()
        table.column("payload_json", .blob).notNull()
      }
      try db.create(table: "proposals") { table in
        table.column("id", .text).primaryKey()
        table.column("session_id", .text).notNull().indexed()
          .references("sessions", onDelete: .cascade)
        table.column("item_id", .text).notNull().indexed()
          .references("item_snapshots", onDelete: .cascade)
        table.column("status", .text).notNull()
        table.column("payload_json", .blob).notNull()
      }
      try db.create(table: "folder_proposals") { table in
        table.column("id", .text).primaryKey()
        table.column("session_id", .text).notNull().indexed()
          .references("sessions", onDelete: .cascade)
        table.column("normalized_name", .text).notNull()
        table.column("status", .text).notNull()
        table.column("payload_json", .blob).notNull()
        table.uniqueKey(["session_id", "normalized_name"])
      }
      try db.create(table: "plans") { table in
        table.column("id", .text).primaryKey()
        table.column("session_id", .text).notNull().indexed()
          .references("sessions", onDelete: .cascade)
        table.column("status", .text).notNull()
        table.column("payload_json", .blob).notNull()
        table.column("receipt_json", .blob)
        table.column("confirmed_at", .datetime).notNull()
      }
      try db.create(table: "operations") { table in
        table.column("id", .text).primaryKey()
        table.column("plan_id", .text).notNull().indexed()
          .references("plans", onDelete: .cascade)
        table.column("sequence", .integer).notNull()
        table.column("kind", .text).notNull()
        table.column("source_path", .text)
        table.column("destination_path", .text).notNull()
        table.column("state", .text).notNull()
        table.column("payload_json", .blob).notNull()
        table.column("error", .text)
        table.column("updated_at", .datetime).notNull()
        table.uniqueKey(["plan_id", "sequence"])
      }
      try db.create(table: "decision_records") { table in
        table.column("id", .text).primaryKey()
        table.column("session_id", .text).notNull().indexed()
          .references("sessions", onDelete: .cascade)
        table.column("item_id", .text).notNull()
        table.column("action", .text).notNull()
        table.column("payload_json", .blob).notNull()
        table.column("created_at", .datetime).notNull()
      }
    }
    migrator.registerMigration("v2.1-catalog-learning") { db in
      try db.create(table: "libraries") { table in
        table.column("id", .text).primaryKey()
        table.column("workspace_id", .text).notNull().indexed()
        table.column("payload_json", .blob)
      }
      try db.create(table: "destinations") { table in
        table.column("id", .text).primaryKey()
        table.column("library_id", .text).notNull().indexed()
        table.column("relative_path", .text).notNull()
        table.column("kind", .text).notNull()
        table.column("payload_json", .blob).notNull()
        table.uniqueKey(["library_id", "relative_path"])
      }
      try db.create(table: "organization_rules") { table in
        table.column("id", .text).primaryKey()
        table.column("workspace_id", .text).notNull().indexed()
        table.column("destination_id", .text).notNull()
        table.column("is_enabled", .boolean).notNull()
        table.column("payload_json", .blob).notNull()
      }
      try db.create(table: "learning_events") { table in
        table.column("id", .text).primaryKey()
        table.column("operation_id", .text).notNull().unique()
        table.column("state", .text).notNull()
        table.column("payload_json", .blob).notNull()
      }
      try db.create(table: "learning_samples") { table in
        table.column("id", .text).primaryKey()
        table.column("library_id", .text).notNull().indexed()
        table.column("operation_id", .text).unique()
        table.column("item_identity", .text).notNull()
        table.column("destination_id", .text).notNull()
        table.column("is_active", .boolean).notNull()
        table.column("payload_json", .blob).notNull()
        table.column("created_at", .datetime).notNull()
      }
      try db.create(table: "rule_suggestions") { table in
        table.column("id", .text).primaryKey()
        table.column("library_id", .text).notNull().indexed()
        table.column("state", .text).notNull()
        table.column("payload_json", .blob).notNull()
      }
    }
    migrator.registerMigration("v2.1-active-workspace") { db in
      try db.alter(table: "workspaces") { table in
        table.add(column: "is_active", .boolean).notNull().defaults(to: false)
      }
      try db.execute(
        sql: """
          UPDATE workspaces SET is_active = 1
          WHERE id = (SELECT id FROM workspaces ORDER BY created_at DESC LIMIT 1)
          """)
    }
    migrator.registerMigration("v2.2-rule-actions") { db in
      try db.create(table: "organization_rules_v2") { table in
        table.column("id", .text).primaryKey()
        table.column("workspace_id", .text).notNull().indexed()
        table.column("destination_id", .text)
        table.column("action", .text).notNull().defaults(to: RuleAction.move.rawValue)
        table.column("is_enabled", .boolean).notNull()
        table.column("payload_json", .blob).notNull()
      }
      try db.execute(
        sql: """
          INSERT INTO organization_rules_v2
          (id, workspace_id, destination_id, action, is_enabled, payload_json)
          SELECT id, workspace_id, destination_id, 'move', is_enabled, payload_json
          FROM organization_rules
          """)
      try db.drop(table: "organization_rules")
      try db.rename(table: "organization_rules_v2", to: "organization_rules")
    }
    migrator.registerMigration("v2.2-filename-renaming") { db in
      try db.create(table: "rename_proposals") { table in
        table.column("id", .text).primaryKey()
        table.column("session_id", .text).notNull().indexed()
        table.column("item_id", .text).notNull().indexed()
        table.column("disposition", .text).notNull()
        table.column("payload_json", .blob).notNull()
        table.uniqueKey(["session_id", "item_id"])
      }
      try db.create(table: "naming_rules") { table in
        table.column("id", .text).primaryKey()
        table.column("workspace_id", .text).notNull().indexed()
        table.column("is_enabled", .boolean).notNull()
        table.column("payload_json", .blob).notNull()
      }
      try db.create(table: "naming_samples") { table in
        table.column("id", .text).primaryKey()
        table.column("workspace_id", .text).notNull().indexed()
        table.column("session_id", .text).notNull()
        table.column("operation_id", .text).unique()
        table.column("item_identity", .text).notNull()
        table.column("destination_id", .text).indexed()
        table.column("source", .text).notNull()
        table.column("is_active", .boolean).notNull()
        table.column("payload_json", .blob).notNull()
        table.column("created_at", .datetime).notNull()
      }
      try db.create(table: "naming_rule_suggestions") { table in
        table.column("id", .text).primaryKey()
        table.column("workspace_id", .text).notNull().indexed()
        table.column("state", .text).notNull()
        table.column("payload_json", .blob).notNull()
      }
    }
    migrator.registerMigration("v2.3-file-concepts") { db in
      try db.create(table: "file_concepts") { table in
        table.column("id", .text).primaryKey()
        table.column("parent_id", .text).indexed()
        table.column("name_key", .text).notNull().unique()
        table.column("payload_json", .blob).notNull()
        table.column("created_at", .datetime).notNull()
      }
      try db.create(table: "concept_examples") { table in
        table.column("id", .text).primaryKey()
        table.column("concept_id", .text).notNull().indexed()
          .references("file_concepts", onDelete: .cascade)
        table.column("item_identity", .text).notNull()
        table.column("is_positive", .boolean).notNull()
        table.column("model_version", .text).notNull()
        table.column("payload_json", .blob).notNull()
        table.column("created_at", .datetime).notNull()
        table.uniqueKey(["concept_id", "item_identity"])
      }
    }
    try migrator.migrate(queue)
  }

  private func encode<T: Encodable>(_ value: T) throws -> Data {
    do { return try encoder.encode(value) } catch {
      throw OrganizerError.persistenceFailed("编码数据失败：\(error.localizedDescription)")
    }
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do { return try decoder.decode(type, from: data) } catch {
      throw OrganizerError.persistenceFailed("读取数据失败：\(error.localizedDescription)")
    }
  }

  public func saveWorkspace(_ workspace: Workspace) throws {
    let payload = try encode(workspace)
    try queue.write { db in
      try db.execute(sql: "UPDATE workspaces SET is_active = 0")
      try db.execute(
        sql: """
          INSERT INTO workspaces
          (id, inbox_path, library_path, inbox_bookmark, library_bookmark,
           inbox_volume_id, library_volume_id, payload_json, created_at, is_active)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
          ON CONFLICT(id) DO UPDATE SET
          inbox_path = excluded.inbox_path, library_path = excluded.library_path,
          inbox_bookmark = excluded.inbox_bookmark, library_bookmark = excluded.library_bookmark,
          inbox_volume_id = excluded.inbox_volume_id,
          library_volume_id = excluded.library_volume_id, payload_json = excluded.payload_json,
          is_active = 1
          """,
        arguments: [
          workspace.id.uuidString, workspace.inboxPath, workspace.libraryPath,
          workspace.inboxBookmark, workspace.libraryBookmark, workspace.inboxVolumeID,
          workspace.libraryVolumeID, payload, workspace.createdAt,
        ]
      )
    }
  }

  public func latestWorkspace() throws -> Workspace? {
    try queue.read { db in
      guard
        let data: Data = try Data.fetchOne(
          db,
          sql: "SELECT payload_json FROM workspaces WHERE is_active = 1 ORDER BY created_at DESC LIMIT 1"
        )
      else { return nil }
      return try decode(Workspace.self, from: data)
    }
  }

  public func clearWorkspaces() throws {
    try queue.write { db in
      try db.execute(sql: "DELETE FROM workspaces")
    }
  }

  public func deactivateWorkspaces() throws {
    try queue.write { db in try db.execute(sql: "UPDATE workspaces SET is_active = 0") }
  }

  public func saveSession(_ session: OrganizationSession) throws {
    let payload = try encode(session)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions (id, workspace_id, state, payload_json, started_at, finished_at)
          VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET state = excluded.state,
          payload_json = excluded.payload_json, finished_at = excluded.finished_at
          """,
        arguments: [
          session.id.uuidString, session.workspaceID.uuidString,
          session.state.rawValue, payload, session.startedAt, session.finishedAt,
        ]
      )
    }
  }

  public func saveSnapshots(_ snapshots: [ItemSnapshot]) throws {
    let rows = try snapshots.map { ($0, try encode($0)) }
    try queue.write { db in
      for (item, payload) in rows {
        try db.execute(
          sql:
            "INSERT OR REPLACE INTO item_snapshots (id, session_id, path, payload_json) VALUES (?, ?, ?, ?)",
          arguments: [item.id.uuidString, item.sessionID.uuidString, item.path, payload]
        )
      }
    }
  }

  public func saveProposals(_ proposals: [ClassificationProposal]) throws {
    let rows = try proposals.map { ($0, try encode($0)) }
    try queue.write { db in
      for (proposal, payload) in rows {
        try db.execute(
          sql:
            "INSERT OR REPLACE INTO proposals (id, session_id, item_id, status, payload_json) VALUES (?, ?, ?, ?, ?)",
          arguments: [
            proposal.id.uuidString, proposal.sessionID.uuidString,
            proposal.itemID.uuidString, proposal.status.rawValue, payload,
          ]
        )
      }
    }
  }

  public func saveRenameProposals(_ proposals: [RenameProposal]) throws {
    let rows = try proposals.map { ($0, try encode($0)) }
    try queue.write { db in
      for (proposal, payload) in rows {
        try db.execute(
          sql: """
            INSERT INTO rename_proposals (id, session_id, item_id, disposition, payload_json)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(session_id, item_id) DO UPDATE SET
            id = excluded.id, disposition = excluded.disposition, payload_json = excluded.payload_json
            """,
          arguments: [
            proposal.id.uuidString, proposal.sessionID.uuidString, proposal.itemID.uuidString,
            proposal.disposition.rawValue, payload,
          ])
      }
    }
  }

  public func renameProposals(sessionID: UUID) throws -> [RenameProposal] {
    try queue.read { db in
      try Data.fetchAll(
        db,
        sql: "SELECT payload_json FROM rename_proposals WHERE session_id = ? ORDER BY rowid",
        arguments: [sessionID.uuidString]
      ).map { try decode(RenameProposal.self, from: $0) }
    }
  }

  public func saveFolderProposals(_ proposals: [FolderProposal]) throws {
    let rows = try proposals.map { ($0, try encode($0)) }
    try queue.write { db in
      for (proposal, payload) in rows {
        try db.execute(
          sql: """
            INSERT INTO folder_proposals (id, session_id, normalized_name, status, payload_json)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(session_id, normalized_name) DO UPDATE SET
            status = excluded.status, payload_json = excluded.payload_json
            """,
          arguments: [
            proposal.id.uuidString, proposal.sessionID.uuidString,
            proposal.normalizedName, proposal.status.rawValue, payload,
          ]
        )
      }
    }
  }

  public func savePlan(_ plan: OrganizationPlan) throws {
    let planPayload = try encode(plan)
    let operations = try plan.operations.map { ($0, try encode($0)) }
    try queue.write { db in
      try db.execute(
        sql:
          "INSERT OR IGNORE INTO plans (id, session_id, status, payload_json, confirmed_at) VALUES (?, ?, 'confirmed', ?, ?)",
        arguments: [plan.id.uuidString, plan.sessionID.uuidString, planPayload, plan.confirmedAt]
      )
      for (operation, payload) in operations {
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO operations
            (id, plan_id, sequence, kind, source_path, destination_path, state, payload_json, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            operation.id.uuidString, plan.id.uuidString, operation.sequence,
            operation.kind.rawValue, operation.sourcePath, operation.destinationPath,
            OperationState.pending.rawValue, payload, Date(),
          ]
        )
      }
    }
  }

  public func updateOperation(_ id: UUID, state: OperationState, error: String? = nil) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE operations SET state = ?, error = ?, updated_at = ? WHERE id = ?",
        arguments: [state.rawValue, error, Date(), id.uuidString]
      )
    }
  }

  public func finishOperation(
    _ id: UUID,
    state: OperationState,
    error: String? = nil,
    learningSample: LearningSample? = nil,
    namingSample: NamingSample? = nil
  ) throws {
    let samplePayload = try learningSample.map(encode)
    let namingPayload = try namingSample.map(encode)
    try queue.write { db in
      try db.execute(
        sql: "UPDATE operations SET state = ?, error = ?, updated_at = ? WHERE id = ?",
        arguments: [state.rawValue, error, Date(), id.uuidString])
      if let sample = learningSample, let payload = samplePayload {
        try db.execute(
          sql: """
            INSERT INTO learning_events (id, operation_id, state, payload_json)
            VALUES (?, ?, 'active', ?)
            ON CONFLICT(operation_id) DO UPDATE SET state = 'active', payload_json = excluded.payload_json
            """,
          arguments: [UUID().uuidString, id.uuidString, payload])
        try db.execute(
          sql: """
            INSERT INTO learning_samples
            (id, library_id, operation_id, item_identity, destination_id, is_active, payload_json, created_at)
            VALUES (?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(operation_id) DO UPDATE SET
            library_id = excluded.library_id,
            item_identity = excluded.item_identity,
            destination_id = excluded.destination_id,
            is_active = 1,
            payload_json = excluded.payload_json,
            created_at = excluded.created_at
            """,
          arguments: [
            sample.id.uuidString, sample.libraryID.uuidString, id.uuidString,
            sample.itemIdentity, sample.destinationID.uuidString, payload, sample.createdAt,
          ])
      }
      if let sample = namingSample, let payload = namingPayload {
        try db.execute(
          sql: """
            INSERT INTO naming_samples
            (id, workspace_id, session_id, operation_id, item_identity, destination_id,
             source, is_active, payload_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(operation_id) DO UPDATE SET
            is_active = 1, payload_json = excluded.payload_json, created_at = excluded.created_at
            """,
          arguments: [
            sample.id.uuidString, sample.workspaceID.uuidString, sample.sessionID.uuidString,
            id.uuidString, sample.itemIdentity, sample.destinationID?.uuidString,
            sample.source.rawValue, payload, sample.createdAt,
          ])
      }
    }
  }

  public func finishUndoOperation(_ id: UUID, result: OperationResult) throws {
    try queue.write { db in
      let persistedState: OperationState = result.state == .blocked ? .undoBlocked : result.state
      try db.execute(
        sql: "UPDATE operations SET state = ?, error = ?, updated_at = ? WHERE id = ?",
        arguments: [persistedState.rawValue, result.error, Date(), id.uuidString])
      guard result.state == .undone else { return }
      if let data: Data = try Data.fetchOne(
        db, sql: "SELECT payload_json FROM learning_samples WHERE operation_id = ?",
        arguments: [id.uuidString])
      {
        var sample = try decode(LearningSample.self, from: data)
        sample.isActive = false
        try db.execute(
          sql: "UPDATE learning_samples SET is_active = 0, payload_json = ? WHERE operation_id = ?",
          arguments: [try encode(sample), id.uuidString])
        try db.execute(
          sql: "UPDATE learning_events SET state = 'retracted' WHERE operation_id = ?",
          arguments: [id.uuidString])
      }
      if let data: Data = try Data.fetchOne(
        db, sql: "SELECT payload_json FROM naming_samples WHERE operation_id = ?",
        arguments: [id.uuidString])
      {
        var sample = try decode(NamingSample.self, from: data)
        sample.isActive = false
        try db.execute(
          sql: "UPDATE naming_samples SET is_active = 0, payload_json = ? WHERE operation_id = ?",
          arguments: [try encode(sample), id.uuidString])
      }
    }
  }

  public func operationStates(planID: UUID) throws -> [UUID: OperationState] {
    try queue.read { db in
      let rows = try Row.fetchAll(
        db, sql: "SELECT id, state FROM operations WHERE plan_id = ?",
        arguments: [planID.uuidString])
      return Dictionary(
        uniqueKeysWithValues: rows.compactMap { row in
          guard let id = UUID(uuidString: row["id"]),
            let state = OperationState(rawValue: row["state"])
          else { return nil }
          return (id, state)
        })
    }
  }

  public func saveReceipt(_ receipt: ExecutionReceipt) throws {
    let payload = try encode(receipt)
    try queue.write { db in
      try db.execute(
        sql: "UPDATE plans SET status = ?, receipt_json = ? WHERE id = ?",
        arguments: [
          !receipt.isFinal || receipt.wasCancelled
            || receipt.results.contains(where: { $0.state == .failed || $0.state == .blocked })
            ? "partial" : "completed",
          payload, receipt.planID.uuidString,
        ]
      )
    }
  }

  public func receipt(planID: UUID) throws -> ExecutionReceipt? {
    try queue.read { db in
      guard
        let data: Data = try Data.fetchOne(
          db, sql: "SELECT receipt_json FROM plans WHERE id = ?", arguments: [planID.uuidString]
        )
      else { return nil }
      return try decode(ExecutionReceipt.self, from: data)
    }
  }

  public func plan(id: UUID) throws -> OrganizationPlan? {
    try queue.read { db in
      guard let data: Data = try Data.fetchOne(
        db, sql: "SELECT payload_json FROM plans WHERE id = ?", arguments: [id.uuidString]
      ) else { return nil }
      return try decode(OrganizationPlan.self, from: data)
    }
  }

  public func plans(workspaceID: UUID) throws -> [OrganizationPlan] {
    try queue.read { db in
      let rows = try Data.fetchAll(
        db,
        sql: """
          SELECT plans.payload_json FROM plans
          JOIN sessions ON sessions.id = plans.session_id
          WHERE sessions.workspace_id = ?
          ORDER BY plans.confirmed_at DESC
          """,
        arguments: [workspaceID.uuidString]
      )
      return try rows.map { try decode(OrganizationPlan.self, from: $0) }
    }
  }

  public func saveLearningSample(_ sample: LearningSample) throws {
    let payload = try encode(sample)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO learning_samples
          (id, library_id, operation_id, item_identity, destination_id, is_active, payload_json, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(operation_id) DO NOTHING
          """,
        arguments: [
          sample.id.uuidString,
          sample.libraryID.uuidString,
          sample.operationID?.uuidString,
          sample.itemIdentity,
          sample.destinationID.uuidString,
          sample.isActive,
          payload,
          sample.createdAt,
        ]
      )
    }
  }

  public func concepts() throws -> [FileConcept] {
    try queue.read { db in
      try Data.fetchAll(db, sql: "SELECT payload_json FROM file_concepts ORDER BY created_at, id")
        .map { try decode(FileConcept.self, from: $0) }
    }
  }

  public func saveConcept(_ concept: FileConcept) throws {
    let payload = try encode(concept)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO file_concepts (id, parent_id, name_key, payload_json, created_at)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET parent_id = excluded.parent_id,
          name_key = excluded.name_key, payload_json = excluded.payload_json
          """,
        arguments: [concept.id.uuidString, concept.parentID?.uuidString,
          RuleCondition.normalize(concept.name), payload, concept.createdAt])
    }
  }

  public func deleteConcept(_ conceptID: UUID) throws {
    try queue.write { db in
      let children = try Data.fetchAll(db,
        sql: "SELECT payload_json FROM file_concepts WHERE parent_id = ?",
        arguments: [conceptID.uuidString])
      for data in children {
        var child = try decode(FileConcept.self, from: data)
        child.parentID = nil
        try db.execute(
          sql: "UPDATE file_concepts SET parent_id = NULL, payload_json = ? WHERE id = ?",
          arguments: [try encode(child), child.id.uuidString])
      }
      try db.execute(sql: "DELETE FROM file_concepts WHERE id = ?",
        arguments: [conceptID.uuidString])
    }
  }

  public func conceptExamples(conceptID: UUID) throws -> [ConceptExample] {
    try queue.read { db in
      try Data.fetchAll(db,
        sql: "SELECT payload_json FROM concept_examples WHERE concept_id = ? ORDER BY created_at, id",
        arguments: [conceptID.uuidString])
        .map { try decode(ConceptExample.self, from: $0) }
    }
  }

  public func saveConceptExample(_ example: ConceptExample) throws {
    let payload = try encode(example)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO concept_examples
          (id, concept_id, item_identity, is_positive, model_version, payload_json, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(concept_id, item_identity) DO UPDATE SET id = excluded.id,
          is_positive = excluded.is_positive, model_version = excluded.model_version,
          payload_json = excluded.payload_json, created_at = excluded.created_at
          """,
        arguments: [example.id.uuidString, example.conceptID.uuidString,
          example.itemIdentity, example.isPositive, example.features.modelVersion,
          payload, example.createdAt])
    }
  }

  public func deleteConceptExample(_ exampleID: UUID) throws {
    try queue.write { db in
      try db.execute(sql: "DELETE FROM concept_examples WHERE id = ?",
        arguments: [exampleID.uuidString])
    }
  }

  public func saveRule(_ rule: OrganizationRule) throws {
    let payload = try encode(rule)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO organization_rules
          (id, workspace_id, destination_id, action, is_enabled, payload_json)
          VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET destination_id = excluded.destination_id,
          action = excluded.action, is_enabled = excluded.is_enabled,
          payload_json = excluded.payload_json
          """,
        arguments: [
          rule.id.uuidString, rule.workspaceID.uuidString, rule.destinationID?.uuidString,
          rule.action.rawValue, rule.isEnabled, payload,
        ]
      )
    }
  }

  public func rules(workspaceID: UUID) throws -> [OrganizationRule] {
    try queue.read { db in
      try Data.fetchAll(
        db,
        sql: "SELECT payload_json FROM organization_rules WHERE workspace_id = ? ORDER BY rowid",
        arguments: [workspaceID.uuidString]
      ).map { try decode(OrganizationRule.self, from: $0) }
    }
  }

  public func deleteRule(_ id: UUID) throws {
    try queue.write { db in
      try db.execute(sql: "DELETE FROM organization_rules WHERE id = ?", arguments: [id.uuidString])
    }
  }

  public func saveNamingRule(_ rule: NamingRule) throws {
    let payload = try encode(rule)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO naming_rules (id, workspace_id, is_enabled, payload_json)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET is_enabled = excluded.is_enabled,
          payload_json = excluded.payload_json
          """,
        arguments: [rule.id.uuidString, rule.workspaceID.uuidString, rule.isEnabled, payload])
    }
  }

  public func namingRules(workspaceID: UUID) throws -> [NamingRule] {
    try queue.read { db in
      try Data.fetchAll(
        db,
        sql: "SELECT payload_json FROM naming_rules WHERE workspace_id = ? ORDER BY rowid",
        arguments: [workspaceID.uuidString]
      ).map { try decode(NamingRule.self, from: $0) }
    }
  }

  public func deleteNamingRule(_ id: UUID) throws {
    try queue.write { db in
      try db.execute(sql: "DELETE FROM naming_rules WHERE id = ?", arguments: [id.uuidString])
    }
  }

  public func saveNamingSample(_ sample: NamingSample) throws {
    let payload = try encode(sample)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO naming_samples
          (id, workspace_id, session_id, operation_id, item_identity, destination_id,
           source, is_active, payload_json, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(operation_id) DO NOTHING
          """,
        arguments: [
          sample.id.uuidString, sample.workspaceID.uuidString, sample.sessionID.uuidString,
          sample.operationID?.uuidString, sample.itemIdentity, sample.destinationID?.uuidString,
          sample.source.rawValue, sample.isActive, payload, sample.createdAt,
        ])
    }
  }

  public func namingSamples(workspaceID: UUID, activeOnly: Bool = false) throws
    -> [NamingSample]
  {
    try queue.read { db in
      let suffix = activeOnly ? " AND is_active = 1" : ""
      return try Data.fetchAll(
        db,
        sql: "SELECT payload_json FROM naming_samples WHERE workspace_id = ?\(suffix) ORDER BY created_at",
        arguments: [workspaceID.uuidString]
      ).map { try decode(NamingSample.self, from: $0) }
    }
  }

  public func namingSamples(destinationID: UUID, activeOnly: Bool = false) throws
    -> [NamingSample]
  {
    try queue.read { db in
      let suffix = activeOnly ? " AND is_active = 1" : ""
      return try Data.fetchAll(
        db,
        sql: "SELECT payload_json FROM naming_samples WHERE destination_id = ?\(suffix) ORDER BY created_at",
        arguments: [destinationID.uuidString]
      ).map { try decode(NamingSample.self, from: $0) }
    }
  }

  public func replaceExistingNamingSamples(workspaceID: UUID, samples: [NamingSample]) throws {
    let rows = try samples.map { ($0, try encode($0)) }
    try queue.write { db in
      try db.execute(
        sql: "DELETE FROM naming_samples WHERE workspace_id = ? AND source = ?",
        arguments: [workspaceID.uuidString, NamingSampleSource.existingLibrary.rawValue])
      for (sample, payload) in rows {
        try db.execute(
          sql: """
            INSERT INTO naming_samples
            (id, workspace_id, session_id, operation_id, item_identity, destination_id,
             source, is_active, payload_json, created_at)
            VALUES (?, ?, ?, NULL, ?, ?, ?, 1, ?, ?)
            """,
          arguments: [
            sample.id.uuidString, sample.workspaceID.uuidString, sample.sessionID.uuidString,
            sample.itemIdentity, sample.destinationID?.uuidString, sample.source.rawValue,
            payload, sample.createdAt,
          ])
      }
    }
  }

  public func retractNamingSample(operationID: UUID) throws {
    try queue.write { db in
      guard let data: Data = try Data.fetchOne(
        db, sql: "SELECT payload_json FROM naming_samples WHERE operation_id = ?",
        arguments: [operationID.uuidString])
      else { return }
      var sample = try decode(NamingSample.self, from: data)
      sample.isActive = false
      try db.execute(
        sql: "UPDATE naming_samples SET is_active = 0, payload_json = ? WHERE operation_id = ?",
        arguments: [try encode(sample), operationID.uuidString])
    }
  }

  public func replaceNamingRuleSuggestions(
    workspaceID: UUID, suggestions: [NamingRuleSuggestion]
  ) throws {
    let rows = try suggestions.map { ($0, try encode($0)) }
    try queue.write { db in
      try db.execute(
        sql: "DELETE FROM naming_rule_suggestions WHERE workspace_id = ? AND state = 'pending'",
        arguments: [workspaceID.uuidString])
      for (suggestion, payload) in rows {
        try db.execute(
          sql: """
            INSERT INTO naming_rule_suggestions (id, workspace_id, state, payload_json)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
            payload_json = CASE WHEN naming_rule_suggestions.state = 'pending'
              THEN excluded.payload_json ELSE naming_rule_suggestions.payload_json END
            """,
          arguments: [
            suggestion.id.uuidString, suggestion.workspaceID.uuidString,
            suggestion.state.rawValue, payload,
          ])
      }
    }
  }

  public func namingRuleSuggestions(workspaceID: UUID) throws -> [NamingRuleSuggestion] {
    try queue.read { db in
      try Data.fetchAll(
        db,
        sql: "SELECT payload_json FROM naming_rule_suggestions WHERE workspace_id = ? ORDER BY rowid",
        arguments: [workspaceID.uuidString]
      ).map { try decode(NamingRuleSuggestion.self, from: $0) }
    }
  }

  public func saveNamingRuleSuggestion(_ suggestion: NamingRuleSuggestion) throws {
    let payload = try encode(suggestion)
    try queue.write { db in
      try db.execute(
        sql: "UPDATE naming_rule_suggestions SET state = ?, payload_json = ? WHERE id = ?",
        arguments: [suggestion.state.rawValue, payload, suggestion.id.uuidString])
    }
  }

  public func learningSamples(libraryID: UUID, activeOnly: Bool = false) throws
    -> [LearningSample]
  {
    try queue.read { db in
      let sql = activeOnly
        ? "SELECT payload_json FROM learning_samples WHERE library_id = ? AND is_active = 1 ORDER BY created_at"
        : "SELECT payload_json FROM learning_samples WHERE library_id = ? ORDER BY created_at"
      return try Data.fetchAll(db, sql: sql, arguments: [libraryID.uuidString]).map {
        try decode(LearningSample.self, from: $0)
      }
    }
  }

  public func replaceExistingLibrarySamples(libraryID: UUID, samples: [LearningSample]) throws {
    let rows = try samples.map { ($0, try encode($0)) }
    try queue.write { db in
      try db.execute(
        sql: "DELETE FROM learning_samples WHERE library_id = ? AND operation_id IS NULL",
        arguments: [libraryID.uuidString])
      for (sample, payload) in rows {
        try db.execute(
          sql: """
            INSERT INTO learning_samples
            (id, library_id, operation_id, item_identity, destination_id, is_active, payload_json, created_at)
            VALUES (?, ?, NULL, ?, ?, 1, ?, ?)
            """,
          arguments: [
            sample.id.uuidString, libraryID.uuidString, sample.itemIdentity,
            sample.destinationID.uuidString, payload, sample.createdAt,
          ])
      }
    }
  }

  public func retractLearningSample(operationID: UUID) throws {
    try queue.write { db in
      guard let data: Data = try Data.fetchOne(
        db,
        sql: "SELECT payload_json FROM learning_samples WHERE operation_id = ?",
        arguments: [operationID.uuidString]
      ) else { return }
      var sample = try decode(LearningSample.self, from: data)
      sample.isActive = false
      try db.execute(
        sql: "UPDATE learning_samples SET is_active = 0, payload_json = ? WHERE operation_id = ?",
        arguments: [try encode(sample), operationID.uuidString]
      )
    }
  }

  public func saveDecision(_ record: DecisionRecord) throws {
    let payload = try encode(record)
    try queue.write { db in
      try db.execute(
        sql:
          "INSERT INTO decision_records (id, session_id, item_id, action, payload_json, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        arguments: [
          record.id.uuidString, record.sessionID.uuidString,
          record.itemID.uuidString, record.action, payload, record.createdAt,
        ]
      )
    }
  }

  public func rowCount(_ table: String) throws -> Int {
    let allowed = [
      "workspaces", "sessions", "item_snapshots", "proposals", "folder_proposals", "plans",
      "operations", "decision_records", "libraries", "destinations", "organization_rules",
      "learning_events", "learning_samples", "rule_suggestions",
      "rename_proposals", "naming_rules", "naming_samples", "naming_rule_suggestions",
      "file_concepts", "concept_examples",
    ]
    guard allowed.contains(table) else { throw OrganizerError.persistenceFailed("未知数据表") }
    return try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
  }
}
