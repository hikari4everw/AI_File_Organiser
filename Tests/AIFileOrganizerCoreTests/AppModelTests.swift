import Foundation
import Testing

@testable import AIFileOrganizerApp
@testable import AIFileOrganizerCore

@Suite @MainActor struct AppModelTests {
  @Test func creatorDestinationIsSavedOnlyAfterCompletedMove() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("bunga/[青空] 作者甲", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let database = try AppDatabase.inMemory()
    let workspace = Workspace(inboxPath: "/tmp/Inbox", libraryPath: root.path,
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    let model = AppModel(database: database)
    let category = DestinationProfile(relativePath: "bunga", displayName: "bunga")
    model.destinations = [category]
    let session = OrganizationSession(workspaceID: workspace.id)
    let item = ItemSnapshot(sessionID: session.id, path: "/tmp/Inbox/work",
      name: "[青空 (作者甲)] 新作", kind: .directory)
    model.items = [item]
    model.proposals = [ClassificationProposal(sessionID: session.id, itemID: item.id,
      action: .move, destinationID: category.id, source: .deterministic,
      reviewDecision: .ready, reason: "creator")]
    let move = PlannedOperation(sequence: 0, kind: .move, sourcePath: item.path,
      destinationPath: destination.appendingPathComponent(item.name).path,
      itemID: item.id, destinationID: category.id)
    let plan = OrganizationPlan(sessionID: session.id, operations: [move])
    try model.recordCompletedCreatorDestinations(plan: plan,
      receipt: ExecutionReceipt(planID: plan.id, results: [
        OperationResult(operationID: move.id, state: .failed)]),
      workspace: workspace, database: database)
    #expect(try database.creatorIdentities(workspaceID: workspace.id).isEmpty)
    try model.recordCompletedCreatorDestinations(plan: plan,
      receipt: ExecutionReceipt(planID: plan.id, results: [
        OperationResult(operationID: move.id, state: .completed)]),
      workspace: workspace, database: database)
    #expect(try database.creatorIdentities(workspaceID: workspace.id).first?
      .preferredDestinations["bunga"] == "bunga/[青空] 作者甲")
  }
  @Test func existingCreatorFolderIsReusedAndFolderApprovalDoesNotPersistBeforeExecution() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("bunga/[おじたん屋さん] まめおじたん",
      isDirectory: true)
    let oldWork = folder.appendingPathComponent("旧作", isDirectory: true)
    try FileManager.default.createDirectory(at: oldWork, withIntermediateDirectories: true)
    try Data([1]).write(to: oldWork.appendingPathComponent("001.jpg"))
    let database = try AppDatabase.inMemory()
    let workspace = Workspace(inboxPath: "/tmp/Inbox", libraryPath: root.path,
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    let model = AppModel(database: database)
    model.workspace = workspace
    model.libraryIndex = try LibraryWorkIndexer().index(root: root)
    let category = DestinationProfile(relativePath: "bunga", displayName: "bunga")
    model.destinations = [category]
    let session = OrganizationSession(workspaceID: workspace.id)
    model.session = session
    let name = "[おじたん屋さん (まめおじたん)] 新作"
    let item = ItemSnapshot(sessionID: session.id, path: "/tmp/Inbox/" + name,
      name: name, kind: .directory)
    model.items = [item]
    let resolutions = try model.creatorResolutions(for: [item], workspace: workspace,
      database: database)
    guard case .confirmed(let creator) = resolutions[item.id] else {
      Issue.record("应匹配现有作者目录")
      return
    }
    #expect(creator.preferredDestinations["bunga"] ==
      "bunga/[おじたん屋さん] まめおじたん")
    model.proposals = [ClassificationProposal(sessionID: session.id, itemID: item.id,
      action: .move, destinationID: category.id,
      suggestedFolderName: "[おじたん屋さん] まめおじたん",
      source: .deterministic, reviewDecision: .needsReview, reason: "author")]
    let suggestion = FolderProposal(sessionID: session.id,
      normalizedName: PathSafety.normalizedFolderKey("[おじたん屋さん] まめおじたん"),
      displayName: "[おじたん屋さん] まめおじたん",
      relatedItemIDs: [item.id], parentDestinationID: category.id)
    model.folderProposals = [suggestion]
    model.setFolderProposal(suggestion.id, approved: true)
    #expect(try database.creatorIdentities(workspaceID: workspace.id).isEmpty)
  }
  @Test func existingWorkAlreadyAtSuggestedCategoryShowsKeepInsteadOfMove() {
    let model = AppModel()
    model.workspace = Workspace(inboxPath: "/tmp/Inbox", libraryPath: "/tmp/Library",
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    let category = DestinationProfile(relativePath: "bunga", displayName: "bunga")
    model.destinations = [category]
    let item = ItemSnapshot(sessionID: UUID(), path: "/tmp/Library/bunga/old-work",
      name: "old-work", kind: .directory)
    let proposal = ClassificationProposal(sessionID: item.sessionID, itemID: item.id,
      action: .move, destinationID: category.id, source: .deterministic,
      reviewDecision: .ready, reason: "category")
    let displayed = model.normalizeExistingWorkProposal(proposal, item: item)
    #expect(displayed.action == .keep)
    #expect(displayed.reviewDecision == .keep)
  }
  @Test func changingCatalogPurposeInvalidatesPreparedPlanAndSuggestions() throws {
    let database = try AppDatabase.inMemory()
    let model = AppModel(database: database)
    let workspace = Workspace(inboxPath: "/tmp/inbox", libraryPath: "/tmp/library",
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    model.workspace = workspace
    let session = OrganizationSession(workspaceID: workspace.id)
    model.session = session
    let item = ItemSnapshot(sessionID: session.id, path: "/tmp/inbox/work",
      name: "work", kind: .directory)
    model.items = [item]
    model.proposals = [ClassificationProposal(sessionID: session.id, itemID: item.id,
      action: .move, destinationID: UUID(), source: .deterministic,
      reviewDecision: .ready, status: .approved, reason: "old", catalogRevision: "old")]
    model.folderProposals = [FolderProposal(sessionID: session.id,
      normalizedName: "creator", displayName: "Creator", status: .approved,
      relatedItemIDs: [item.id])]
    model.currentPlan = OrganizationPlan(sessionID: session.id, operations: [],
      catalogRevision: "old")

    model.setCatalogPurpose("同人志", for: "bunga")

    #expect(model.currentPlan == nil)
    #expect(model.proposals.first?.reviewDecision == .needsReview)
    #expect(!model.canExecute)
    #expect(try database.catalogProfileOverride(workspaceID: workspace.id,
      path: "bunga")?.purpose == "同人志")
  }

  @Test func confirmingCreatorAliasReusesSavedIdentity() throws {
    let database = try AppDatabase.inMemory()
    let model = AppModel(database: database)
    let workspace = Workspace(inboxPath: "/tmp/inbox", libraryPath: "/tmp/library",
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    model.workspace = workspace
    let creator = try CreatorCatalog(database: database).create(workspaceID: workspace.id,
      japaneseName: "まめおじたん", englishName: nil, circleName: "おじたん屋さん")

    model.confirmCreatorAlias("Mame Ojitan", creatorID: creator.id,
      sourceURL: "https://example.test/creator")

    let parsed = WorkNameParser().parse("[おじたん屋さん (Mame Ojitan)] 新作")
    guard case .confirmed(let resolved) = try CreatorCatalog(database: database)
      .resolve(parsed, workspaceID: workspace.id) else {
      Issue.record("确认别名后应解析为原作者")
      return
    }
    #expect(resolved.id == creator.id)
  }
  @Test func saveReevaluatesRawExampleAgainstCurrentDraft() {
    let model = AppModel()
    model.workspace = Workspace(
      inboxPath: "/tmp/inbox",
      libraryPath: "/tmp/library",
      inboxVolumeID: "test-volume",
      libraryVolumeID: "test-volume")
    model.namingRules = []
    model.lastError = nil
    let draft = NamingRuleDraft(
      originalText: "删除 draft_ 前缀",
      condition: RuleCondition(filenameKeywords: ["draft_"]),
      operations: [.removeLiteralPrefix("draft_")])

    model.saveNamingRuleDraft(
      draft,
      exampleOriginalName: "report.pdf",
      exampleExpectedName: nil)

    #expect(model.namingRules.isEmpty)
    #expect(model.lastError?.contains("没有变化") == true)
  }

  @Test func executionIsBlockedWhileTeachingConcept() {
    let model = AppModel()
    model.workspace = Workspace(
      inboxPath: "/tmp/inbox", libraryPath: "/tmp/library",
      inboxVolumeID: "test-volume", libraryVolumeID: "test-volume")
    model.proposals = [ClassificationProposal(
      sessionID: UUID(), itemID: UUID(), action: .move,
      destinationID: UUID(), source: .user, reviewDecision: .ready,
      reason: "old concept route")]
    #expect(model.canExecute)

    model.isTeachingConcept = true

    #expect(!model.canExecute)
  }

  @Test func uiTestingDatabaseLivesInTemporaryDirectory() {
    let url = AppModel.uiTestingDatabaseURL
    #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    #expect(url.pathExtension == "sqlite")
  }

  @Test func independentEntryRefusesToReplaceUnreviewedInboxReviewWithoutConfirmation() throws {
    let database = try AppDatabase.inMemory()
    let model = AppModel(database: database)
    let workspace = Workspace(inboxPath: "/tmp/inbox", libraryPath: "/tmp/library",
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    model.workspace = workspace
    let session = OrganizationSession(workspaceID: workspace.id)
    model.session = session
    let inboxItem = ItemSnapshot(sessionID: session.id, path: "/tmp/inbox/new.pdf",
      name: "new.pdf", kind: .file, fileExtension: "pdf")
    model.items = [inboxItem]
    model.proposals = [ClassificationProposal(
      sessionID: session.id, itemID: inboxItem.id, action: .keep,
      source: .deterministic, reviewDecision: .needsReview, status: .pending, reason: "待确认")]
    model.selectedExistingWorkPaths = ["bunga/作品"]

    #expect(model.hasUnreviewedInboxWork)
    // 未确认时不得切换会话，收件箱复核必须原样保留。
    #expect(!model.startExistingWorkReview())
    #expect(model.session?.id == session.id)
    #expect(model.items.map(\.id) == [inboxItem.id])
  }

  @Test func independentEntryDoesNotOfferReplacementWhenInboxReviewIsFinished() throws {
    let database = try AppDatabase.inMemory()
    let model = AppModel(database: database)
    let workspace = Workspace(inboxPath: "/tmp/inbox", libraryPath: "/tmp/library",
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    model.workspace = workspace
    let session = OrganizationSession(workspaceID: workspace.id)
    model.session = session

    // 空会话没有未处理项目，切换不需要确认。
    #expect(!model.hasUnreviewedInboxWork)
    // 但没有勾选作品时仍然不能进入，避免生成空方案。
    #expect(model.selectedExistingWorkPaths.isEmpty)
    #expect(!model.startExistingWorkReview(confirmingReplacement: true))
  }

  @Test func existingWorkItemsIncludeOnlyReadableSelectedWorks() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let selected = root.appendingPathComponent("bunga/作品甲", isDirectory: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    try Data().write(to: selected.appendingPathComponent("001.jpg"))
    // 指向资料库外的符号链接作品必须被跳过。
    let symlink = root.appendingPathComponent("bunga/链接作品", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: symlink, withDestinationURL: root.appendingPathComponent("bunga/作品甲"))

    let model = AppModel()
    let sessionID = UUID()
    let items = model.existingWorkItems(
      from: [
        LibraryWorkNode(relativePath: "bunga/作品甲", role: .work, kind: .directory),
        LibraryWorkNode(relativePath: "bunga/链接作品", role: .work, kind: .directory),
        LibraryWorkNode(relativePath: "bunga/不存在", role: .work, kind: .directory),
      ],
      sessionID: sessionID, libraryRoot: root)

    #expect(items.count == 1)
    #expect(items.first?.name == "作品甲")
    #expect(items.first?.sessionID == sessionID)
    // 未勾选的作品不在输入里，也就不可能进入计划。
    #expect(!items.contains { $0.name == "作品乙" })
  }
}
