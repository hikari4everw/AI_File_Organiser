import AIFileOrganizerCore
import Foundation

enum CheckFailure: Error, CustomStringConvertible {
  case failed(String)
  var description: String {
    switch self {
    case .failed(let value): value
    }
  }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw CheckFailure.failed(message) }
}

func makeTempDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aifo-check-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private struct EmptyExtractor: ContentExtractor {
  func extractContext(for item: ItemSnapshot) async -> ExtractedContext { .init() }
}

private struct InvalidOutputProvider: ClassificationProvider {
  let itemID: UUID
  var availabilityDescription: String { "测试模型可用" }
  var isAvailable: Bool { true }

  func classify(items: [ItemContext], destinations: [DestinationProfile]) async throws
    -> [ModelProposal]
  {
    [
      ModelProposal(
        itemID: itemID,
        action: .move,
        destinationID: UUID(),
        reason: String(repeating: "x", count: 400)
      ),
      ModelProposal(
        itemID: itemID,
        action: .suggestFolder,
        suggestedFolderName: "../escape",
        reason: "越界"
      ),
    ]
  }
}

@main
struct CoreChecks {
  static func main() async throws {
    var completed = 0
    try checkPathSafety()
    completed += 1
    try checkDatabase()
    completed += 1
    try await checkScanner()
    completed += 1
    try checkClassification()
    completed += 1
    try checkHundredCaseBaseline()
    completed += 1
    try await checkInvalidModelOutput()
    completed += 1
    try await checkExecutionAndUndo()
    completed += 1
    try await checkNewFolderAndUndo()
    completed += 1
    try await checkConflictBlocking()
    completed += 1
    try await checkChangedSourceBlocking()
    completed += 1
    try await checkCrashRecovery()
    completed += 1
    print("AI File Organizer core checks: \(completed)/11 passed")
  }

