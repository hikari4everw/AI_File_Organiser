import AIFileOrganizerCore
import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
  @Published var workspace: Workspace?
  @Published var session: OrganizationSession?
  @Published var items: [ItemSnapshot] = []
  @Published var destinations: [DestinationProfile] = []
  @Published var proposals: [ClassificationProposal] = []
  @Published var folderProposals: [FolderProposal] = []
  @Published var renameProposals: [RenameProposal] = []
  @Published var selectedItemIDs: Set<UUID> = []
  @Published var selectedItemID: UUID?
  @Published var statusMessage = ""
  @Published var modelStatus = "正在检查本地模型…"
  @Published var isWorking = false
  @Published var discoveredCount = 0
  @Published var skippedCount = 0
  @Published var progress: OrganizationProgress?
  @Published var currentPlan: OrganizationPlan?
  @Published var receipt: ExecutionReceipt?
  @Published var rules: [OrganizationRule] = []
  @Published var concepts: [FileConcept] = []
  @Published var libraryIndex: LibraryWorkIndex?
  @Published var catalog: CatalogAnalysisResult?
  @Published var catalogStatus = "尚未分析资料库"
  @Published var catalogNeedsRefresh = false
  @Published var selectedExistingWorkPaths: Set<String> = []
  @Published var selectedSourceIDs: Set<UUID> = []
  @Published var creatorIdentities: [CreatorIdentity] = []
  @Published var recognitionByItem: [UUID: ConceptRecognitionResult] = [:]
  @Published var conceptModelStatus = "正在检查概念模型…"
  @Published var isDownloadingConceptModel = false
  @Published var isTeachingConcept = false
  @Published var ruleDrafts: [RuleDraft] = []
  @Published var namingRules: [NamingRule] = []
  @Published var namingRuleDrafts: [NamingRuleDraft] = []
  @Published var ruleInterpretationWarnings: [String] = []
  @Published var namingRuleSuggestions: [NamingRuleSuggestion] = []
  @Published var historyEntries: [HistoryEntry] = []
  @Published var learningSampleCount = 0
  @Published var isInterpretingRule = false
  @Published private(set) var decisionLocks: Set<UUID> = []
  @Published var lastError: String?

  private(set) var database: AppDatabase?
  private var runningTask: Task<Void, Never>?
  private var planPreparationTask: Task<OrganizationPlan, Error>?
  private var activeExecutor: SafePlanExecutor?

  init(database injectedDatabase: AppDatabase? = nil) {
    let isUITesting = ProcessInfo.processInfo.arguments.contains("-ui-testing-reset")
    do {
      let database: AppDatabase
      if let injectedDatabase {
        database = injectedDatabase
      } else if isUITesting {
        let url = Self.uiTestingDatabaseURL
        for suffix in ["", "-wal", "-shm"] {
          try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        database = try AppDatabase(path: url.path)
      } else {
        database = try AppDatabase.applicationDatabase()
      }
      self.database = database
      concepts = try database.concepts()
      conceptModelStatus = ConceptModelManager().isInstalled
        ? "正在检查本地图像模型…" : "图像概念模型未安装；可先手动教学"
      if ConceptModelManager().isInstalled {
        Task { [weak self] in
          let status = await Task.detached(priority: .utility) { () -> String in
            do {
              _ = try ConceptModelManager().provider()
              return "本地图像概念模型已安装"
            } catch { return "图像概念模型损坏，请重新下载" }
          }.value
          self?.conceptModelStatus = status
        }
      }
      if isUITesting && injectedDatabase == nil {
        try database.clearWorkspaces()
      }
      if ProcessInfo.processInfo.arguments.contains("-ui-testing-progress-demo") {
        progress = OrganizationProgress(
          phase: .analyzing,
          completed: 37,
          total: 120,
          skipped: 2,
          failed: 1,
          isCancellable: true
        )
        isWorking = true
      }
      if let savedWorkspace = try database.latestWorkspace() {
        do {
          let access = try SecurityScopedBookmarks.resolve(savedWorkspace)
          defer { access.stop() }
          workspace = savedWorkspace
          loadWorkspaceArtifacts(savedWorkspace, database: database)
        } catch {
          workspace = nil
          lastError = error.localizedDescription
        }
      }
      if ProcessInfo.processInfo.arguments.contains("-ui-testing-workspace-demo") {
        let renameDisposition: RenameDisposition
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-blocked-rename-demo") {
          renameDisposition = .blocked
        } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-rejected-rename-demo") {
          renameDisposition = .rejected
        } else {
          renameDisposition = .pending
        }
        seedWorkspaceDemo(
          database: database,
          renameDisposition: renameDisposition)
      }
      if ProcessInfo.processInfo.arguments.contains("-ui-testing-concept-demo") {
        seedConceptDemo(database: database)
      }
      if isUITesting {
        modelStatus = "本地 AI 状态将在整理时检查"
      } else {
        refreshModelStatus()
      }
    } catch {
      lastError = "数据库初始化失败：\(error.localizedDescription)"
    }
  }

  static var uiTestingDatabaseURL: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("AIFileOrganizerUITests-\(ProcessInfo.processInfo.processIdentifier).sqlite")
  }

  private func refreshModelStatus() {
    Task { [weak self] in
      let status = await Task.detached(priority: .utility) {
        AppleFoundationModelProvider().availabilityDescription
      }.value
      self?.modelStatus = status
    }
  }

  private func seedWorkspaceDemo(
    database: AppDatabase, renameDisposition: RenameDisposition = .pending
  ) {
    let workspace = Workspace(
      inboxPath: "/tmp/Downloads",
      libraryPath: "/tmp/Library",
      inboxVolumeID: "ui-volume",
      libraryVolumeID: "ui-volume"
    )
    let session = OrganizationSession(workspaceID: workspace.id, state: .review)
    let destination = DestinationProfile(
      relativePath: "创作/音乐/乐谱", displayName: "乐谱", keywords: ["乐谱"], depth: 3)
    let item = ItemSnapshot(
      sessionID: session.id,
      path: "/tmp/Downloads/Moonlight Score.pdf",
      name: "Moonlight Score.pdf",
      kind: .file,
      contentType: "com.adobe.pdf",
      fileExtension: "pdf"
    )
    let proposal = ClassificationProposal(
      sessionID: session.id,
      itemID: item.id,
      action: .move,
      destinationID: destination.id,
      source: .deterministic,
      reviewDecision: .ready,
      reason: "文件类型与目录用途一致"
    )
    let rename = RenameProposal(
      sessionID: session.id,
      itemID: item.id,
      originalName: item.name,
      suggestedBaseName: "Moonlight Sonata",
      source: .foundationModel,
      disposition: renameDisposition,
      reason: renameDisposition == .blocked ? "多个命名规则给出了不同名称" : "从 PDF 标题提取"
    )
    try? database.saveWorkspace(workspace)
    try? database.saveSession(session)
    try? database.saveSnapshots([item])
    try? database.saveProposals([proposal])
    try? database.saveRenameProposals([rename])
    self.workspace = workspace
    self.session = session
    items = [item]
    destinations = [destination]
    proposals = [proposal]
    renameProposals = [rename]
    catalog = CatalogAnalysisResult(profiles: [CatalogProfile(
      relativePath: destination.relativePath, workNames: [item.name],
      nameFrequencies: [:], totalWorks: 1, contentAnalyzedWorks: 1,
      userPurpose: "乐谱", referenceWorkPaths: [])],
      workAnalyses: [], reusedWorkCount: 1, revision: "ui-demo")
    catalogStatus = "已分析 1 个分类、1 部作品；复用 1 部缓存"
    libraryIndex = LibraryWorkIndex(nodes: [LibraryWorkNode(
      relativePath: destination.relativePath + "/" + item.name,
      role: .work, kind: .file)])
    selectedItemID = item.id
    statusMessage = "方案已生成，请确认移动位置"
    modelStatus = "Apple 本地模型可用"
  }

  private func seedConceptDemo(database: AppDatabase) {
    guard let item = items.first else { return }
    do {
      let store = ConceptStore(database: database)
      var known = try store.concepts()
      func concept(named name: String) throws -> FileConcept {
        if let existing = known.first(where: { $0.name == name }) { return existing }
        let created = FileConcept(name: name)
        try store.save(created)
        known.append(created)
        return created
      }
      let score = try concept(named: "钢琴谱")
      _ = try concept(named: "课程讲义")
      concepts = try store.concepts()
      recognitionByItem[item.id] = ConceptRecognitionResult(
        itemIdentity: ConceptIdentity.of(item), status: .confirmed,
        confirmedConceptIDs: [score.id], candidates: [])
    } catch {
      lastError = error.localizedDescription
    }
  }

  var readyProposals: [ClassificationProposal] {
    proposals.filter { $0.reviewDecision == .ready && $0.action == .move && $0.status != .rejected }
  }

  var reviewProposals: [ClassificationProposal] {
    proposals.filter { $0.reviewDecision == .needsReview }
  }

  var keptProposals: [ClassificationProposal] {
    proposals.filter { $0.reviewDecision == .keep }
  }

  var pendingFolderCount: Int { folderProposals.filter { $0.status == .pending }.count }

  var selectedRenameProposals: [RenameProposal] {
    renameProposals.filter { $0.selectedBaseName != nil }
  }

  var pendingRenameCount: Int {
    renameProposals.filter { $0.disposition == .pending }.count
  }

  var blockedRenameCount: Int {
    renameProposals.filter { $0.disposition == .blocked }.count
  }

  var canExecute: Bool {
    !isWorking && !isTeachingConcept && !catalogNeedsRefresh
      && receipt == nil && workspace != nil
      && (!readyProposals.isEmpty || folderProposals.contains { $0.status == .approved }
        || !selectedRenameProposals.isEmpty)
  }

  var canCancel: Bool { isWorking && progress?.isCancellable == true }

  func configure(inbox: URL, library: URL) {
    do {
      let workspace = try SecurityScopedBookmarks.makeWorkspace(inbox: inbox, library: library)
      try database?.saveWorkspace(workspace)
      self.workspace = workspace
      if let database { loadWorkspaceArtifacts(workspace, database: database) }
      lastError = nil
      statusMessage = "目录已授权，可以开始整理"
    } catch {
      lastError = error.localizedDescription
    }
  }

  func setCatalogPurpose(_ purpose: String, for relativePath: String) {
    guard let workspace, let database else { return }
    do {
      try CatalogAnalysisService(database: database).setPurpose(
        purpose, for: relativePath, workspaceID: workspace.id)
      invalidateCatalogSuggestions()
      catalogStatus = "目录用途已保存；请重新分析资料库"
    } catch { lastError = error.localizedDescription }
  }

  func setCatalogRole(_ role: LibraryNodeRole, for relativePath: String) {
    guard let workspace, let database else { return }
    do {
      try CatalogAnalysisService(database: database).setRole(
        role, for: relativePath, workspaceID: workspace.id)
      invalidateCatalogSuggestions()
      catalogStatus = "目录角色已保存；请重新分析资料库"
    } catch { lastError = error.localizedDescription }
  }

  func setCatalogWorkExcluded(_ excluded: Bool, workPath: String, categoryPath: String) {
    guard let workspace, let database else { return }
    do {
      try CatalogAnalysisService(database: database).setExcluded(excluded,
        workPath: workPath, categoryPath: categoryPath, workspaceID: workspace.id)
      invalidateCatalogSuggestions()
      catalogStatus = "样本排除状态已保存；请重新分析资料库"
    } catch { lastError = error.localizedDescription }
  }

  func setCatalogReference(_ reference: Bool, workPath: String, categoryPath: String) {
    guard let workspace, let database else { return }
    do {
      try CatalogAnalysisService(database: database).setReference(reference,
        workPath: workPath, categoryPath: categoryPath, workspaceID: workspace.id)
      invalidateCatalogSuggestions()
      catalogStatus = "参考作品已保存；请重新分析资料库"
    } catch { lastError = error.localizedDescription }
  }

  func confirmCreatorAlias(_ alias: String, creatorID: UUID, sourceURL: String) {
    guard let workspace, let database else { return }
    do {
      try CreatorCatalog(database: database).confirmAlias(
        alias, for: creatorID, sourceURL: sourceURL)
      creatorIdentities = try database.creatorIdentities(workspaceID: workspace.id)
      invalidateCatalogSuggestions()
      statusMessage = "作者别名已确认；请重新分析建议"
    } catch { lastError = error.localizedDescription }
  }

  func refreshCatalog() {
    guard let workspace, let database, !isWorking else { return }
    isWorking = true
    catalogStatus = "正在分析资料库…"
    runningTask = Task { [weak self] in
      guard let self else { return }
      defer { self.isWorking = false; self.runningTask = nil; self.progress = nil }
      do {
        let access = try SecurityScopedBookmarks.resolve(workspace)
        defer { access.stop() }
        let root = URL(fileURLWithPath: workspace.libraryPath, isDirectory: true)
        let roleOverrides = try database.catalogProfileOverrides(workspaceID: workspace.id)
          .compactMapValues { $0.role }
        let index = try LibraryWorkIndexer().index(root: root, roleOverrides: roleOverrides)
        let result = try await CatalogAnalysisService(database: database).analyze(
          index: index, workspaceID: workspace.id, root: root,
          progress: { [weak self] completed, total in
            await MainActor.run {
              self?.progress = OrganizationProgress(phase: .analyzing,
                completed: completed, total: total, isCancellable: true)
            }
          })
        try Task.checkCancellation()
        self.libraryIndex = index
        self.catalog = result
        self.catalogNeedsRefresh = false
        let indexed = try DestinationCatalogService().index(workspace: workspace,
          maxDepth: 4, roleOverrides: roleOverrides)
        self.destinations = try LearningService(database: database).enrich(
          destinations: indexed, libraryID: workspace.id)
        self.catalogStatus = "已分析 \(result.profiles.count) 个分类、\(result.workAnalyses.count) 部作品；复用 \(result.reusedWorkCount) 部缓存"
        if let session = self.session, !self.items.isEmpty {
          let resolutions = try self.creatorResolutions(
            for: self.items, workspace: workspace, database: database)
          let classified = await ClassificationPipeline().run(
            sessionID: session.id, items: self.items,
            destinations: self.destinations.filter { $0.kind == .category },
            rules: self.rules, concepts: self.concepts,
            recognitionByItem: self.recognitionByItem,
            catalog: result, creatorResolutions: resolutions)
          let old = Dictionary(uniqueKeysWithValues: self.proposals.map { ($0.itemID, $0) })
          self.proposals = classified.proposals.map { proposal in
            if self.decisionLocks.contains(proposal.itemID) {
              return old[proposal.itemID] ?? proposal
            }
            guard let item = self.items.first(where: { $0.id == proposal.itemID }) else {
              return proposal
            }
            return self.normalizeExistingWorkProposal(proposal, item: item)
          }
          self.folderProposals = classified.folderProposals.compactMap { folder in
            var value = folder
            value.relatedItemIDs.removeAll { self.decisionLocks.contains($0) }
            return value.relatedItemIDs.isEmpty ? nil : value
          }
          try database.saveProposals(self.proposals)
          try database.saveFolderProposals(self.folderProposals)
        }
        self.statusMessage = "目录画像已更新，请检查新的整理建议"
      } catch is CancellationError {
        self.catalogStatus = "目录分析已取消"
      } catch {
        self.catalogStatus = "目录分析失败"
        self.lastError = error.localizedDescription
      }
    }
  }

  func includeSelectedExistingWorks() {
    guard let workspace, let database, let session, let catalog, let libraryIndex,
      !isWorking, !selectedExistingWorkPaths.isEmpty else { return }
    let selected = libraryIndex.nodes.filter {
      $0.role == .work && selectedExistingWorkPaths.contains($0.relativePath)
    }
    guard !selected.isEmpty else { return }
    isWorking = true
    runningTask = Task { [weak self] in
      guard let self else { return }
      defer { self.isWorking = false; self.runningTask = nil }
      do {
        let access = try SecurityScopedBookmarks.resolve(workspace)
        defer { access.stop() }
        let root = URL(fileURLWithPath: workspace.libraryPath, isDirectory: true)
        let existingPaths = Set(self.items.map(\.path))
        let newItems = selected.compactMap { node -> ItemSnapshot? in
          let url = root.appendingPathComponent(node.relativePath)
          guard !existingPaths.contains(url.path),
            FileManager.default.fileExists(atPath: url.path),
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
          else { return nil }
          return ItemSnapshot(sessionID: session.id, path: url.path,
            name: url.lastPathComponent, kind: node.kind,
            fileExtension: url.pathExtension.lowercased())
        }
        guard !newItems.isEmpty else { return }
        let resolutions = try self.creatorResolutions(
          for: newItems, workspace: workspace, database: database)
        let result = await ClassificationPipeline().run(sessionID: session.id,
          items: newItems, destinations: self.destinations.filter { $0.kind == .category },
          rules: self.rules, concepts: self.concepts, catalog: catalog,
          creatorResolutions: resolutions)
        try Task.checkCancellation()
        self.items.append(contentsOf: newItems)
        self.selectedSourceIDs.formUnion(newItems.map(\.id))
        self.proposals.append(contentsOf: result.proposals.compactMap { proposal in
          guard let item = newItems.first(where: { $0.id == proposal.itemID }) else { return nil }
          return self.normalizeExistingWorkProposal(proposal, item: item)
        })
        self.folderProposals.append(contentsOf: result.folderProposals)
        self.selectedExistingWorkPaths.removeAll()
        try database.saveSnapshots(newItems)
        try database.saveProposals(result.proposals)
        try database.saveFolderProposals(result.folderProposals)
        self.statusMessage = "已将 \(newItems.count) 部旧作加入本次复核"
      } catch { self.lastError = error.localizedDescription }
    }
  }

  private func invalidateCatalogSuggestions() {
    currentPlan = nil
    catalog = nil
    catalogNeedsRefresh = true
    for index in proposals.indices where proposals[index].source != .user {
      proposals[index].reviewDecision = .needsReview
      proposals[index].status = .pending
      proposals[index].reason = "目录画像已更新，请重新分析后确认"
      proposals[index].catalogRevision = nil
    }
    for index in folderProposals.indices { folderProposals[index].status = .pending }
    try? database?.saveProposals(proposals)
    try? database?.saveFolderProposals(folderProposals)
  }

  func creatorResolutions(
    for items: [ItemSnapshot], workspace: Workspace, database: AppDatabase
  ) throws -> [UUID: CreatorResolution] {
    let creatorCatalog = CreatorCatalog(database: database)
    let existingCreators = libraryIndex?.nodes.filter { $0.role == .creator } ?? []
    let libraryRoot = URL(fileURLWithPath: workspace.libraryPath, isDirectory: true)
    var result: [UUID: CreatorResolution] = [:]
    for item in items {
      let parsed = WorkNameParser().parse(item.name)
      let resolution = try creatorCatalog.resolve(parsed, workspaceID: workspace.id)
      let identity: CreatorIdentity?
      if case .unknown = resolution, parsed.authorNames.count == 1 {
        identity = CreatorIdentity(workspaceID: workspace.id,
          japaneseName: parsed.authorNames[0], englishName: nil,
          circleName: parsed.circleName)
      } else if case .confirmed(let confirmed) = resolution {
        identity = confirmed
      } else {
        identity = nil
      }
      if var identity {
        identity.preferredDestinations = identity.preferredDestinations.filter { _, path in
          let url = libraryRoot.appendingPathComponent(path, isDirectory: true)
          return FileManager.default.fileExists(atPath: url.path)
            && (try? PathSafety.safeDestination(library: libraryRoot,
              relativePath: path)) != nil
        }
        let matches = existingCreators.filter { node in
          let path = node.relativePath
          let folder = (path as NSString).lastPathComponent
          let parent = (path as NSString).deletingLastPathComponent
          let url = libraryRoot.appendingPathComponent(path, isDirectory: true)
          return destinations.contains { $0.relativePath == parent && $0.kind == .category }
            && CreatorCatalog.key(folder) == CreatorCatalog.key(identity.proposedDirectoryName)
            && FileManager.default.fileExists(atPath: url.path)
            && (try? PathSafety.safeDestination(library: libraryRoot,
              relativePath: path)) == PathSafety.normalized(url)
        }
        if matches.count == 1 {
          let path = matches[0].relativePath
          let parent = (path as NSString).deletingLastPathComponent
          identity.preferredDestinations[parent] = path
        }
        result[item.id] = .confirmed(identity)
      } else {
        result[item.id] = resolution
      }
    }
    return result
  }

  var existingCreatorPaths: [String] {
    libraryIndex?.nodes.filter { $0.role == .creator }.map(\.relativePath) ?? []
  }

  func setCreatorDestination(_ path: String, for itemIDs: Set<UUID>) {
    guard let workspace, let session, !itemIDs.isEmpty else { return }
    let root = URL(fileURLWithPath: workspace.libraryPath, isDirectory: true)
    guard existingCreatorPaths.contains(path),
      FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path),
      (try? PathSafety.safeDestination(library: root, relativePath: path)) != nil,
      let category = destinations.first(where: {
        $0.kind == .category && $0.relativePath == (path as NSString).deletingLastPathComponent
      }) else {
      lastError = "现有作者目录不可用"
      return
    }
    currentPlan = nil
    decisionLocks.formUnion(itemIDs)
    detachFromFolderProposals(itemIDs)
    for index in proposals.indices where itemIDs.contains(proposals[index].itemID) {
      proposals[index].destinationID = category.id
      proposals[index].creatorDestinationPath = path
      proposals[index].creatorID = nil
      proposals[index].suggestedFolderName = nil
      proposals[index].action = .move
      proposals[index].reviewDecision = .ready
      proposals[index].status = .overridden
      proposals[index].source = .user
      proposals[index].reason = "由你指定现有作者目录"
      try? database?.saveDecision(DecisionRecord(sessionID: session.id,
        itemID: proposals[index].itemID, originalDestinationID: nil,
        finalDestinationID: category.id, action: "override_creator_folder"))
    }
    try? database?.saveProposals(proposals)
    selectedItemIDs.subtract(itemIDs)
  }

  func normalizeExistingWorkProposal(
    _ proposal: ClassificationProposal, item: ItemSnapshot
  ) -> ClassificationProposal {
    guard let workspace, proposal.action == .move,
      proposal.creatorDestinationPath == nil, proposal.suggestedFolderName == nil,
      let destinationID = proposal.destinationID,
      let destination = destinations.first(where: { $0.id == destinationID })
    else { return proposal }
    let source = URL(fileURLWithPath: item.path)
    let library = URL(fileURLWithPath: workspace.libraryPath, isDirectory: true)
    guard PathSafety.contains(library, source),
      PathSafety.normalized(source.deletingLastPathComponent()).path
        == PathSafety.normalized(library.appendingPathComponent(destination.relativePath)).path
    else { return proposal }
    var result = proposal
    result.action = .keep
    result.destinationID = nil
    result.reviewDecision = .keep
    result.reason = "作品已位于目标分类"
    return result
  }

  func forgetWorkspace() {
    guard !isWorking else { return }
    do {
      try database?.deactivateWorkspaces()
    } catch {
      lastError = error.localizedDescription
      return
    }
    workspace = nil
    resetSession()
    destinations = []
    catalog = nil
    libraryIndex = nil
    creatorIdentities = []
    catalogStatus = "尚未分析资料库"
    catalogNeedsRefresh = false
    rules = []
    ruleDrafts = []
    namingRules = []
    namingRuleDrafts = []
    namingRuleSuggestions = []
    historyEntries = []
    learningSampleCount = 0
  }

  func startOrganizing() {
    guard let workspace, let database, !isWorking, !isTeachingConcept else { return }
    resetSession()
    isWorking = true
    let session = OrganizationSession(workspaceID: workspace.id, state: .scanning)
    self.session = session
    try? database.saveSession(session)
    progress = OrganizationProgress(
      phase: .scanning,
      isIndeterminate: true,
      isCancellable: true
    )
    runningTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.session?.id == session.id {
          self.progress = nil
          self.isWorking = false
          self.runningTask = nil
        }
      }
      do {
        let access = try SecurityScopedBookmarks.resolve(workspace)
        defer { access.stop() }
        self.statusMessage = "正在分析资料库的作品与目录…"
        self.catalogStatus = "正在分析资料库…"
        let libraryRoot = URL(fileURLWithPath: workspace.libraryPath, isDirectory: true)
        let roleOverrides = try database.catalogProfileOverrides(workspaceID: workspace.id)
          .compactMapValues { $0.role }
        let index = try LibraryWorkIndexer().index(root: libraryRoot,
          roleOverrides: roleOverrides)
        self.libraryIndex = index
        let catalog = try await CatalogAnalysisService(database: database).analyze(
          index: index, workspaceID: workspace.id, root: libraryRoot,
          progress: { [weak self] completed, total in
            await self?.setProgress(OrganizationProgress(phase: .analyzing,
              completed: completed, total: total, isCancellable: true), sessionID: session.id)
          })
        try Task.checkCancellation()
        self.catalog = catalog
        self.catalogNeedsRefresh = false
        self.catalogStatus = "已分析 \(catalog.profiles.count) 个分类、\(catalog.workAnalyses.count) 部作品；复用 \(catalog.reusedWorkCount) 部缓存"
        self.creatorIdentities = try database.creatorIdentities(workspaceID: workspace.id)
        let indexed = try DestinationCatalogService().index(workspace: workspace,
          maxDepth: 4, roleOverrides: roleOverrides)
        let learning = LearningService(database: database)
        try learning.refreshExistingLibrarySamples(
          libraryID: workspace.id,
          root: URL(fileURLWithPath: workspace.libraryPath, isDirectory: true),
          destinations: indexed)
        self.destinations = try learning.enrich(destinations: indexed, libraryID: workspace.id)
        self.rules = try database.rules(workspaceID: workspace.id)
        let namingLearning = NamingLearningService(database: database)
        try namingLearning.refreshExistingLibrarySamples(
          workspaceID: workspace.id,
          root: URL(fileURLWithPath: workspace.libraryPath, isDirectory: true),
          destinations: self.destinations)
        self.namingRules = try database.namingRules(workspaceID: workspace.id)
        self.concepts = try database.concepts()
        var scanned: [ItemSnapshot] = []
        for try await event in LocalInboxScanner().scan(workspace, sessionID: session.id) {
          try Task.checkCancellation()
          switch event {
          case .started(let total):
            self.statusMessage = "正在扫描收件箱…"
            self.setProgress(
              OrganizationProgress(
                phase: .scanning,
                total: total,
                isCancellable: true
              ),
              sessionID: session.id
            )
          case .discovered(let item):
            scanned.append(item)
            self.items.append(item)
            self.proposals.append(
              ClassificationProposal(
                sessionID: session.id,
                itemID: item.id,
                action: .keep,
                source: .deterministic,
                reviewDecision: .needsReview,
                reason: "正在分析…"
              ))
            self.discoveredCount += 1
            self.updateScanProgress(total: self.progress?.total, sessionID: session.id)
          case .skipped(_, _):
            self.skippedCount += 1
            self.updateScanProgress(total: self.progress?.total, sessionID: session.id)
          case .finished(let discovered, let skipped):
            self.setProgress(
              OrganizationProgress(
                phase: .scanning,
                completed: discovered + skipped,
                total: discovered + skipped,
                skipped: skipped,
                isCancellable: true
              ),
              sessionID: session.id
            )
          }
        }
        try Task.checkCancellation()
        try database.saveSnapshots(scanned)
        let conceptStore = ConceptStore(database: database)
        let allExamples = try self.concepts.flatMap {
          try conceptStore.examples(conceptID: $0.id)
        }
        let concepts = self.concepts
        let recognitionTask = Task.detached(priority: .utility) {
          let manager = ConceptModelManager()
          let provider = try? manager.provider()
          let results = await ConceptRecognitionService().recognize(
            items: scanned, concepts: concepts, examples: allExamples, provider: provider)
          return (results, manager.isInstalled && provider == nil)
        }
        let recognitionOutcome = await withTaskCancellationHandler {
          await recognitionTask.value
        } onCancel: {
          recognitionTask.cancel()
        }
        try Task.checkCancellation()
        let recognitions = recognitionOutcome.0
        self.recognitionByItem = recognitions
        if recognitionOutcome.1 {
          self.conceptModelStatus = "图像概念模型损坏，请重新下载"
        }
        self.updateSession(.proposing)
        self.statusMessage = "正在生成整理方案…"
        let creatorResolutions = try self.creatorResolutions(
          for: scanned, workspace: workspace, database: database)
        let result = await ClassificationPipeline().run(
          sessionID: session.id,
          items: scanned,
          destinations: self.destinations.filter { $0.kind == .category },
          rules: self.rules,
          concepts: self.concepts,
          recognitionByItem: recognitions,
          catalog: catalog,
          creatorResolutions: creatorResolutions,
          progress: { [weak self] value in
            guard !Task.isCancelled else { return }
            await self?.setProgress(value, sessionID: session.id)
          }
        )
        try Task.checkCancellation()
        let generated = Dictionary(uniqueKeysWithValues: result.proposals.map { ($0.itemID, $0) })
        self.proposals = scanned.compactMap { item in
          if self.decisionLocks.contains(item.id) {
            return self.proposals.first { $0.itemID == item.id }
          }
          return generated[item.id]
        }
        self.folderProposals = result.folderProposals.compactMap { folder in
          var filtered = folder
          filtered.relatedItemIDs.removeAll { self.decisionLocks.contains($0) }
          return filtered.relatedItemIDs.isEmpty ? nil : filtered
        }
        let destinationByItem = Dictionary(uniqueKeysWithValues: result.proposals.compactMap {
          proposal in proposal.destinationID.map { (proposal.itemID, $0) }
        })
        var styleExamples: [UUID: [String]] = [:]
        for destination in self.destinations {
          styleExamples[destination.id] = try namingLearning.styleExamples(
            destinationID: destination.id)
        }
        let namingResult = await FilenameSuggestionPipeline().run(
          sessionID: session.id,
          items: scanned,
          contextsByItem: result.contextsByItem,
          namingRules: self.namingRules,
          recognitionByItem: recognitions,
          concepts: self.concepts,
          styleExamplesByDestination: styleExamples,
          destinationByItem: destinationByItem,
          progress: { [weak self] value in
            guard !Task.isCancelled else { return }
            await self?.setProgress(value, sessionID: session.id)
          })
        try Task.checkCancellation()
        self.renameProposals = namingResult.proposals
        self.modelStatus = result.modelStatus
        try database.saveProposals(self.proposals)
        try database.saveFolderProposals(self.folderProposals)
        try database.saveRenameProposals(self.renameProposals)
        self.updateSession(.review)
        self.statusMessage = scanned.isEmpty ? "收件箱已经很干净" : "方案已生成，请处理需要确认的项目"
      } catch is CancellationError {
        self.updateSession(.cancelled, finished: true)
        self.statusMessage = "已取消"
      } catch {
        self.lastError = error.localizedDescription
        self.updateSession(.failed, finished: true, error: error.localizedDescription)
      }
    }
  }

  func cancel() {
    guard canCancel else { return }
    if progress?.phase == .executing || progress?.phase == .undoing {
      activeExecutor?.cancel()
    } else {
      runningTask?.cancel()
      planPreparationTask?.cancel()
    }
    statusMessage = "正在安全停止…"
  }

  func setDestination(_ destinationID: UUID, for itemIDs: Set<UUID>) {
    guard let session else { return }
    currentPlan = nil
    decisionLocks.formUnion(itemIDs)
    for index in proposals.indices where itemIDs.contains(proposals[index].itemID) {
      let old = proposals[index].destinationID
      proposals[index].destinationID = destinationID
      proposals[index].suggestedFolderName = nil
      proposals[index].creatorDestinationPath = nil
      proposals[index].creatorID = nil
      proposals[index].action = .move
      proposals[index].reviewDecision = .ready
      proposals[index].status = .overridden
      proposals[index].source = .user
      proposals[index].reason = "由你指定目标"
      try? database?.saveDecision(
        DecisionRecord(
          sessionID: session.id,
          itemID: proposals[index].itemID,
          originalDestinationID: old,
          finalDestinationID: destinationID,
          action: "override"
        ))
    }
    detachFromFolderProposals(itemIDs)
    try? database?.saveProposals(proposals)
    selectedItemIDs.subtract(itemIDs)
  }

  func keep(_ itemIDs: Set<UUID>) {
    guard let session else { return }
    currentPlan = nil
    decisionLocks.formUnion(itemIDs)
    for index in proposals.indices where itemIDs.contains(proposals[index].itemID) {
      let old = proposals[index].destinationID
      proposals[index].action = .keep
      proposals[index].destinationID = nil
      proposals[index].suggestedFolderName = nil
      proposals[index].creatorDestinationPath = nil
      proposals[index].creatorID = nil
      proposals[index].reviewDecision = .keep
      proposals[index].status = .overridden
      proposals[index].source = .user
      proposals[index].reason = "由你选择保留原处"
      try? database?.saveDecision(
        DecisionRecord(
          sessionID: session.id,
          itemID: proposals[index].itemID,
          originalDestinationID: old,
          finalDestinationID: nil,
          action: "keep"
        ))
    }
    detachFromFolderProposals(itemIDs)
    try? database?.saveProposals(proposals)
    selectedItemIDs.subtract(itemIDs)
  }

  func setFolderProposal(_ id: UUID, approved: Bool) {
    guard let index = folderProposals.firstIndex(where: { $0.id == id }) else { return }
    currentPlan = nil
    folderProposals[index].status = approved ? .approved : .rejected
    let affected = Set(folderProposals[index].relatedItemIDs)
    if approved {
      for proposalIndex in proposals.indices
      where affected.contains(proposals[proposalIndex].itemID) {
        proposals[proposalIndex].reviewDecision = .ready
        proposals[proposalIndex].status = .approved
        proposals[proposalIndex].reason = "新目录已由你批准"
      }
    } else {
      for proposalIndex in proposals.indices
      where affected.contains(proposals[proposalIndex].itemID) {
        proposals[proposalIndex].action = .keep
        proposals[proposalIndex].creatorDestinationPath = nil
        proposals[proposalIndex].creatorID = nil
        proposals[proposalIndex].reviewDecision = .needsReview
        proposals[proposalIndex].reason = "新目录建议已拒绝，请另选目标或保留"
      }
    }
    for itemID in affected {
      try? database?.saveDecision(
        DecisionRecord(
          sessionID: folderProposals[index].sessionID,
          itemID: itemID,
          originalDestinationID: nil,
          finalDestinationID: nil,
          action: approved ? "approve_folder" : "reject_folder"
        ))
    }
    try? database?.saveFolderProposals(folderProposals)
    try? database?.saveProposals(proposals)
  }

  func createFolder(named rawName: String, for itemIDs: Set<UUID>) {
    guard let session, !itemIDs.isEmpty else { return }
    currentPlan = nil
    decisionLocks.formUnion(itemIDs)
    do {
      let name = try PathSafety.validateFolderName(rawName)
      let key = PathSafety.normalizedFolderKey(name)
      guard !destinations.contains(where: { PathSafety.normalizedFolderKey($0.displayName) == key })
      else {
        throw OrganizerError.invalidFolderName("资料库中已经存在同名目录，请直接选择它")
      }
      detachFromFolderProposals(itemIDs)
      if let index = folderProposals.firstIndex(where: { $0.normalizedName == key }) {
        folderProposals[index].displayName = name
        folderProposals[index].status = .approved
        folderProposals[index].relatedItemIDs = Array(
          Set(folderProposals[index].relatedItemIDs).union(itemIDs))
      } else {
        folderProposals.append(
          FolderProposal(
            sessionID: session.id,
            normalizedName: key,
            displayName: name,
            status: .approved,
            relatedItemIDs: Array(itemIDs)
          ))
      }
      for index in proposals.indices where itemIDs.contains(proposals[index].itemID) {
        proposals[index].action = .suggestFolder
        proposals[index].destinationID = nil
        proposals[index].suggestedFolderName = name
        proposals[index].creatorDestinationPath = nil
        proposals[index].creatorID = nil
        proposals[index].source = .user
        proposals[index].reviewDecision = .ready
        proposals[index].status = .overridden
        proposals[index].reason = "将创建你指定的新目录"
      }
      try database?.saveFolderProposals(folderProposals)
      try database?.saveProposals(proposals)
      for itemID in itemIDs {
        try? database?.saveDecision(
          DecisionRecord(
            sessionID: session.id,
            itemID: itemID,
            originalDestinationID: nil,
            finalDestinationID: nil,
            action: "create_folder"
          ))
      }
      selectedItemIDs.subtract(itemIDs)
    } catch {
      lastError = error.localizedDescription
    }
  }

  func prepareExecution() async -> Bool {
    guard let workspace, let session, let database, !isWorking,
      !isTeachingConcept, !catalogNeedsRefresh else {
      return false
    }
    currentPlan = nil
    do {
      isWorking = true
      updateSession(.preflighting)
      progress = OrganizationProgress(
        phase: .preflighting,
        isIndeterminate: true,
        isCancellable: true
      )
      defer {
        planPreparationTask = nil
        progress = nil
        isWorking = false
      }
      let access = try SecurityScopedBookmarks.resolve(workspace)
      defer { access.stop() }
      let planItems = items
      let planDestinations = destinations
      let planProposals = proposals
      let planFolderProposals = folderProposals
      let planRenameProposals = renameProposals
      let selectedSources = selectedSourceIDs
      let revision = catalog?.revision
      let preparation = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        return try PlanBuilder().build(
          sessionID: session.id,
          workspace: workspace,
          items: planItems,
          destinations: planDestinations,
          proposals: planProposals,
          folderProposals: planFolderProposals,
          renameProposals: planRenameProposals,
          selectedSourceIDs: selectedSources,
          catalogRevision: revision
        )
      }
      planPreparationTask = preparation
      let plan = try await preparation.value
      guard !plan.operations.isEmpty else {
        lastError = "当前没有可执行的移动或改名"
        return false
      }
      progress = OrganizationProgress(
        phase: .preflighting,
        total: plan.operations.count,
        isCancellable: false
      )
      let report = await SafePlanExecutor(workspace: workspace, database: database,
        catalogRevision: revision).preflight(
        plan,
        progress: { [weak self] value in
          await self?.setProgress(value, sessionID: session.id)
        }
      )
      guard report.isReady else {
        throw OrganizerError.planBlocked(report.issues.map(\.message))
      }
      currentPlan = plan
      statusMessage = "预检通过，请确认执行"
      return true
    } catch is CancellationError {
      updateSession(.review)
      statusMessage = "已取消生成执行计划"
      return false
    } catch {
      lastError = error.localizedDescription
      updateSession(.review, error: error.localizedDescription)
      return false
    }
  }

  func discardPreparedPlan() {
    guard !isWorking, receipt == nil else { return }
    currentPlan = nil
    updateSession(.review)
    statusMessage = "已取消执行，方案仍可修改"
  }

  func executePreparedPlan() {
    guard let workspace, let database, var plan = currentPlan, !isWorking,
      !isTeachingConcept else { return }
    plan.confirmedAt = Date()
    currentPlan = plan
    isWorking = true
    updateSession(.executing)
    runningTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.progress = nil
        self.isWorking = false
        self.runningTask = nil
        self.activeExecutor = nil
      }
      do {
        let access = try SecurityScopedBookmarks.resolve(workspace)
        defer { access.stop() }
        let executor = SafePlanExecutor(workspace: workspace, database: database,
          catalogRevision: self.catalog?.revision)
        self.activeExecutor = executor
        var finalReceipt: ExecutionReceipt?
        for try await event in executor.execute(plan) {
          switch event {
          case .started(let total):
            self.statusMessage = "正在执行 \(total) 项操作…"
            self.setProgress(
              OrganizationProgress(phase: .executing, total: total, isCancellable: true),
              sessionID: plan.sessionID
            )
          case .operationStarted: break
          case .operationFinished(let result):
            self.advanceOperationProgress(result: result, sessionID: plan.sessionID)
            if result.state == .failed || result.state == .blocked {
              self.statusMessage = "部分项目需要处理"
            }
          case .finished(let receipt):
            finalReceipt = receipt
            self.receipt = receipt
          }
        }
        guard finalReceipt != nil else {
          throw OrganizerError.operationFailed("执行流提前结束，未收到最终回执")
        }
        if let finalReceipt {
          do {
            try self.recordCompletedCreatorDestinations(plan: plan, receipt: finalReceipt,
              workspace: workspace, database: database)
          } catch {
            self.lastError = "作品已移动，但作者目录关系未保存：" + error.localizedDescription
          }
        }
        let wasCancelled = finalReceipt?.wasCancelled == true
        let hasFailure =
          finalReceipt?.results.contains { $0.state == .failed || $0.state == .blocked } ?? false
        self.updateSession(wasCancelled || hasFailure ? .partial : .completed, finished: true)
        self.statusMessage = wasCancelled
          ? "已停止，已完成的项目保持不变"
          : (hasFailure ? "整理部分完成" : "整理完成")
        self.refreshHistory()
        self.refreshLearningCount()
        self.refreshNamingLearning()
      } catch is CancellationError {
        self.receipt = try? database.receipt(planID: plan.id)
        self.refreshHistory()
        self.refreshLearningCount()
        self.refreshNamingLearning()
        self.updateSession(.partial, finished: true)
        self.statusMessage = "已停止，已完成的项目保持不变"
      } catch {
        self.lastError = error.localizedDescription
        self.updateSession(.failed, finished: true, error: error.localizedDescription)
      }
    }
  }

  func recordCompletedCreatorDestinations(
    plan: OrganizationPlan, receipt: ExecutionReceipt, workspace: Workspace,
    database: AppDatabase
  ) throws {
    let completed = Set(receipt.results.filter { $0.state == .completed }.map(\.operationID))
    let root = URL(fileURLWithPath: workspace.libraryPath, isDirectory: true)
    let creatorCatalog = CreatorCatalog(database: database)
    for operation in plan.operations where operation.kind == .move
      && completed.contains(operation.id) {
      guard let itemID = operation.itemID,
        let item = items.first(where: { $0.id == itemID }),
        let proposal = proposals.first(where: { $0.itemID == itemID }),
        let categoryID = proposal.destinationID,
        let category = destinations.first(where: { $0.id == categoryID })
      else { continue }
      let folderURL = URL(fileURLWithPath: operation.destinationPath).deletingLastPathComponent()
      let categoryURL = root.appendingPathComponent(category.relativePath, isDirectory: true)
      guard folderURL.deletingLastPathComponent().standardizedFileURL == categoryURL.standardizedFileURL
      else { continue }
      let path = category.relativePath + "/" + folderURL.lastPathComponent
      guard (try? PathSafety.safeDestination(library: root, relativePath: path)) != nil
      else { continue }
      let parsed = WorkNameParser().parse(item.name)
      guard !parsed.hasMultipleAuthors, let author = parsed.authorNames.first else { continue }
      let identity: CreatorIdentity
      switch try creatorCatalog.resolve(parsed, workspaceID: workspace.id) {
      case .confirmed(let existing): identity = existing
      case .unknown:
        identity = try creatorCatalog.create(workspaceID: workspace.id,
          japaneseName: author, englishName: nil, circleName: parsed.circleName)
      case .candidates, .ambiguous: continue
      }
      try creatorCatalog.bindDestination(path, for: identity.id,
        categoryPath: category.relativePath)
    }
    creatorIdentities = try database.creatorIdentities(workspaceID: workspace.id)
  }

  func undo() {
    guard let workspace, let database, let plan = currentPlan, let receipt, !isWorking else {
      return
    }
    isWorking = true
    progress = OrganizationProgress(
      phase: .undoing,
      total: receipt.results.filter { $0.state == .completed }.count,
      isCancellable: true
    )
    runningTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.progress = nil
        self.isWorking = false
        self.runningTask = nil
        self.activeExecutor = nil
      }
      do {
        let access = try SecurityScopedBookmarks.resolve(workspace)
        defer { access.stop() }
        let executor = SafePlanExecutor(workspace: workspace, database: database)
        self.activeExecutor = executor
        var finalReceipt: ExecutionReceipt?
        for try await event in executor.undo(plan: plan, receipt: receipt) {
          switch event {
          case .started(let total):
            self.setProgress(
              OrganizationProgress(phase: .undoing, total: total, isCancellable: true),
              sessionID: plan.sessionID
            )
          case .operationStarted:
            break
          case .operationFinished(let result):
            self.advanceOperationProgress(result: result, sessionID: plan.sessionID)
          case .finished(let value):
            finalReceipt = value
          }
        }
        guard finalReceipt != nil else {
          throw OrganizerError.operationFailed("撤销流提前结束，未收到最终回执")
        }
        let blocked = finalReceipt?.results.filter { $0.state == .blocked }.count ?? 0
        if finalReceipt?.wasCancelled == true {
          self.statusMessage = "已停止撤销，已完成的项目保持当前状态"
          self.receipt = finalReceipt
        } else {
          self.statusMessage = blocked == 0 ? "本次整理已撤销" : "撤销完成，\(blocked) 项因状态变化被保留"
          self.receipt = blocked == 0 ? nil : finalReceipt
        }
        self.refreshHistory()
        self.refreshLearningCount()
        self.refreshNamingLearning()
      } catch {
        if error is CancellationError {
          self.receipt = try? database.receipt(planID: plan.id)
          self.refreshHistory()
          self.refreshLearningCount()
          self.refreshNamingLearning()
          self.statusMessage = "已停止撤销，已完成的项目保持当前状态"
        } else {
          self.lastError = error.localizedDescription
        }
      }
    }
  }

  func requestFilenameSuggestion(for itemID: UUID) {
    guard let workspace, let session, let database,
      let item = items.first(where: { $0.id == itemID }), item.kind != .applicationBundle,
      !isWorking
    else { return }
    isWorking = true
    progress = OrganizationProgress(
      phase: .analyzing, total: 1, isCancellable: true)
    runningTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.progress = nil
        self.isWorking = false
        self.runningTask = nil
      }
      do {
        let access = try SecurityScopedBookmarks.resolve(workspace)
        defer { access.stop() }
        let result = await FilenameSuggestionPipeline().run(
          sessionID: session.id,
          items: [item],
          namingRules: self.namingRules,
          requestedItemIDs: [itemID],
          progress: { [weak self] value in
            await self?.setProgress(value, sessionID: session.id)
          })
        try Task.checkCancellation()
        guard let proposal = result.proposals.first else {
          throw OrganizerError.modelUnavailable(result.modelStatus)
        }
        self.renameProposals.removeAll { $0.itemID == itemID }
        self.renameProposals.append(proposal)
        try database.saveRenameProposals(self.renameProposals)
        self.currentPlan = nil
        self.statusMessage = "已生成文件名建议，请确认"
      } catch is CancellationError {
        self.statusMessage = "已取消文件名分析"
      } catch {
        self.lastError = error.localizedDescription
      }
    }
  }

  func acceptRename(_ proposalID: UUID) {
    guard let index = renameProposals.firstIndex(where: { $0.id == proposalID }) else { return }
    var proposal = renameProposals[index]
    proposal.disposition = .approved
    renameProposals[index] = proposal
    persistRenameReview(itemID: proposal.itemID, action: "approve_rename")
  }

  func rejectRename(_ proposalID: UUID) {
    guard let index = renameProposals.firstIndex(where: { $0.id == proposalID }) else { return }
    var proposal = renameProposals[index]
    proposal.disposition = .rejected
    proposal.editedBaseName = nil
    renameProposals[index] = proposal
    persistRenameReview(itemID: proposal.itemID, action: "reject_rename")
  }

  func updateRename(_ proposalID: UUID, baseName: String) {
    guard let index = renameProposals.firstIndex(where: { $0.id == proposalID }),
      let item = items.first(where: { $0.id == renameProposals[index].itemID })
    else { return }
    do {
      _ = try FilenameValidator().validatedFullName(baseName: baseName, item: item)
      var proposal = renameProposals[index]
      let cleaned = baseName.trimmingCharacters(
        in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
      if cleaned != proposal.suggestedBaseName {
        proposal.templatePattern = nil
      }
      proposal.editedBaseName = cleaned
      proposal.source = .user
      proposal.disposition = .edited
      proposal.missingFields = []
      proposal.reason = "由你修改文件名"
      renameProposals[index] = proposal
      persistRenameReview(itemID: item.id, action: "edit_rename")
    } catch {
      lastError = error.localizedDescription
    }
  }

  func rejectRenames(for itemIDs: Set<UUID>) {
    for proposal in renameProposals where itemIDs.contains(proposal.itemID) {
      rejectRename(proposal.id)
    }
  }

  func renameProposal(for itemID: UUID) -> RenameProposal? {
    renameProposals.first { $0.itemID == itemID }
  }

  func proposedFullName(for item: ItemSnapshot) -> String? {
    guard let proposal = renameProposal(for: item.id),
      proposal.disposition != .rejected, proposal.disposition != .blocked
    else { return nil }
    let baseName = proposal.editedBaseName ?? proposal.suggestedBaseName
    return try? FilenameValidator().validatedFullName(baseName: baseName, item: item)
  }

  private func persistRenameReview(itemID: UUID, action: String) {
    currentPlan = nil
    do {
      try database?.saveRenameProposals(renameProposals)
      if let session {
        try database?.saveDecision(DecisionRecord(
          sessionID: session.id,
          itemID: itemID,
          originalDestinationID: nil,
          finalDestinationID: nil,
          action: action))
      }
    } catch { lastError = error.localizedDescription }
  }

  func item(for proposal: ClassificationProposal) -> ItemSnapshot? {
    items.first { $0.id == proposal.itemID }
  }

  func destinationName(_ id: UUID?) -> String {
    guard let id else { return "未指定" }
    return destinations.first(where: { $0.id == id })?.relativePath ?? "未知目标"
  }

  func installConceptModel() {
    guard !isDownloadingConceptModel else { return }
    isDownloadingConceptModel = true
    conceptModelStatus = "正在下载并校验本地模型…"
    Task { [weak self] in
      guard let self else { return }
      defer { self.isDownloadingConceptModel = false }
      do {
        try await Task.detached(priority: .utility) {
          try await ConceptModelManager().install()
        }.value
        self.conceptModelStatus = "本地图像概念模型已安装"
      } catch {
        self.conceptModelStatus = "概念模型不可用"
        self.lastError = error.localizedDescription
      }
    }
  }

  func saveConcept(
    name: String, description: String, aliases: [String], parentID: UUID?,
    defaultDestinationID: UUID?, itemIDs: Set<UUID>, externalURLs: [URL]
  ) -> Bool {
    guard let database, !isWorking, !isTeachingConcept else { return false }
    if let destinationID = defaultDestinationID {
      guard workspace != nil,
        destinations.contains(where: { $0.id == destinationID && $0.kind == .category })
      else {
        lastError = "默认目标目录无效"
        return false
      }
    }
    let concept = FileConcept(
      name: ConceptLabelParser.name(from: name),
      description: description, aliases: aliases, parentID: parentID)
    do {
      let store = ConceptStore(database: database)
      try store.save(concept)
      concepts = try store.concepts()
      if let destinationID = defaultDestinationID {
        guard let workspace else { return false }
        let rule = OrganizationRule(
          workspaceID: workspace.id,
          originalText: "\(concept.name) → \(destinationName(destinationID))",
          condition: RuleCondition(conceptID: concept.id), destinationID: destinationID)
        try database.saveRule(rule)
        rules.append(rule)
      }
      currentPlan = nil
      statusMessage = "已保存概念「\(concept.name)」"
      if !itemIDs.isEmpty || !externalURLs.isEmpty {
        teachConcept(
          concept.id, itemIDs: itemIDs, externalURLs: externalURLs, isPositive: true)
      }
      return true
    } catch {
      lastError = error.localizedDescription
      return false
    }
  }

  func deleteConcept(_ conceptID: UUID) {
    guard let database, !isWorking, !isTeachingConcept else { return }
    do {
      let moveRuleIDs = Set(rules.filter {
        $0.condition.conceptID == conceptID
      }.map(\.id))
      let namingRuleIDs = Set(namingRules.filter {
        $0.condition.conceptID == conceptID
      }.map(\.id))
      try ConceptStore(database: database).delete(conceptID)
      let invalidated = ConceptProposalInvalidator().invalidate(
        proposals: proposals, renames: renameProposals,
        moveRuleIDs: moveRuleIDs, namingRuleIDs: namingRuleIDs)
      proposals = invalidated.proposals
      renameProposals = invalidated.renames
      try database.saveProposals(proposals)
      try database.saveRenameProposals(renameProposals)
      concepts = try database.concepts()
      if let workspace {
        rules = try database.rules(workspaceID: workspace.id)
        namingRules = try database.namingRules(workspaceID: workspace.id)
      }
      currentPlan = nil
      recognitionByItem = [:]
      statusMessage = "概念已删除；关联规则已停用"
    } catch { lastError = error.localizedDescription }
  }

  func updateConcept(
    _ conceptID: UUID, name: String, description: String,
    aliases: [String], parentID: UUID?
  ) -> Bool {
    guard let database, !isWorking, !isTeachingConcept,
      var concept = concepts.first(where: { $0.id == conceptID })
    else { return false }
    concept.name = name
    concept.description = description
    concept.aliases = aliases
    concept.parentID = parentID
    do {
      try ConceptStore(database: database).save(concept)
      concepts = try database.concepts()
      let moveIDs = Set(rules.filter { $0.condition.conceptID != nil }.map(\.id))
      let namingIDs = Set(namingRules.filter { $0.condition.conceptID != nil }.map(\.id))
      let invalidated = ConceptProposalInvalidator().invalidate(
        proposals: proposals, renames: renameProposals,
        moveRuleIDs: moveIDs, namingRuleIDs: namingIDs)
      proposals = invalidated.proposals
      renameProposals = invalidated.renames
      try database.saveProposals(proposals)
      try database.saveRenameProposals(renameProposals)
      recognitionByItem = [:]
      currentPlan = nil
      statusMessage = "概念已更新，请重新审核现有方案"
      return true
    } catch {
      lastError = error.localizedDescription
      return false
    }
  }

  func teachConcept(
    _ conceptID: UUID, itemIDs: Set<UUID>, externalURLs: [URL] = [],
    isPositive: Bool
  ) {
    guard let database, !isWorking, !isTeachingConcept,
      concepts.contains(where: { $0.id == conceptID }) else { return }
    let recognitionBefore = recognitionByItem
    if receipt == nil { currentPlan = nil }
    isTeachingConcept = true
    let selected = items.filter { itemIDs.contains($0.id) }
    let access = externalURLs.filter { $0.startAccessingSecurityScopedResource() }
    let external = externalURLs.compactMap { conceptSnapshot(for: $0) }
    let teachingItems = selected + external
    guard !teachingItems.isEmpty else {
      access.forEach { $0.stopAccessingSecurityScopedResource() }
      isTeachingConcept = false
      lastError = "没有可读取的示例文件"
      return
    }
    Task { [weak self] in
      guard let self else { return }
      defer {
        access.forEach { $0.stopAccessingSecurityScopedResource() }
        self.isTeachingConcept = false
      }
      do {
        let (features, modelFailed) = await Task.detached(priority: .utility) {
          let manager = ConceptModelManager()
          let provider = try? manager.provider()
          let extractor = provider.map { ConceptFeatureExtractor(provider: $0) }
          var result: [(ItemSnapshot, ConceptFeatureSnapshot)] = []
          for item in teachingItems {
            if Task.isCancelled { break }
            var feature = await ConceptTextFeatureExtractor().extract(item: item)
            if let visual = try? await extractor?.extract(item: item) {
              feature.modelVersion = visual.modelVersion
              feature.visualVector = visual.visualVector
            }
            result.append((item, feature))
          }
          return (result, manager.isInstalled && provider == nil)
        }.value
        if modelFailed { self.conceptModelStatus = "图像概念模型损坏，请重新下载" }
        let store = ConceptStore(database: database)
        for (item, feature) in features {
          try store.teach(ConceptExample(
            conceptID: conceptID, itemIdentity: ConceptIdentity.of(item),
            isPositive: isPositive, features: feature))
        }
        let concepts = self.concepts
        let examples = try concepts.flatMap { try store.examples(conceptID: $0.id) }
        let currentItems = self.items
        let recognitions = await Task.detached(priority: .utility) {
          let provider = try? ConceptModelManager().provider()
          return await ConceptRecognitionService().recognize(
            items: currentItems, concepts: concepts, examples: examples, provider: provider)
        }.value
        self.recognitionByItem = recognitions
        if self.receipt == nil { self.currentPlan = nil }
        self.refreshConceptProposals(for: itemIDs)
        if !itemIDs.isEmpty {
          let changedConceptIDs = ConceptProposalInvalidator().changedConfirmedConceptIDs(
            before: recognitionBefore, after: recognitions, itemIDs: itemIDs)
          let namingRuleIDs = Set(self.namingRules.filter {
            $0.condition.conceptID.map(changedConceptIDs.contains) == true
          }.map(\.id))
          let invalidated = ConceptProposalInvalidator().invalidate(
            proposals: self.proposals, renames: self.renameProposals,
            moveRuleIDs: [], namingRuleIDs: namingRuleIDs, itemIDs: itemIDs)
          self.renameProposals = invalidated.renames
          try database.saveRenameProposals(self.renameProposals)
        }
        self.statusMessage = "已记录 \(features.count) 个\(isPositive ? "正例" : "反例")；新的相似文件将等待审核"
      } catch { self.lastError = error.localizedDescription }
    }
  }

  func replaceConceptLabel(
    from oldConceptID: UUID, to newConceptID: UUID, itemID: UUID
  ) {
    guard let database, !isWorking, !isTeachingConcept, oldConceptID != newConceptID,
      concepts.contains(where: { $0.id == oldConceptID }),
      concepts.contains(where: { $0.id == newConceptID }),
      let item = items.first(where: { $0.id == itemID })
    else { return }
    let recognitionBefore = recognitionByItem
    if receipt == nil { currentPlan = nil }
    isTeachingConcept = true
    Task { [weak self] in
      guard let self else { return }
      defer { self.isTeachingConcept = false }
      do {
        let (feature, modelFailed) = await Task.detached(priority: .utility) {
          let manager = ConceptModelManager()
          let provider = try? manager.provider()
          var feature = await ConceptTextFeatureExtractor().extract(item: item)
          if let provider,
            let visual = try? await ConceptFeatureExtractor(provider: provider).extract(item: item)
          {
            feature.modelVersion = visual.modelVersion
            feature.visualVector = visual.visualVector
          }
          return (feature, manager.isInstalled && provider == nil)
        }.value
        if modelFailed { self.conceptModelStatus = "图像概念模型损坏，请重新下载" }
        let store = ConceptStore(database: database)
        try store.replaceLabel(
          itemIdentity: ConceptIdentity.of(item), features: feature,
          from: oldConceptID, to: newConceptID)
        let concepts = self.concepts
        let examples = try concepts.flatMap { try store.examples(conceptID: $0.id) }
        let currentItems = self.items
        let recognitions = await Task.detached(priority: .utility) {
          let provider = try? ConceptModelManager().provider()
          return await ConceptRecognitionService().recognize(
            items: currentItems, concepts: concepts, examples: examples, provider: provider)
        }.value
        self.recognitionByItem = recognitions
        if self.receipt == nil { self.currentPlan = nil }
        self.refreshConceptProposals(for: [itemID])
        let changedConceptIDs = ConceptProposalInvalidator().changedConfirmedConceptIDs(
          before: recognitionBefore, after: recognitions, itemIDs: [itemID])
        let namingRuleIDs = Set(self.namingRules.filter {
          $0.condition.conceptID.map(changedConceptIDs.contains) == true
        }.map(\.id))
        let invalidated = ConceptProposalInvalidator().invalidate(
          proposals: self.proposals, renames: self.renameProposals,
          moveRuleIDs: [], namingRuleIDs: namingRuleIDs, itemIDs: [itemID])
        self.renameProposals = invalidated.renames
        try database.saveRenameProposals(self.renameProposals)
        self.statusMessage = "已替换文件概念；整理目标仍需按规则审核"
      } catch { self.lastError = error.localizedDescription }
    }
  }

  private func conceptSnapshot(for url: URL) -> ItemSnapshot? {
    guard let values = try? url.resourceValues(forKeys: [
      .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .isPackageKey,
      .fileSizeKey, .fileResourceIdentifierKey, .volumeIdentifierKey,
    ]), values.isSymbolicLink != true, values.isPackage != true else { return nil }
    let kind: ItemKind
    if values.isDirectory == true { kind = .directory }
    else if values.isRegularFile == true { kind = .file }
    else { return nil }
    return ItemSnapshot(
      sessionID: session?.id ?? UUID(), path: url.path, name: url.lastPathComponent,
      kind: kind, fileExtension: url.pathExtension.lowercased(),
      size: Int64(values.fileSize ?? 0),
      resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
      volumeIdentifier: values.volumeIdentifier.map { String(describing: $0) })
  }

  private func refreshConceptProposals(for itemIDs: Set<UUID>) {
    guard let session else { return }
    let validDestinations = Set(destinations.filter { $0.kind == .category }.map(\.id))
    for item in items where itemIDs.contains(item.id) && !decisionLocks.contains(item.id) {
      let context = DeterministicClassifier().context(for: item)
      let evaluation = RuleEngine().evaluate(
        item: context, rules: rules,
        recognition: recognitionByItem[item.id], concepts: concepts)
      let proposal: ClassificationProposal
      switch evaluation {
      case .matchedMove(let ruleID, let destinationID)
      where validDestinations.contains(destinationID):
        proposal = ClassificationProposal(
          sessionID: session.id, itemID: item.id, action: .move,
          destinationID: destinationID, source: .user, reviewDecision: .ready,
          reason: "匹配已确认概念的整理规则",
          evidence: [Evidence(kind: "rule", detail: ruleID.uuidString, weight: 1)])
      case .matchedKeep:
        proposal = ClassificationProposal(
          sessionID: session.id, itemID: item.id, action: .keep,
          source: .user, reviewDecision: .keep, reason: "匹配用户保留规则")
      default:
        proposal = ClassificationProposal(
          sessionID: session.id, itemID: item.id, action: .keep,
          source: .user, reviewDecision: .needsReview,
          reason: "概念已更新，请确认整理目标")
      }
      if let index = proposals.firstIndex(where: { $0.itemID == item.id }) {
        proposals[index] = proposal
      }
    }
    try? database?.saveProposals(proposals)
  }

  func interpretRule(_ text: String) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !isInterpretingRule
    else { return }
    isInterpretingRule = true
    ruleDrafts = []
    namingRuleDrafts = []
    ruleInterpretationWarnings = []
    lastError = nil
    Task { [weak self] in
      guard let self else { return }
      defer { self.isInterpretingRule = false }
      do {
        let interpreter = AppleRuleInterpreter()
        let result = try await RuleInterpretationEngine().interpret(
          text: text,
          destinations: self.destinations,
          concepts: self.concepts,
          interpreter: interpreter)
        self.ruleDrafts = result.organizationDrafts
        self.namingRuleDrafts = result.namingDrafts
        self.ruleInterpretationWarnings = result.warnings
      } catch {
        self.lastError = error.localizedDescription
      }
    }
  }

  func saveRuleDraft(_ draft: RuleDraft) {
    guard let workspace else { return }
    guard draft.condition.hasDeterministicConditions || draft.condition.semanticDescription != nil
    else {
      lastError = "请补全规则条件"
      return
    }
    if let conceptID = draft.condition.conceptID,
      !concepts.contains(where: { $0.id == conceptID })
    {
      lastError = "概念已不存在"
      return
    }
    let destinationID: UUID?
    switch draft.action {
    case .move:
      guard let selectedID = draft.destinationID,
        destinations.contains(where: { $0.id == selectedID })
      else {
        lastError = "请补全规则条件并选择有效目标"
        return
      }
      destinationID = selectedID
    case .keep:
      destinationID = nil
    }
    let rule = OrganizationRule(
      workspaceID: workspace.id,
      originalText: draft.originalText,
      action: draft.action,
      condition: draft.condition,
      destinationID: destinationID
    )
    do {
      try database?.saveRule(rule)
      rules.append(rule)
      ruleDrafts.removeAll { $0.id == draft.id }
      statusMessage = "规则已保存，将用于下一次整理"
    } catch { lastError = error.localizedDescription }
  }

  func toggleRule(_ rule: OrganizationRule) {
    guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
    rules[index].isEnabled.toggle()
    do { try database?.saveRule(rules[index]) } catch { lastError = error.localizedDescription }
  }

  func deleteRule(_ rule: OrganizationRule) {
    do {
      try database?.deleteRule(rule.id)
      rules.removeAll { $0.id == rule.id }
    } catch { lastError = error.localizedDescription }
  }

  func saveNamingRuleDraft(
    _ draft: NamingRuleDraft,
    exampleOriginalName: String = "",
    exampleExpectedName: String? = nil
  ) {
    guard let workspace else { return }
    do {
      let exampleEvaluation = NamingRuleExampleEvaluator().evaluate(
        operations: draft.operations,
        condition: draft.condition,
        originalName: exampleOriginalName,
        expectedName: exampleExpectedName)
      if let reason = exampleEvaluation.blockingReason {
        throw OrganizerError.invalidFilename(reason)
      }
      let operations = draft.operations
      try NamingOperationEngine().validate(operations: operations)
      guard draft.condition.hasDeterministicConditions
        || draft.condition.semanticDescription != nil
      else { throw OrganizerError.invalidFilename("请补全命名规则条件") }
      if let conceptID = draft.condition.conceptID,
        !concepts.contains(where: { $0.id == conceptID })
      {
        throw OrganizerError.invalidFilename("概念已不存在")
      }
      let rule = NamingRule(
        workspaceID: workspace.id,
        originalText: draft.originalText,
        condition: draft.condition,
        operations: operations)
      try database?.saveNamingRule(rule)
      namingRules.append(rule)
      namingRuleDrafts.removeAll { $0.id == draft.id }
      statusMessage = "命名规则已保存，将用于下一次整理"
    } catch { lastError = error.localizedDescription }
  }

  func toggleNamingRule(_ rule: NamingRule) {
    guard let index = namingRules.firstIndex(where: { $0.id == rule.id }) else { return }
    namingRules[index].isEnabled.toggle()
    do { try database?.saveNamingRule(namingRules[index]) }
    catch { lastError = error.localizedDescription }
  }

  func deleteNamingRule(_ rule: NamingRule) {
    do {
      try database?.deleteNamingRule(rule.id)
      namingRules.removeAll { $0.id == rule.id }
    } catch { lastError = error.localizedDescription }
  }

  func approveNamingRuleSuggestion(_ suggestion: NamingRuleSuggestion) {
    guard let workspace else { return }
    var updated = suggestion
    updated.state = .approved
    let rule = NamingRule(
      workspaceID: workspace.id,
      originalText: "根据已确认改名生成：\(suggestion.template.pattern)",
      condition: suggestion.condition,
      template: suggestion.template,
      isDerived: true)
    do {
      try database?.saveNamingRule(rule)
      try database?.saveNamingRuleSuggestion(updated)
      namingRules.append(rule)
      namingRuleSuggestions.removeAll { $0.id == suggestion.id }
    } catch { lastError = error.localizedDescription }
  }

  func rejectNamingRuleSuggestion(_ suggestion: NamingRuleSuggestion) {
    var updated = suggestion
    updated.state = .rejected
    do {
      try database?.saveNamingRuleSuggestion(updated)
      namingRuleSuggestions.removeAll { $0.id == suggestion.id }
    } catch { lastError = error.localizedDescription }
  }

  func useHistoryEntry(_ entry: HistoryEntry) {
    guard let receipt = entry.receipt, !isWorking else { return }
    currentPlan = entry.plan
    self.receipt = receipt
    statusMessage = "已载入历史整理，可检查并撤销"
  }

  private func updateSession(_ state: SessionState, finished: Bool = false, error: String? = nil) {
    guard var session else { return }
    session.state = state
    session.errorMessage = error
    if finished { session.finishedAt = Date() }
    self.session = session
    try? database?.saveSession(session)
  }

  private func resetSession() {
    activeExecutor?.cancel()
    runningTask?.cancel()
    session = nil
    items = []
    destinations = []
    proposals = []
    folderProposals = []
    renameProposals = []
    selectedItemIDs = []
    selectedSourceIDs = []
    selectedExistingWorkPaths = []
    selectedItemID = nil
    recognitionByItem = [:]
    decisionLocks = []
    discoveredCount = 0
    skippedCount = 0
    progress = nil
    currentPlan = nil
    receipt = nil
    namingRuleDrafts = []
    lastError = nil
  }

  private func loadWorkspaceArtifacts(_ workspace: Workspace, database: AppDatabase) {
    do {
      let roleOverrides = try database.catalogProfileOverrides(workspaceID: workspace.id)
        .compactMapValues { $0.role }
      let indexed = try DestinationCatalogService().index(workspace: workspace,
        maxDepth: 4, roleOverrides: roleOverrides)
      let learning = LearningService(database: database)
      try learning.refreshExistingLibrarySamples(
        libraryID: workspace.id,
        root: URL(fileURLWithPath: workspace.libraryPath, isDirectory: true),
        destinations: indexed)
      destinations = try learning.enrich(destinations: indexed, libraryID: workspace.id)
      creatorIdentities = try database.creatorIdentities(workspaceID: workspace.id)
      let namingLearning = NamingLearningService(database: database)
      try namingLearning.refreshExistingLibrarySamples(
        workspaceID: workspace.id,
        root: URL(fileURLWithPath: workspace.libraryPath, isDirectory: true),
        destinations: destinations)
      rules = try database.rules(workspaceID: workspace.id)
      namingRules = try database.namingRules(workspaceID: workspace.id)
      namingRuleSuggestions = try database.namingRuleSuggestions(workspaceID: workspace.id)
        .filter { $0.state == .pending }
      historyEntries = try HistoryStore(database: database).entries(workspaceID: workspace.id)
      let moveSamples = try learning.activeSamples(libraryID: workspace.id)
        .filter { $0.confirmation != .existingLibrary }.count
      let renameSamples = try namingLearning.activeSamples(workspaceID: workspace.id)
        .filter { $0.source != .existingLibrary }.count
      learningSampleCount = moveSamples + renameSamples
    } catch { lastError = error.localizedDescription }
  }

  private func refreshHistory() {
    guard let workspace, let database else { return }
    historyEntries = (try? HistoryStore(database: database).entries(workspaceID: workspace.id)) ?? []
  }

  private func refreshLearningCount() {
    guard let workspace, let database else { return }
    let moveSamples = (try? LearningService(database: database)
      .activeSamples(libraryID: workspace.id)
      .filter { $0.confirmation != .existingLibrary }.count) ?? 0
    let renameSamples = (try? NamingLearningService(database: database)
      .activeSamples(workspaceID: workspace.id)
      .filter { $0.source != .existingLibrary }.count) ?? 0
    learningSampleCount = moveSamples + renameSamples
  }

  private func refreshNamingLearning() {
    guard let workspace, let database else { return }
    do {
      let service = NamingLearningService(database: database)
      namingRuleSuggestions = try service.suggestRules(workspaceID: workspace.id)
        .filter { $0.state == .pending }
    } catch { lastError = error.localizedDescription }
  }

  private func setProgress(_ value: OrganizationProgress, sessionID: UUID) {
    guard session?.id == sessionID else { return }
    progress = value
  }

  private func updateScanProgress(total: Int?, sessionID: UUID) {
    setProgress(
      OrganizationProgress(
        phase: .scanning,
        completed: discoveredCount + skippedCount,
        total: total,
        skipped: skippedCount,
        isIndeterminate: total == nil,
        isCancellable: true
      ),
      sessionID: sessionID
    )
  }

  private func advanceOperationProgress(result: OperationResult, sessionID: UUID) {
    guard var current = progress, current.phase == .executing || current.phase == .undoing else {
      return
    }
    current.completed = min(current.completed + 1, current.total ?? current.completed + 1)
    if result.state == .failed || result.state == .blocked {
      current.failed += 1
    }
    setProgress(current, sessionID: sessionID)
  }

  private func detachFromFolderProposals(_ itemIDs: Set<UUID>) {
    for index in folderProposals.indices {
      folderProposals[index].relatedItemIDs.removeAll { itemIDs.contains($0) }
      if folderProposals[index].relatedItemIDs.isEmpty {
        folderProposals[index].status = .rejected
      }
    }
    try? database?.saveFolderProposals(folderProposals)
  }
}
