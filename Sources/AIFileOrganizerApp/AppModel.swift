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
  @Published var currentPlan: OrganizationPlan?
  @Published var receipt: ExecutionReceipt?
  @Published var lastError: String?

  private(set) var database: AppDatabase?
  private var runningTask: Task<Void, Never>?

  init() {
    do {
      let database = try AppDatabase.applicationDatabase()
      self.database = database
      if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset") {
        try database.clearWorkspaces()
      }
      if let savedWorkspace = try database.latestWorkspace() {
        do {
          let access = try SecurityScopedBookmarks.resolve(savedWorkspace)
          access.stop()
          workspace = savedWorkspace
        } catch {
          workspace = nil
          lastError = error.localizedDescription
        }
      }
      refreshModelStatus()
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

  func configure(inbox: URL, library: URL) {
    do {
      let workspace = try SecurityScopedBookmarks.makeWorkspace(inbox: inbox, library: library)
      try database?.saveWorkspace(workspace)
      self.workspace = workspace
      lastError = nil
      statusMessage = "目录已授权，可以开始整理"
    } catch {
      lastError = error.localizedDescription
    }
  }

  func forgetWorkspace() {
    guard !isWorking else { return }
    do {
      try database?.clearWorkspaces()
    } catch {
      lastError = error.localizedDescription
      return
    }
    workspace = nil
    resetSession()
  }

  func startOrganizing() {
    guard let workspace, let database, !isWorking else { return }
    resetSession()
    isWorking = true
    let session = OrganizationSession(workspaceID: workspace.id, state: .scanning)
    self.session = session
    try? database.saveSession(session)
    runningTask = Task { [weak self] in
      guard let self else { return }
      do {
        let access = try SecurityScopedBookmarks.resolve(workspace)
        defer { access.stop() }
        self.destinations = try DestinationIndexer().index(workspace: workspace)
        var scanned: [ItemSnapshot] = []
        for try await event in LocalInboxScanner().scan(workspace, sessionID: session.id) {
          switch event {
          case .started:
            self.statusMessage = "正在扫描收件箱…"
          case .discovered(let item):
            scanned.append(item)
            self.items.append(item)
            self.discoveredCount += 1
          case .skipped(_, _):
            self.skippedCount += 1
          case .finished:
            break
          }
        }
        try database.saveSnapshots(scanned)
        self.updateSession(.proposing)
        self.statusMessage = "正在生成整理方案…"
        let result = await ClassificationPipeline().run(
          sessionID: session.id,
          items: scanned,
          destinations: self.destinations
        )
        self.proposals = result.proposals
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
      self.isWorking = false
    }
  }

  func cancel() {
    runningTask?.cancel()
    statusMessage = "正在安全停止…"
  }

  func setDestination(_ destinationID: UUID, for itemIDs: Set<UUID>) {
    guard let session else { return }
    currentPlan = nil
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
      defer { isWorking = false }
      let access = try SecurityScopedBookmarks.resolve(workspace)
      defer { access.stop() }
      let report = await SafePlanExecutor(workspace: workspace, database: database).preflight(plan)
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
      do {
        let access = try SecurityScopedBookmarks.resolve(workspace)
        defer { access.stop() }
        let executor = SafePlanExecutor(workspace: workspace, database: database)
        for try await event in executor.execute(plan) {
          switch event {
          case .started(let total): self.statusMessage = "正在执行 \(total) 项操作…"
          case .operationStarted: break
          case .operationFinished(let result):
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
      } catch is CancellationError {
        self.updateSession(.partial, finished: true)
        self.statusMessage = "已停止，已完成的项目保持不变"
      } catch {
        self.lastError = error.localizedDescription
        self.updateSession(.failed, finished: true, error: error.localizedDescription)
      }
      self.isWorking = false
    }
  }

  func undo() {
    guard let workspace, let database, let plan = currentPlan, let receipt, !isWorking else {
      return
    }
    isWorking = true
    runningTask = Task { [weak self] in
      guard let self else { return }
      do {
        let access = try SecurityScopedBookmarks.resolve(workspace)
        defer { access.stop() }
        let executor = SafePlanExecutor(workspace: workspace, database: database)
        var finalReceipt: ExecutionReceipt?
        for try await event in executor.undo(plan: plan, receipt: receipt) {
          if case .finished(let value) = event { finalReceipt = value }
        }
        let blocked = finalReceipt?.results.filter { $0.state == .blocked }.count ?? 0
        self.statusMessage = blocked == 0 ? "本次整理已撤销" : "撤销完成，\(blocked) 项因状态变化被保留"
        if blocked == 0 { self.receipt = nil }
      } catch {
        self.lastError = error.localizedDescription
      }
      self.isWorking = false
    }
  }

  func item(for proposal: ClassificationProposal) -> ItemSnapshot? {
    items.first { $0.id == proposal.itemID }
  }

  func destinationName(_ id: UUID?) -> String {
    guard let id else { return "未指定" }
    return destinations.first(where: { $0.id == id })?.displayName ?? "未知目标"
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
    discoveredCount = 0
    skippedCount = 0
    currentPlan = nil
    receipt = nil
    lastError = nil
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