  static func checkPathSafety() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    let volumes = try PathSafety.validateWorkspace(inbox: inbox, library: library)
    try require(volumes.0 == volumes.1, "同卷目录验证失败")
    do {
      _ = try PathSafety.validateWorkspace(inbox: root, library: inbox)
      throw CheckFailure.failed("未阻止互相包含的目录")
    } catch is OrganizerError {}
    do {
      _ = try PathSafety.validateFolderName("../escape")
      throw CheckFailure.failed("未阻止非法目录名")
    } catch is OrganizerError {}
  }

  static func checkDatabase() throws {
    let database = try AppDatabase.inMemory()
    let expected = [
      "workspaces", "sessions", "item_snapshots", "proposals", "folder_proposals", "plans",
      "operations", "decision_records",
    ]
    for table in expected {
      let count = try database.rowCount(table)
      try require(count == 0, "数据表 \(table) 初始化失败")
    }
    let workspace = Workspace(
      inboxPath: "/tmp/inbox", libraryPath: "/tmp/library",
      inboxVolumeID: "volume", libraryVolumeID: "volume"
    )
    try database.saveWorkspace(workspace)
    let loaded = try database.latestWorkspace()
    try require(loaded?.id == workspace.id, "Workspace 持久化失败")
  }

  static func checkScanner() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: inbox.appendingPathComponent("note.txt"))
    let nested = inbox.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data().write(to: nested.appendingPathComponent("nested.pdf"))
    try Data().write(to: inbox.appendingPathComponent(".hidden"))
    let volume = try PathSafety.volumeIdentifier(for: inbox)
    let workspace = Workspace(
      inboxPath: inbox.path, libraryPath: library.path,
      inboxVolumeID: volume, libraryVolumeID: volume
    )
    var names: Set<String> = []
    for try await event in LocalInboxScanner().scan(workspace, sessionID: UUID()) {
      if case .discovered(let item) = event { names.insert(item.name) }
    }
    try require(names == ["note.txt", "Folder"], "扫描未保持直接子项边界：\(names)")
  }

  static func checkClassification() throws {
    let session = UUID()
    let item = ItemSnapshot(
      sessionID: session, path: "/tmp/photo.jpg", name: "photo.jpg",
      kind: .file, contentType: "public.jpeg", fileExtension: "jpg"
    )
    let destination = DestinationProfile(relativePath: "图片", displayName: "图片", keywords: ["图片"])
    let classifier = DeterministicClassifier()
    let context = classifier.context(for: item)
    let candidates = classifier.rank(context, destinations: [destination])
    try require(candidates.first?.destinationID == destination.id, "图片候选排序失败")
    try require(
      classifier.proposal(sessionID: session, item: context, candidates: candidates)?.reviewDecision
        == .ready,
      "明确分类未进入可整理状态"
    )
  }

  static func checkHundredCaseBaseline() throws {
    let session = UUID()
    let specifications: [(String, [String])] = [
      ("图片", ["jpg", "png", "heic", "gif", "webp"]),
      ("文档", ["txt", "md", "rtf", "doc", "docx"]),
      ("PDF", ["pdf"]),
      ("音乐", ["mp3", "m4a", "wav", "flac", "aac"]),
      ("视频", ["mp4", "mov", "mkv", "m4v", "avi"]),
      ("压缩包", ["zip", "7z", "rar", "tar", "gz"]),
      ("安装包", ["dmg", "pkg"]),
      ("表格", ["xls", "xlsx", "csv", "numbers", "tsv"]),
      ("演示", ["ppt", "pptx", "key", "pps", "odp"]),
    ]
    let destinations = specifications.map {
      DestinationProfile(relativePath: $0.0, displayName: $0.0, keywords: [$0.0])
    }
    let classifier = DeterministicClassifier()
    var evaluated = 0
    for (index, specification) in specifications.enumerated() {
      for itemIndex in 0..<10 {
        let ext = specification.1[itemIndex % specification.1.count]
        let item = ItemSnapshot(
          sessionID: session,
          path: "/tmp/sample-\(itemIndex).\(ext)",
          name: "sample-\(itemIndex).\(ext)",
          kind: .file,
          fileExtension: ext
        )
        let context = classifier.context(for: item)
        let candidates = classifier.rank(context, destinations: destinations)
        try require(candidates.first?.destinationID == destinations[index].id, "100 项基线分类错误：\(ext)")
        evaluated += 1
      }
    }
    for itemIndex in 0..<10 {
      let item = ItemSnapshot(
        sessionID: session,
        path: "/tmp/unknown-\(itemIndex).bin",
        name: "unknown-\(itemIndex).bin",
        kind: .file,
        fileExtension: "bin"
      )
      let context = classifier.context(for: item)
      try require(classifier.rank(context, destinations: destinations).isEmpty, "未知文件被强行分类")
      evaluated += 1
    }
    try require(evaluated == 100, "评测基线数量不正确")
  }

  static func checkInvalidModelOutput() async throws {
    let session = UUID()
    let item = ItemSnapshot(
      sessionID: session,
      path: "/tmp/untrusted.bin",
      name: "untrusted.bin",
      kind: .file,
      fileExtension: "bin"
    )
    let destination = DestinationProfile(relativePath: "文档", displayName: "文档")
    let pipeline = ClassificationPipeline(
      extractor: EmptyExtractor(),
      provider: InvalidOutputProvider(itemID: item.id)
    )
    let result = await pipeline.run(
      sessionID: session,
      items: [item],
      destinations: [destination]
    )
    try require(result.folderProposals.isEmpty, "非法目录建议进入了目录提案")
    try require(result.proposals.first?.destinationID == nil, "越界候选 ID 被接受")
    try require(result.proposals.first?.reviewDecision == .needsReview, "非法模型输出未强制审核")
  }

  static func checkExecutionAndUndo() async throws {
    let fixture = try executionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("report.txt")
    try Data("original".utf8).write(to: source)
    let item = ItemSnapshot(
      sessionID: fixture.sessionID, path: source.path, name: source.lastPathComponent, kind: .file)
    let destination = DestinationProfile(relativePath: "Docs", displayName: "Docs")
    let proposal = ClassificationProposal(
      sessionID: fixture.sessionID, itemID: item.id, action: .move,
      destinationID: destination.id, source: .user, reviewDecision: .ready,
      status: .approved, reason: "check"
    )
    let plan = try PlanBuilder().build(
      sessionID: fixture.sessionID, workspace: fixture.workspace,
      items: [item], destinations: [destination], proposals: [proposal], folderProposals: []
    )
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
    let preflight = await executor.preflight(plan)
    try require(preflight.isReady, "有效计划预检失败")
    var receipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { receipt = value }
    }
    let moved = fixture.docs.appendingPathComponent("report.txt")
    try require(FileManager.default.fileExists(atPath: moved.path), "文件未移动")
    guard let receipt else { throw CheckFailure.failed("执行未生成回执") }
    for try await _ in executor.undo(plan: plan, receipt: receipt) {}
    try require(FileManager.default.fileExists(atPath: source.path), "撤销未恢复文件")
    try require(!FileManager.default.fileExists(atPath: moved.path), "撤销后目标仍存在")
  }

  static func checkConflictBlocking() async throws {
    let fixture = try executionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("same.txt")
    let target = fixture.docs.appendingPathComponent("same.txt")
    try Data("source".utf8).write(to: source)
    try Data("target".utf8).write(to: target)
    let operation = PlannedOperation(
      sequence: 0, kind: .move, sourcePath: source.path,
      destinationPath: target.path, preSnapshot: try .capture(source)
    )
    let report = await SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
      .preflight(OrganizationPlan(sessionID: fixture.sessionID, operations: [operation]))
    try require(!report.isReady, "同名目标未被阻止")
    try require(report.issues.contains { $0.message.contains("目标已存在") }, "同名冲突原因不明确")
  }

  static func checkNewFolderAndUndo() async throws {
    let fixture = try executionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("paper.pdf")
    try Data("paper".utf8).write(to: source)
    let item = ItemSnapshot(
      sessionID: fixture.sessionID,
      path: source.path,
      name: source.lastPathComponent,
      kind: .file
    )
    let folder = FolderProposal(
      sessionID: fixture.sessionID,
      normalizedName: "research",
      displayName: "Research",
      status: .approved,
      relatedItemIDs: [item.id]
    )
    let plan = try PlanBuilder().build(
      sessionID: fixture.sessionID,
      workspace: fixture.workspace,
      items: [item],
      destinations: [],
      proposals: [],
      folderProposals: [folder]
    )
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
    var receipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { receipt = value }
    }
    let directory = fixture.library.appendingPathComponent("Research", isDirectory: true)
    try require(FileManager.default.fileExists(atPath: directory.path), "批准的新目录未创建")
    guard let receipt else { throw CheckFailure.failed("新目录执行没有回执") }
    for try await _ in executor.undo(plan: plan, receipt: receipt) {}
    try require(!FileManager.default.fileExists(atPath: directory.path), "撤销后空目录未删除")
    try require(FileManager.default.fileExists(atPath: source.path), "新目录撤销未恢复文件")
  }

  static func checkChangedSourceBlocking() async throws {
    let fixture = try executionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("changing.txt")
    try Data("before".utf8).write(to: source)
    let operation = PlannedOperation(
      sequence: 0,
      kind: .move,
      sourcePath: source.path,
      destinationPath: fixture.docs.appendingPathComponent("changing.txt").path,
      preSnapshot: try .capture(source)
    )
    try Data("after and a different size".utf8).write(to: source)
    let report = await SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
      .preflight(OrganizationPlan(sessionID: fixture.sessionID, operations: [operation]))
    try require(!report.isReady, "源文件变化后仍通过预检")
  }

  static func checkCrashRecovery() async throws {
    let fixture = try executionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("recover.txt")
    let destination = fixture.docs.appendingPathComponent("recover.txt")
    try Data("recoverable".utf8).write(to: source)
    let operation = PlannedOperation(
      sequence: 0,
      kind: .move,
      sourcePath: source.path,
      destinationPath: destination.path,
      preSnapshot: try .capture(source)
    )
    let plan = OrganizationPlan(sessionID: fixture.sessionID, operations: [operation])
    try fixture.database.savePlan(plan)
    try fixture.database.updateOperation(operation.id, state: .running)
    try FileManager.default.moveItem(at: source, to: destination)
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
    var receipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { receipt = value }
    }
    try require(receipt?.results.first?.state == .completed, "崩溃恢复未识别已完成移动")
    try require(FileManager.default.fileExists(atPath: destination.path), "崩溃恢复破坏了目标文件")
  }

  static func executionFixture() throws -> (
    root: URL, inbox: URL, library: URL, docs: URL,
    workspace: Workspace, database: AppDatabase, sessionID: UUID
  ) {
    let root = try makeTempDirectory()
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
