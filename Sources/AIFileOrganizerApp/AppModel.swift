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

  init() {
    let isUITesting = ProcessInfo.processInfo.arguments.contains("-ui-testing-reset")
    do {
      let database = try AppDatabase.applicationDatabase()
      self.database = database
      if isUITesting {
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
      if isUITesting {
        modelStatus = "本地 AI 状态将在整理时检查"
      } else {
        refreshModelStatus()
      }
    } catch {
      lastError = "数据库初始化失败：\(error.localizedDescription)"
    }
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
    selectedItemID = item.id
    statusMessage = "方案已生成，请确认移动位置"
    modelStatus = "Apple 本地模型可用"
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
    !isWorking && receipt == nil && workspace != nil
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
    rules = []
    ruleDrafts = []
    namingRules = []
    namingRuleDrafts = []
    namingRuleSuggestions = []
    historyEntries = []
    learningSampleCount = 0
  }

  func startOrganizing() {
    guard let workspace, let database, !isWorking else { return }
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
        let indexed = try DestinationCatalogService().index(workspace: workspace, maxDepth: 4)
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
        self.updateSession(.proposing)
        self.statusMessage = "正在生成整理方案…"
        let result = await ClassificationPipeline().run(
          sessionID: session.id,
          items: scanned,
          destinations: self.destinations.filter { $0.kind == .category },
          rules: self.rules,
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
    guard let workspace, let session, let database, !isWorking else { return false }
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
      let preparation = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        return try PlanBuilder().build(
          sessionID: session.id,
          workspace: workspace,
          items: planItems,
          destinations: planDestinations,
          proposals: planProposals,
          folderProposals: planFolderProposals,
          renameProposals: planRenameProposals
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
      let report = await SafePlanExecutor(workspace: workspace, database: database).preflight(
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
    guard let workspace, let database, var plan = currentPlan, !isWorking else { return }
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
        let executor = SafePlanExecutor(workspace: workspace, database: database)
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
    exampleEvaluation: NamingRuleExampleEvaluation? = nil
  ) {
    guard let workspace else { return }
    do {
      if let reason = exampleEvaluation?.blockingReason {
        throw OrganizerError.invalidFilename(reason)
      }
      let operations = draft.operations
      try NamingOperationEngine().validate(operations: operations)
      guard draft.condition.hasDeterministicConditions
        || draft.condition.semanticDescription != nil
      else { throw OrganizerError.invalidFilename("请补全命名规则条件") }
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
    selectedItemID = nil
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
      let indexed = try DestinationCatalogService().index(workspace: workspace, maxDepth: 4)
      let learning = LearningService(database: database)
      try learning.refreshExistingLibrarySamples(
        libraryID: workspace.id,
        root: URL(fileURLWithPath: workspace.libraryPath, isDirectory: true),
        destinations: indexed)
      destinations = try learning.enrich(destinations: indexed, libraryID: workspace.id)
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
