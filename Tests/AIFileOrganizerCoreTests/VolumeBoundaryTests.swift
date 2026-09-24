import Foundation
import Testing

@testable import AIFileOrganizerCore

/// 跨卷拒绝是产品对外的核心安全承诺之一（"V2.3 不跨卷移动"），
/// 但此前没有任何测试构造过卷不匹配的场景：所有夹具都把收件箱与资料库
/// 钉在同一个真实卷上，因此 `SafePlanExecutor.preflight` 的跨卷分支
/// 从未被执行过。
///
/// 注意：这些用例验证的是**守卫逻辑本身**，不是真实的跨设备 I/O——
/// 本机只有一个可写卷，无法把文件真正放到第二块盘上。
/// 真实跨卷需要外置卷或磁盘镜像，见计划中的 P3-1（默认不做）。
@Suite struct VolumeBoundaryTests {
  private struct Fixture {
    let root: URL
    let inbox: URL
    let library: URL
    let docs: URL
    let database: AppDatabase
    let sessionID: UUID
    let volume: String
  }

  /// 只建真实目录与数据库；workspace 由各用例自行构造，以便篡改卷 ID。
  private func makeFixture() throws -> Fixture {
    let root = try temporaryDirectory()
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let docs = library.appendingPathComponent("Docs", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    let sessionID = UUID()
    let database = try AppDatabase.inMemory()
    return Fixture(
      root: root, inbox: inbox, library: library, docs: docs,
      database: database, sessionID: sessionID,
      volume: try PathSafety.volumeIdentifier(for: inbox))
  }

  /// 收件箱/资料库路径都真实存在，但 workspace 记录的卷 ID 与磁盘不符。
  ///
  /// 注意 `execute` 会**先** `savePlan` 再 preflight（`SafePlanExecutor.execute`），
  /// 而 `plans.session_id` 有外键约束，所以要走 `execute` 的用例
  /// 必须把 workspace 与 session 一并入库，否则会先撞上外键错误，
  /// 反而测不到跨卷分支。
  private func mismatchedWorkspace(_ fixture: Fixture, persisted: Bool = false) throws -> Workspace {
    let workspace = Workspace(
      inboxPath: fixture.inbox.path,
      libraryPath: fixture.library.path,
      inboxVolumeID: "not-the-real-volume",
      libraryVolumeID: "not-the-real-volume")
    if persisted {
      try fixture.database.saveWorkspace(workspace)
      try fixture.database.saveSession(
        OrganizationSession(id: fixture.sessionID, workspaceID: workspace.id))
    }
    return workspace
  }

  @Test func movePreflightRejectsVolumeMismatch() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("cross.txt")
    try Data("payload".utf8).write(to: source)
    let operation = PlannedOperation(
      sequence: 0, kind: .move, sourcePath: source.path,
      destinationPath: fixture.docs.appendingPathComponent("cross.txt").path,
      preSnapshot: try .capture(source))
    let plan = OrganizationPlan(sessionID: fixture.sessionID, operations: [operation])

    let report = await SafePlanExecutor(
      workspace: try mismatchedWorkspace(fixture), database: fixture.database
    ).preflight(plan)

    #expect(!report.isReady)
    #expect(report.issues.contains { $0.message.contains("跨卷") })
    #expect(report.issues.contains { $0.operationID == operation.id })
  }

  @Test func renamePreflightRejectsVolumeMismatch() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("before.txt")
    try Data("payload".utf8).write(to: source)
    let operation = PlannedOperation(
      sequence: 0, kind: .rename, sourcePath: source.path,
      destinationPath: fixture.inbox.appendingPathComponent("after.txt").path,
      preSnapshot: try .capture(source))
    let plan = OrganizationPlan(sessionID: fixture.sessionID, operations: [operation])

    let report = await SafePlanExecutor(
      workspace: try mismatchedWorkspace(fixture), database: fixture.database
    ).preflight(plan)

    #expect(!report.isReady)
    // 改名分支只比对收件箱卷（SafePlanExecutor 的 .rename 分支）。
    #expect(report.issues.contains { $0.message.contains("同一卷") })
  }

  @Test func executeRefusesPlanBlockedByVolumeMismatch() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("never-moves.txt")
    try Data("payload".utf8).write(to: source)
    let destination = fixture.docs.appendingPathComponent("never-moves.txt")
    let operation = PlannedOperation(
      sequence: 0, kind: .move, sourcePath: source.path,
      destinationPath: destination.path,
      preSnapshot: try .capture(source))
    let plan = OrganizationPlan(sessionID: fixture.sessionID, operations: [operation])

    let executor = SafePlanExecutor(
      workspace: try mismatchedWorkspace(fixture, persisted: true), database: fixture.database)
    var thrown: (any Error)?
    do {
      for try await _ in executor.execute(plan) {}
    } catch {
      thrown = error
    }

    guard case .planBlocked(let messages) = try #require(thrown as? OrganizerError) else {
      Issue.record("期望 planBlocked，实际为 \(String(describing: thrown))")
      return
    }
    #expect(messages.contains { $0.contains("跨卷") })
    // 被拒绝的计划不得移动任何文件。
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func validateWorkspaceResolvesOneRealVolumeForEveryDirectory() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let (inboxVolume, libraryVolume) = try PathSafety.validateWorkspace(
      inbox: fixture.inbox, library: fixture.library)
    #expect(inboxVolume == libraryVolume)
    #expect(inboxVolume == fixture.volume)

    // 同卷守卫（PathSafety.validateWorkspace）只能靠"两个真实目录是否落在同一卷"
    // 触发；本机没有第二块可写卷，因此这里只确认每个真实目录都解析出同一个真实
    // 卷 ID——无法伪造出"不同卷"。跨卷的执行层守卫由本套件其他用例覆盖。
    #expect(try PathSafety.volumeIdentifier(for: fixture.docs) == fixture.volume)
  }

  @Test func sameVolumeWorkspaceStillExecutesNormally() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("same-volume.txt")
    try Data("payload".utf8).write(to: source)
    let destination = fixture.docs.appendingPathComponent("same-volume.txt")
    let operation = PlannedOperation(
      sequence: 0, kind: .move, sourcePath: source.path,
      destinationPath: destination.path,
      preSnapshot: try .capture(source))
    let plan = OrganizationPlan(sessionID: fixture.sessionID, operations: [operation])
    let workspace = Workspace(
      inboxPath: fixture.inbox.path, libraryPath: fixture.library.path,
      inboxVolumeID: fixture.volume, libraryVolumeID: fixture.volume)
    try fixture.database.saveWorkspace(workspace)
    try fixture.database.saveSession(
      OrganizationSession(id: fixture.sessionID, workspaceID: workspace.id))

    let executor = SafePlanExecutor(workspace: workspace, database: fixture.database)
    // 这条用例是"对照组"：同卷计划仍然正常通过预检并执行，
    // 证明上面的拒绝确实来自卷不匹配而不是夹具本身有毛病。
    let report = await executor.preflight(plan)
    #expect(report.isReady)
    var finished: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let receipt) = event { finished = receipt }
    }
    let receipt = try #require(finished)
    #expect(receipt.results.allSatisfy { $0.state == .completed })
    #expect(FileManager.default.fileExists(atPath: destination.path))
  }
}
