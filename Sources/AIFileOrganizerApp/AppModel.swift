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
  @Published var historyEntries: [HistoryEntry] = []
  @Published var learningSampleCount = 0
  @Published var isInterpretingRule = false
  @Published private(set) var decisionLocks: Set<UUID> = []
  @Published var lastError: String?

  private(set) var database: AppDatabase?
  private var runningTask: Task<Void, Never>?

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
        seedWorkspaceDemo(database: database)
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

  private func seedWorkspaceDemo(database: AppDatabase) {
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
    try? database.saveWorkspace(workspace)
    try? database.saveSession(session)
    try? database.saveSnapshots([item])
    try? database.saveProposals([proposal])
    self.workspace = workspace
    self.session = session
    items = [item]
    destinations = [destination]
    proposals = [proposal]
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

  var canExecute: Bool {
    !isWorking && receipt == nil && workspace != nil
      && (!readyProposals.isEmpty || folderProposals.contains { $0.status == .approved })
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
        self.folderProposals = result.folderProposals
        self.modelStatus = result.modelStatus
        try database.saveProposals(result.proposals)
        try database.saveFolderProposals(result.folderProposals)
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
    runningTask?.cancel()
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
      let plan = try PlanBuilder().build(
        sessionID: session.id,
        workspace: workspace,
        items: items,
        destinations: destinations,
        proposals: proposals,
        folderProposals: folderProposals
      )
      guard !plan.operations.isEmpty else {
        lastError = "当前没有可执行的移动"
        return false
      }
      isWorking = true
      updateSession(.preflighting)
      progress = OrganizationProgress(
        phase: .preflighting,
        total: plan.operations.count,
        isCancellable: false
      )
      defer {
        progress = nil
        isWorking = false
      }
      let access = try SecurityScopedBookmarks.resolve(workspace)
      defer { access.stop() }
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
      }
      do {
        let access = try SecurityScopedBookmarks.resolve(workspace)
        defer { access.stop() }
        let executor = SafePlanExecutor(workspace: workspace, database: database)
        for try await event in executor.execute(plan) {
          try Task.checkCancellation()
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
          case .finished(let receipt): self.receipt = receipt
          }
        }
        let hasFailure =
          self.receipt?.results.contains { $0.state == .failed || $0.state == .blocked } ?? false
        self.updateSession(hasFailure ? .partial : .completed, finished: true)
        self.statusMessage = hasFailure ? "整理部分完成" : "整理完成"
        self.refreshHistory()
        self.refreshLearningCount()
      } catch is CancellationError {
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
      }
      do {
        let access = try SecurityScopedBookmarks.resolve(workspace)
        defer { access.stop() }
        let executor = SafePlanExecutor(workspace: workspace, database: database)
        var finalReceipt: ExecutionReceipt?
        for try await event in executor.undo(plan: plan, receipt: receipt) {
          try Task.checkCancellation()
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
        let blocked = finalReceipt?.results.filter { $0.state == .blocked }.count ?? 0
        self.statusMessage = blocked == 0 ? "本次整理已撤销" : "撤销完成，\(blocked) 项因状态变化被保留"
        self.receipt = blocked == 0 ? nil : finalReceipt
        self.refreshHistory()
        self.refreshLearningCount()
      } catch {
        if error is CancellationError {
          self.statusMessage = "已停止撤销，已完成的项目保持当前状态"
        } else {
          self.lastError = error.localizedDescription
        }
      }
    }
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
    Task { [weak self] in
      guard let self else { return }
      defer { self.isInterpretingRule = false }
      do {
        self.ruleDrafts = try await AppleRuleInterpreter().interpret(
          text: text, destinations: self.destinations)
      } catch {
        self.lastError = error.localizedDescription
      }
    }
  }

  func saveRuleDraft(_ draft: RuleDraft) {
    guard let workspace, let destinationID = draft.destinationID,
      destinations.contains(where: { $0.id == destinationID }),
      draft.condition.hasDeterministicConditions || draft.condition.semanticDescription != nil
    else {
      lastError = "请补全规则条件并选择有效目标"
      return
    }
    let rule = OrganizationRule(
      workspaceID: workspace.id,
      originalText: draft.originalText,
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
    runningTask?.cancel()
    session = nil
    items = []
    destinations = []
    proposals = []
    folderProposals = []
    selectedItemIDs = []
    selectedItemID = nil
    decisionLocks = []
    discoveredCount = 0
    skippedCount = 0
    progress = nil
    currentPlan = nil
    receipt = nil
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
      rules = try database.rules(workspaceID: workspace.id)
      historyEntries = try HistoryStore(database: database).entries(workspaceID: workspace.id)
      learningSampleCount = try learning.activeSamples(libraryID: workspace.id)
        .filter { $0.confirmation != .existingLibrary }.count
    } catch { lastError = error.localizedDescription }
  }

  private func refreshHistory() {
    guard let workspace, let database else { return }
    historyEntries = (try? HistoryStore(database: database).entries(workspaceID: workspace.id)) ?? []
  }

  private func refreshLearningCount() {
    guard let workspace, let database else { return }
    learningSampleCount = (try? LearningService(database: database)
      .activeSamples(libraryID: workspace.id)
      .filter { $0.confirmation != .existingLibrary }.count) ?? 0
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
