import AIFileOrganizerCore
import Foundation

// 验收评测入口。
//
// 用法：
//   AI_FILE_ORGANIZER_ACCEPTANCE_LIBRARY=/path/to/library \
//   swift run AIFileOrganizerAcceptance [清单路径]
//
// 没有资料库根目录时不会“零样本绿过”：直接以退出码 2 结束并说明原因。
// 可选 AI_FILE_ORGANIZER_TEST_MODEL 指向本地 MobileCLIP 包，用于追加“有图像模型”一档。

struct AcceptanceRunner {
  let manifest: AcceptanceManifest
  let libraryRoot: URL
  let database: AppDatabase

  func run(mode: AcceptanceMode) async throws -> [AcceptanceCaseResult] {
    let roleOverrides = try database.catalogProfileOverrides(workspaceID: workspaceID)
      .compactMapValues { $0.role }
    let index = try LibraryWorkIndexer().index(root: libraryRoot, roleOverrides: roleOverrides)
    let modelManager = mode.modelManager
    let catalog = try await CatalogAnalysisService(
      database: database, modelManager: modelManager
    ).analyze(index: index, workspaceID: workspaceID, root: libraryRoot)

    let workspace = Workspace(
      inboxPath: libraryRoot.path, libraryPath: libraryRoot.path,
      inboxVolumeID: "acceptance", libraryVolumeID: "acceptance")
    let destinations = try DestinationCatalogService().index(
      workspace: workspace, maxDepth: 4, roleOverrides: roleOverrides
    ).filter { $0.kind == .category }
    let pathByID = Dictionary(uniqueKeysWithValues: destinations.map { ($0.id, $0.relativePath) })
    let idByPath = Dictionary(
      uniqueKeysWithValues: destinations.map { ($0.relativePath, $0.id) })

    var results: [AcceptanceCaseResult] = []
    for item in manifest.cases {
      try Task.checkCancellation()
      results.append(
        await evaluate(
          item, destinations: destinations, pathByID: pathByID, idByPath: idByPath,
          catalog: catalog, index: index))
    }
    return results
  }

  private let workspaceID = UUID()

  private func evaluate(
    _ item: AcceptanceCase, destinations: [DestinationProfile],
    pathByID: [UUID: String], idByPath: [String: UUID],
    catalog: CatalogAnalysisResult, index: LibraryWorkIndex
  ) async -> AcceptanceCaseResult {
    let url = item.relativePath.map { libraryRoot.appendingPathComponent($0) }
    let fileExists = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    let snapshot = ItemSnapshot(
      sessionID: workspaceID,
      path: fileExists ? url!.path : libraryRoot.appendingPathComponent(item.name).path,
      name: item.name,
      kind: fileExists ? ((try? url!.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        ? .directory : .file) : .directory,
      fileExtension: fileExists ? url!.pathExtension.lowercased() : "")
    let classifier = DeterministicClassifier()
    var context = classifier.context(for: snapshot)
    if fileExists, let url {
      let extracted = await NativeContentExtractor(maximumPDFPages: 5).extractContext(for: snapshot)
      context = classifier.context(for: snapshot, extracted: extracted)
    }
    let ranked = classifier.rank(context, destinations: destinations, catalog: catalog)
    let proposal = classifier.proposal(sessionID: workspaceID, item: context, candidates: ranked)
    let topPath = ranked.first.flatMap { pathByID[$0.destinationID] }
    let isReady = proposal?.reviewDecision == .ready && proposal?.action == .move

    let expectedID = item.expectedCategory.flatMap { idByPath[$0] }
    let isCorrect: Bool?
    if let expectedID {
      isCorrect = ranked.first?.destinationID == expectedID
    } else {
      isCorrect = nil
    }
    let misrouted = isReady && expectedID != nil && proposal?.destinationID != expectedID
    var creatorCorrect: Bool?
    if let expectedCreator = item.expectedCreator,
      let actual = Self.creatorTarget(proposal: proposal, destinations: destinations,
        pathByID: pathByID)
    {
      creatorCorrect = PathSafety.normalizedFolderKey(actual)
        == PathSafety.normalizedFolderKey(expectedCreator)
    }
    var notes: [String] = []
    if !fileExists, item.relativePath != nil { notes.append("样本路径不存在，仅用名称评测") }
    if item.relativePath == nil { notes.append("无内容样本，仅名称与结构") }
    if index.nodes.isEmpty { notes.append("资料库索引为空") }
    return AcceptanceCaseResult(
      caseID: item.id, group: item.group, split: item.split,
      expectedCategory: item.expectedCategory, topCandidateCategory: topPath,
      isTopChoiceCorrect: isCorrect, isBatchReady: isReady,
      isMisroutedDefaultReady: misrouted, isCreatorCorrect: creatorCorrect,
      note: notes.joined(separator: "；"))
  }

  /// 提案最终指向的作者目录：已绑定现有目录用绑定路径；需要新建时用分类 + 建议目录名。
  static func creatorTarget(
    proposal: ClassificationProposal?, destinations: [DestinationProfile],
    pathByID: [UUID: String]
  ) -> String? {
    guard let proposal else { return nil }
    if let bound = proposal.creatorDestinationPath { return bound }
    guard let name = proposal.suggestedFolderName,
      let destinationID = proposal.destinationID,
      let category = pathByID[destinationID]
    else { return nil }
    return category + "/" + name
  }
}

enum AcceptanceMode {
  case namesOnly
  case withVisualModel(URL)

  var label: String {
    switch self {
    case .namesOnly: return "无图像模型"
    case .withVisualModel: return "有图像模型"
    }
  }

  var modelManager: ConceptModelManager {
    switch self {
    case .namesOnly: return ConceptModelManager(root: URL(fileURLWithPath: "/nonexistent-model"))
    case .withVisualModel(let url): return ConceptModelManager(root: url)
    }
  }
}

// MARK: - 入口

let arguments = CommandLine.arguments
let environment = ProcessInfo.processInfo.environment
let manifestURL = arguments.count > 1
  ? URL(fileURLWithPath: arguments[1])
  : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Evaluation/acceptance/manifest.json")

guard let libraryPath = environment["AI_FILE_ORGANIZER_ACCEPTANCE_LIBRARY"] else {
  FileHandle.standardError.write(Data("""
    缺少 AI_FILE_ORGANIZER_ACCEPTANCE_LIBRARY。
    验收必须针对真实资料库运行；没有样本时本工具不会报告通过。
    用法：AI_FILE_ORGANIZER_ACCEPTANCE_LIBRARY=/path/to/library \\
          swift run AIFileOrganizerAcceptance [清单路径]

    """.utf8))
  exit(2)
}
let libraryRoot = URL(fileURLWithPath: libraryPath, isDirectory: true)
guard FileManager.default.fileExists(atPath: libraryRoot.path) else {
  FileHandle.standardError.write(Data("资料库路径不存在：\(libraryRoot.path)\n".utf8))
  exit(2)
}
guard let manifestData = try? Data(contentsOf: manifestURL) else {
  FileHandle.standardError.write(Data("无法读取清单：\(manifestURL.path)\n".utf8))
  exit(2)
}

let decoder = JSONDecoder()
let manifest: AcceptanceManifest
do {
  manifest = try decoder.decode(AcceptanceManifest.self, from: manifestData)
} catch {
  FileHandle.standardError.write(Data("清单解析失败：\(error)\n".utf8))
  exit(2)
}
let issues = manifest.validationIssues()
guard issues.isEmpty else {
  FileHandle.standardError.write(Data(("清单校验失败：\n- " + issues.joined(separator: "\n- ") + "\n").utf8))
  exit(2)
}

// 真实样本尚未提供时，清单里只有示例条目；此时明确拒绝给出结论。
let realCases = manifest.cases.filter { !$0.id.hasPrefix("sample-") }
guard !realCases.isEmpty else {
  print("清单只包含示例条目（id 以 sample- 开头），没有真实验收样本。")
  print("请先按 Evaluation/acceptance/README.md 补齐至少 50 项留出样本。")
  exit(3)
}

var modes: [AcceptanceMode] = [.namesOnly]
if let modelPath = environment["AI_FILE_ORGANIZER_TEST_MODEL"], !modelPath.isEmpty {
  modes.append(.withVisualModel(URL(fileURLWithPath: modelPath)))
}

var overallExit: Int32 = 0
for mode in modes {
  do {
    let database = try AppDatabase(path: FileManager.default.temporaryDirectory
      .appendingPathComponent("acceptance-\(UUID().uuidString).sqlite").path)
    let results = try await AcceptanceRunner(manifest: manifest, libraryRoot: libraryRoot,
      database: database).run(mode: mode)
    let report = AcceptanceEvaluator.report(results: results)
    print(AcceptanceEvaluator.render(report, mode: mode.label))
    print("")
    if report.passed {
      print("已按 \(mode.label) 通过全部门槛。")
    } else {
      overallExit = 1
    }
  } catch {
    FileHandle.standardError.write(Data("评测失败（\(mode.label)）：\(error)\n".utf8))
    exit(2)
  }
}
exit(overallExit)
