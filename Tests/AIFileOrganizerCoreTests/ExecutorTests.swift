import Foundation
import Testing

@testable import AIFileOrganizerCore

private actor ExecutionProgressRecorder {
  private var values: [OrganizationProgress] = []

  func record(_ value: OrganizationProgress) { values.append(value) }
  func snapshot() -> [OrganizationProgress] { values }
}

@Suite struct ExecutorTests {
  @Test func approvedCreatorFolderIsNestedUnderKnownCategoryAndUndoKeepsCategory() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("[青空 (作者甲)] 作品", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("page".utf8).write(to: source.appendingPathComponent("01.jpg"))
    let item = ItemSnapshot(sessionID: fixture.sessionID, path: source.path,
      name: source.lastPathComponent, kind: .directory)
    let category = DestinationProfile(relativePath: "Docs", displayName: "Docs")
    let proposal = ClassificationProposal(sessionID: fixture.sessionID, itemID: item.id,
      action: .move, destinationID: category.id, suggestedFolderName: "[青空] 作者甲",
      source: .deterministic, reviewDecision: .needsReview, status: .approved,
      reason: "creator", creatorID: UUID())
    let folder = FolderProposal(sessionID: fixture.sessionID,
      normalizedName: PathSafety.normalizedFolderKey("[青空] 作者甲"),
      displayName: "[青空] 作者甲", status: .approved,
      relatedItemIDs: [item.id], parentDestinationID: category.id)
    let plan = try PlanBuilder().build(sessionID: fixture.sessionID,
      workspace: fixture.workspace, items: [item], destinations: [category],
      proposals: [proposal], folderProposals: [folder], catalogRevision: "r1")
    let creator = fixture.docs.appendingPathComponent("[青空] 作者甲", isDirectory: true)
    #expect(plan.operations.first?.destinationPath == creator.path)
    #expect(plan.operations.last?.destinationPath == creator.appendingPathComponent(item.name).path)
    let executor = SafePlanExecutor(workspace: fixture.workspace,
      database: fixture.database, catalogRevision: "r1")
    var receipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { receipt = value }
    }
    #expect(FileManager.default.fileExists(atPath: creator.appendingPathComponent(item.name).path))
    for try await _ in executor.undo(plan: plan, receipt: try #require(receipt)) {}
    #expect(!FileManager.default.fileExists(atPath: creator.path))
    #expect(FileManager.default.fileExists(atPath: fixture.docs.path))
  }

  @Test func onlyExplicitlySelectedLibraryWorkMayMove() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.docs.appendingPathComponent("old-work", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("page".utf8).write(to: source.appendingPathComponent("01.jpg"))
    let item = ItemSnapshot(sessionID: fixture.sessionID, path: source.path,
      name: source.lastPathComponent, kind: .directory)
    let category = DestinationProfile(relativePath: "Docs", displayName: "Docs")
    let creator = fixture.docs.appendingPathComponent("Creator", isDirectory: true)
    try FileManager.default.createDirectory(at: creator, withIntermediateDirectories: true)
    let proposal = ClassificationProposal(sessionID: fixture.sessionID, itemID: item.id,
      action: .move, destinationID: category.id, source: .deterministic,
      reviewDecision: .needsReview, status: .approved, reason: "creator",
      creatorDestinationPath: "Docs/Creator")
    let blocked = try PlanBuilder().build(sessionID: fixture.sessionID,
      workspace: fixture.workspace, items: [item], destinations: [category],
      proposals: [proposal], folderProposals: [])
    #expect(blocked.operations.isEmpty)
    let allowed = try PlanBuilder().build(sessionID: fixture.sessionID,
      workspace: fixture.workspace, items: [item], destinations: [category],
      proposals: [proposal], folderProposals: [], selectedSourceIDs: [item.id],
      catalogRevision: "r1")
    #expect(allowed.reviewedSourcePaths == [source.path])
    #expect((await SafePlanExecutor(workspace: fixture.workspace,
      database: fixture.database, catalogRevision: "r1").preflight(allowed)).isReady)
    #expect(!(await SafePlanExecutor(workspace: fixture.workspace,
      database: fixture.database, catalogRevision: "r2").preflight(allowed)).isReady)
  }

  @Test func legacyPlanCannotMoveLibrarySource() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.docs.appendingPathComponent("old.pdf")
    try Data("old".utf8).write(to: source)
    let operation = PlannedOperation(sequence: 0, kind: .move, sourcePath: source.path,
      destinationPath: fixture.docs.appendingPathComponent("new.pdf").path,
      preSnapshot: try .capture(source))
    let plan = OrganizationPlan(sessionID: fixture.sessionID, operations: [operation])
    #expect(!(await SafePlanExecutor(workspace: fixture.workspace,
      database: fixture.database).preflight(plan)).isReady)
  }

  @Test func selectedNestedInboxWorkRequiresExactSourceReview() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let incoming = fixture.inbox.appendingPathComponent("batch", isDirectory: true)
    try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
    let source = incoming.appendingPathComponent("work.pdf")
    try Data("work".utf8).write(to: source)
    let item = ItemSnapshot(sessionID: fixture.sessionID, path: source.path,
      name: source.lastPathComponent, kind: .file)
    let destination = DestinationProfile(relativePath: "Docs", displayName: "Docs")
    let proposal = ClassificationProposal(sessionID: fixture.sessionID, itemID: item.id,
      action: .move, destinationID: destination.id, source: .user,
      reviewDecision: .ready, reason: "selected")
    let skipped = try PlanBuilder().build(sessionID: fixture.sessionID,
      workspace: fixture.workspace, items: [item], destinations: [destination],
      proposals: [proposal], folderProposals: [])
    #expect(skipped.operations.isEmpty)
    let plan = try PlanBuilder().build(sessionID: fixture.sessionID,
      workspace: fixture.workspace, items: [item], destinations: [destination],
      proposals: [proposal], folderProposals: [], selectedSourceIDs: [item.id])
    #expect(plan.reviewedSourcePaths == [source.path])
    #expect((await SafePlanExecutor(workspace: fixture.workspace,
      database: fixture.database).preflight(plan)).isReady)
    var forged = plan
    forged.reviewedSourcePaths = []
    #expect(!(await SafePlanExecutor(workspace: fixture.workspace,
      database: fixture.database).preflight(forged)).isReady)
  }

  @Test func selectedParentAndChildCannotEnterOnePlan() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let parent = fixture.inbox.appendingPathComponent("batch", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let child = parent.appendingPathComponent("work.pdf")
    try Data("work".utf8).write(to: child)
    let items = [ItemSnapshot(sessionID: fixture.sessionID, path: parent.path,
      name: parent.lastPathComponent, kind: .directory),
      ItemSnapshot(sessionID: fixture.sessionID, path: child.path,
        name: child.lastPathComponent, kind: .file)]
    let destination = DestinationProfile(relativePath: "Docs", displayName: "Docs")
    let proposals = items.map { ClassificationProposal(sessionID: fixture.sessionID,
      itemID: $0.id, action: .move, destinationID: destination.id,
      source: .user, reviewDecision: .ready, reason: "selected") }
    #expect(throws: (any Error).self) {
      try PlanBuilder().build(sessionID: fixture.sessionID, workspace: fixture.workspace,
        items: items, destinations: [destination], proposals: proposals, folderProposals: [],
        selectedSourceIDs: [items[1].id])
    }
  }

  @Test func selectedLibrarySymlinkIsBlockedEvenWhenItPointsInsideLibrary() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let actual = fixture.docs.appendingPathComponent("real.pdf")
    try Data("real".utf8).write(to: actual)
    let link = fixture.docs.appendingPathComponent("link.pdf")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
    let operation = PlannedOperation(sequence: 0, kind: .move, sourcePath: link.path,
      destinationPath: fixture.docs.appendingPathComponent("other.pdf").path,
      preSnapshot: try .capture(link))
    let plan = OrganizationPlan(sessionID: fixture.sessionID, operations: [operation],
      reviewedSourcePaths: [link.path], catalogRevision: "r1")
    #expect(!(await SafePlanExecutor(workspace: fixture.workspace,
      database: fixture.database, catalogRevision: "r1").preflight(plan)).isReady)
  }
  @Test func planCombinesMoveAndRenameIntoOneAtomicOperation() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("hash.pdf")
    try Data("Annual Report".utf8).write(to: source)
    let item = ItemSnapshot(
      sessionID: fixture.sessionID, path: source.path, name: source.lastPathComponent,
      kind: .file, fileExtension: "pdf")
    let destination = DestinationProfile(relativePath: "Docs", displayName: "Docs")
    let move = ClassificationProposal(
      sessionID: fixture.sessionID, itemID: item.id, action: .move,
      destinationID: destination.id, source: .user, reviewDecision: .ready,
      status: .approved, reason: "user")
    let rename = RenameProposal(
      sessionID: fixture.sessionID, itemID: item.id, originalName: item.name,
      suggestedBaseName: "Annual Report", source: .foundationModel,
      disposition: .approved, reason: "title")

    let plan = try PlanBuilder().build(
      sessionID: fixture.sessionID, workspace: fixture.workspace, items: [item],
      destinations: [destination], proposals: [move], folderProposals: [],
      renameProposals: [rename])

    #expect(plan.operations.count == 1)
    #expect(plan.operations[0].kind == .move)
    #expect(plan.operations[0].destinationPath == fixture.docs.appendingPathComponent("Annual Report.pdf").path)
    #expect(plan.operations[0].namingDecisionFeatures?.originalBaseName == "hash")
    #expect(plan.operations[0].namingDecisionFeatures?.finalBaseName == "Annual Report")
  }

  @Test func planCreatesRenameOnlyOperationForKeptItem() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("hash.txt")
    try Data("Notes".utf8).write(to: source)
    let item = ItemSnapshot(
      sessionID: fixture.sessionID, path: source.path, name: source.lastPathComponent,
      kind: .file, fileExtension: "txt")
    let keep = ClassificationProposal(
      sessionID: fixture.sessionID, itemID: item.id, action: .keep,
      source: .user, reviewDecision: .keep, reason: "keep")
    let rename = RenameProposal(
      sessionID: fixture.sessionID, itemID: item.id, originalName: item.name,
      suggestedBaseName: "Meeting Notes", source: .user,
      disposition: .edited, reason: "user")

    let plan = try PlanBuilder().build(
      sessionID: fixture.sessionID, workspace: fixture.workspace, items: [item],
      destinations: [], proposals: [keep], folderProposals: [], renameProposals: [rename])

    #expect(plan.operations.count == 1)
    #expect(plan.operations[0].kind == .rename)
    #expect(plan.operations[0].destinationPath == fixture.inbox.appendingPathComponent("Meeting Notes.txt").path)
  }

  @Test func executeAndUndoRenameOnlyAlsoRetractsNamingLearning() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("hash.txt")
    try Data("Notes".utf8).write(to: source)
    let item = ItemSnapshot(
      sessionID: fixture.sessionID, path: source.path, name: source.lastPathComponent,
      kind: .file, fileExtension: "txt")
    let rename = RenameProposal(
      sessionID: fixture.sessionID, itemID: item.id, originalName: item.name,
      suggestedBaseName: "Meeting Notes", source: .user,
      disposition: .edited, reason: "user")
    let plan = try PlanBuilder().build(
      sessionID: fixture.sessionID, workspace: fixture.workspace, items: [item],
      destinations: [], proposals: [], folderProposals: [], renameProposals: [rename])
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)

    var receipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { receipt = value }
    }

    let renamed = fixture.inbox.appendingPathComponent("Meeting Notes.txt")
    #expect(FileManager.default.fileExists(atPath: renamed.path))
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try NamingLearningService(database: fixture.database)
      .activeSamples(workspaceID: fixture.workspace.id).count == 1)

    for try await _ in executor.undo(plan: plan, receipt: try #require(receipt)) {}

    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(!FileManager.default.fileExists(atPath: renamed.path))
    #expect(try NamingLearningService(database: fixture.database)
      .activeSamples(workspaceID: fixture.workspace.id).isEmpty)
  }

  @Test func movesAndRenamesComicDirectoryAsOneUnitWithoutChangingPages() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("Comic", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("page-1".utf8).write(to: source.appendingPathComponent("01.jpg"))
    try Data("page-2".utf8).write(to: source.appendingPathComponent("02.jpg"))
    let item = ItemSnapshot(
      sessionID: fixture.sessionID, path: source.path, name: source.lastPathComponent,
      kind: .directory, shallowExtensions: ["jpg"])
    let destination = DestinationProfile(relativePath: "Docs", displayName: "Docs")
    let move = ClassificationProposal(
      sessionID: fixture.sessionID, itemID: item.id, action: .move,
      destinationID: destination.id, source: .user, reviewDecision: .ready,
      status: .approved, reason: "user")
    let rename = RenameProposal(
      sessionID: fixture.sessionID, itemID: item.id, originalName: item.name,
      suggestedBaseName: "月光漫画", source: .user, disposition: .edited, reason: "user")
    let plan = try PlanBuilder().build(
      sessionID: fixture.sessionID, workspace: fixture.workspace, items: [item],
      destinations: [destination], proposals: [move], folderProposals: [],
      renameProposals: [rename])
    #expect(plan.operations.count == 1)
    #expect(plan.operations[0].kind == .move)
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
    var receipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { receipt = value }
    }

    let moved = fixture.docs.appendingPathComponent("月光漫画", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("01.jpg").path))
    #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("02.jpg").path))
    #expect(!FileManager.default.fileExists(atPath: source.path))

    for try await _ in executor.undo(plan: plan, receipt: try #require(receipt)) {}
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("01.jpg").path))
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("02.jpg").path))
  }

  @Test func renamePreflightBlocksCaseInsensitiveSiblingCollision() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("source.txt")
    try Data("source".utf8).write(to: source)
    try Data("occupied".utf8).write(to: fixture.inbox.appendingPathComponent("REPORT.txt"))
    let operation = PlannedOperation(
      sequence: 0, kind: .rename, sourcePath: source.path,
      destinationPath: fixture.inbox.appendingPathComponent("report.txt").path,
      preSnapshot: try .capture(source))

    let report = await SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
      .preflight(OrganizationPlan(sessionID: fixture.sessionID, operations: [operation]))

    #expect(!report.isReady)
    #expect(report.issues.contains { $0.message.contains("目标已存在") })
  }
  @Test func executeAndUndoMoveWithoutOverwrite() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("report.txt")
    try Data("original".utf8).write(to: source)
    let item = ItemSnapshot(
      sessionID: fixture.sessionID, path: source.path, name: source.lastPathComponent, kind: .file)
    let destination = DestinationProfile(
      relativePath: "Docs", displayName: "Docs", keywords: ["docs"])
    let proposal = ClassificationProposal(
      sessionID: fixture.sessionID, itemID: item.id, action: .move,
      destinationID: destination.id, source: .user, reviewDecision: .ready,
      status: .approved, reason: "test"
    )
    let plan = try PlanBuilder().build(
      sessionID: fixture.sessionID, workspace: fixture.workspace,
      items: [item], destinations: [destination], proposals: [proposal], folderProposals: []
    )
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
    #expect((await executor.preflight(plan)).isReady)
    var receipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { receipt = value }
    }
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(
      FileManager.default.fileExists(atPath: fixture.docs.appendingPathComponent("report.txt").path)
    )
    let unwrapped = try #require(receipt)
    for try await _ in executor.undo(plan: plan, receipt: unwrapped) {}
    #expect(FileManager.default.fileExists(atPath: source.path))
    let storedUndo = try #require(try fixture.database.receipt(planID: plan.id))
    #expect(storedUndo.results.allSatisfy { $0.state == .undone })
    var secondUndoTotal: Int?
    for try await event in executor.undo(plan: plan, receipt: storedUndo) {
      if case .started(let total) = event { secondUndoTotal = total }
    }
    #expect(secondUndoTotal == 0)
  }

  @Test func preflightBlocksExistingDestination() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("same.txt")
    let destinationURL = fixture.docs.appendingPathComponent("same.txt")
    try Data("source".utf8).write(to: source)
    try Data("destination".utf8).write(to: destinationURL)
    let operation = PlannedOperation(
      sequence: 0, kind: .move, sourcePath: source.path,
      destinationPath: destinationURL.path, preSnapshot: try .capture(source)
    )
    let report = await SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
      .preflight(OrganizationPlan(sessionID: fixture.sessionID, operations: [operation]))
    #expect(!report.isReady)
    #expect(report.issues.contains { $0.message.contains("目标已存在") })
  }

  @Test func preflightProgressReachesOperationTotalAndReportsIssues() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("same.txt")
    let destinationURL = fixture.docs.appendingPathComponent("same.txt")
    try Data("source".utf8).write(to: source)
    try Data("destination".utf8).write(to: destinationURL)
    let operation = PlannedOperation(
      sequence: 0,
      kind: .move,
      sourcePath: source.path,
      destinationPath: destinationURL.path,
      preSnapshot: try .capture(source)
    )
    let recorder = ExecutionProgressRecorder()

    _ = await SafePlanExecutor(workspace: fixture.workspace, database: fixture.database).preflight(
      OrganizationPlan(sessionID: fixture.sessionID, operations: [operation]),
      progress: { value in await recorder.record(value) }
    )

    let values = await recorder.snapshot()
    #expect(values.first?.completed == 0)
    #expect(values.last?.completed == 1)
    #expect(values.last?.total == 1)
    #expect(values.last?.failed == 1)
    #expect(values.allSatisfy { !$0.isCancellable })
  }

  @Test func approvedFolderIsCreatedAndRemovedOnUndo() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("paper.pdf")
    try Data("pdf".utf8).write(to: source)
    let item = ItemSnapshot(
      sessionID: fixture.sessionID, path: source.path, name: source.lastPathComponent, kind: .file)
    let classification = ClassificationProposal(
      sessionID: fixture.sessionID, itemID: item.id, action: .suggestFolder,
      suggestedFolderName: "Research", source: .foundationModel,
      reviewDecision: .needsReview, reason: "test"
    )
    let folder = FolderProposal(
      sessionID: fixture.sessionID, normalizedName: "research",
      displayName: "Research", status: .approved, relatedItemIDs: [item.id]
    )
    let plan = try PlanBuilder().build(
      sessionID: fixture.sessionID, workspace: fixture.workspace,
      items: [item], destinations: [], proposals: [classification], folderProposals: [folder]
    )
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
    var receipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { receipt = value }
    }
    let created = fixture.library.appendingPathComponent("Research", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: created.path))
    let unwrapped = try #require(receipt)
    var undoReceipt: ExecutionReceipt?
    for try await event in executor.undo(plan: plan, receipt: unwrapped) {
      if case .finished(let value) = event { undoReceipt = value }
    }
    #expect(undoReceipt?.results.first { $0.operationID == plan.operations[0].id }?.error == nil)
    #expect(undoReceipt?.results.allSatisfy { $0.state == .undone } == true)
    #expect(!FileManager.default.fileExists(atPath: created.path))
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test func directorySnapshotDetectsChangedChildrenBeforeUndo() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Comic", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("page-one".utf8).write(to: folder.appendingPathComponent("01.txt"))
    let snapshot = try FileSnapshot.capture(folder)

    try Data("page-two".utf8).write(to: folder.appendingPathComponent("02.txt"))

    #expect(!snapshot.matches(folder))
  }

  @Test func successfulMoveLearnsOnceAndUndoRetractsSample() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("score.pdf")
    try Data("piano score".utf8).write(to: source)
    let item = ItemSnapshot(
      sessionID: fixture.sessionID,
      path: source.path,
      name: source.lastPathComponent,
      kind: .file,
      fileExtension: "pdf"
    )
    let destination = DestinationProfile(relativePath: "Docs", displayName: "Docs")
    let proposal = ClassificationProposal(
      sessionID: fixture.sessionID,
      itemID: item.id,
      action: .move,
      destinationID: destination.id,
      source: .user,
      reviewDecision: .ready,
      status: .approved,
      reason: "user"
    )
    let plan = try PlanBuilder().build(
      sessionID: fixture.sessionID,
      workspace: fixture.workspace,
      items: [item],
      destinations: [destination],
      proposals: [proposal],
      folderProposals: []
    )
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
    var receipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { receipt = value }
    }
    let completedReceipt = try #require(receipt)
    #expect(
      try LearningService(database: fixture.database).activeSamples(libraryID: fixture.workspace.id)
        .count == 1
    )

    for try await _ in executor.execute(plan) {}
    #expect(
      try LearningService(database: fixture.database).activeSamples(libraryID: fixture.workspace.id)
        .count == 1
    )
    for try await _ in executor.undo(plan: plan, receipt: completedReceipt) {}
    #expect(
      try LearningService(database: fixture.database).activeSamples(libraryID: fixture.workspace.id)
        .isEmpty
    )
    for try await _ in executor.execute(plan) {}
    #expect(
      try LearningService(database: fixture.database).activeSamples(libraryID: fixture.workspace.id)
        .count == 1
    )
  }

  @Test func cancellationFinishesAndPersistsReceiptBeforeStreamEnds() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("cancel.txt")
    try Data("cancel".utf8).write(to: source)
    let operation = PlannedOperation(
      sequence: 0, kind: .move, sourcePath: source.path,
      destinationPath: fixture.docs.appendingPathComponent("cancel.txt").path,
      preSnapshot: try .capture(source))
    let plan = OrganizationPlan(sessionID: fixture.sessionID, operations: [operation])
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
    executor.cancel()
    var finished: ExecutionReceipt?
    do {
      for try await event in executor.execute(plan) {
        if case .finished(let receipt) = event { finished = receipt }
      }
    } catch is CancellationError {}
    let receipt = try #require(finished)
    #expect(receipt.wasCancelled)
    #expect(try fixture.database.receipt(planID: plan.id)?.id == receipt.id)
  }

  @Test func blockedUndoReceiptKeepsOperationRetryable() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("retry.txt")
    try Data("original".utf8).write(to: source)
    let operation = PlannedOperation(
      sequence: 0,
      kind: .move,
      sourcePath: source.path,
      destinationPath: fixture.docs.appendingPathComponent("retry.txt").path,
      preSnapshot: try .capture(source)
    )
    let plan = OrganizationPlan(sessionID: fixture.sessionID, operations: [operation])
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)
    var executionReceipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { executionReceipt = value }
    }
    try Data("occupied".utf8).write(to: source)
    var blockedReceipt: ExecutionReceipt?
    for try await event in executor.undo(plan: plan, receipt: try #require(executionReceipt)) {
      if case .finished(let value) = event { blockedReceipt = value }
    }
    let blocked = try #require(blockedReceipt)
    #expect(blocked.isUndoReceipt)
    #expect(blocked.results.first?.state == .blocked)

    try FileManager.default.removeItem(at: source)
    var retriedReceipt: ExecutionReceipt?
    for try await event in executor.undo(plan: plan, receipt: blocked) {
      if case .finished(let value) = event { retriedReceipt = value }
    }
    #expect(retriedReceipt?.results.first?.state == .undone)
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  /// 文件级撤销阻断：目标文件在移动后被改动时，`revert` 必须拒绝回退
  /// （`SafePlanExecutor.swift:378-380`），且**只阻断该项**，其余项照常回退。
  /// 此前只测过目录清单变化（`directorySnapshotDetectsChangedChildrenBeforeUndo`），
  /// 文件级快照不匹配这条分支从未被执行。
  @Test func undoBlocksOnlyTheModifiedFileAndRevertsTheRest() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let untouchedSource = fixture.inbox.appendingPathComponent("untouched.txt")
    let modifiedSource = fixture.inbox.appendingPathComponent("modified.txt")
    try Data("keep-me".utf8).write(to: untouchedSource)
    try Data("will-change".utf8).write(to: modifiedSource)

    let untouchedOperation = PlannedOperation(
      sequence: 0, kind: .move, sourcePath: untouchedSource.path,
      destinationPath: fixture.docs.appendingPathComponent("untouched.txt").path,
      preSnapshot: try .capture(untouchedSource))
    let modifiedOperation = PlannedOperation(
      sequence: 1, kind: .move, sourcePath: modifiedSource.path,
      destinationPath: fixture.docs.appendingPathComponent("modified.txt").path,
      preSnapshot: try .capture(modifiedSource))
    let plan = OrganizationPlan(
      sessionID: fixture.sessionID, operations: [untouchedOperation, modifiedOperation])
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)

    let executed = try await runExecution(executor, plan: plan)
    #expect(executed.results.allSatisfy { $0.state == .completed })

    // 保持字节数不变地改写内容：size 相同，只有 resourceIdentifier 会变，
    // 因此这条断言确实在验证快照比对，而不是被体积差异蒙混过去。
    try Data("CHANGED!!".utf8).write(
      to: URL(fileURLWithPath: modifiedOperation.destinationPath))

    let undone = try await runUndo(
      executor, plan: plan, receipt: executed)
    let states = Dictionary(
      uniqueKeysWithValues: undone.results.map { ($0.operationID, $0.state) })
    #expect(states[modifiedOperation.id] == .blocked)
    #expect(states[untouchedOperation.id] == .undone)
    #expect(
      undone.results.first { $0.operationID == modifiedOperation.id }?
        .error?.contains("目标文件已被修改或缺失") == true)
    // 未受阻的项真的回到了原位。
    #expect(FileManager.default.fileExists(atPath: untouchedSource.path))
    // 受阻项保持在被改动后的位置，不会被强行挪回。
    #expect(FileManager.default.fileExists(atPath: modifiedOperation.destinationPath))
  }

  /// 第 2 项在**预检无法察觉**的情况下于执行阶段失败 → 该项 failed，
  /// 但执行器不会因此中止，第 3 项仍会被执行，并留下部分回执。
  ///
  /// 制造方式是把第 2 项的目标父目录 `chmod 0555`：预检只看
  /// `fileExists(isDirectory:)`（对只读目录仍为 true，且 `contentsOfDirectory`
  /// 仍可枚举），而 `FileManager.moveItem` 会因没有写权限失败（实测
  /// NSError 513 "you don't have permission to access"）。
  ///
  /// 这里不能用"删除源文件"或"悬空符号链接"：前者被预检的
  /// `源文件在方案生成后发生变化` 拦住并让整份计划抛 `planBlocked`；
  /// 后者被预检的 `hasSiblingCollision` 枚举发现——两者都到不了执行阶段。
  @Test func midPlanApplyingFailureDoesNotStopTheRest() async throws {
    let fixture = try makeFixture()
    // 目标目录会被改成只读，确保清理前恢复权限。
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: fixture.docs.path)
      try? FileManager.default.removeItem(at: fixture.root)
    }
    let lockedDirectory = fixture.library.appendingPathComponent("Locked", isDirectory: true)
    try FileManager.default.createDirectory(
      at: lockedDirectory, withIntermediateDirectories: true)

    let names = ["one.txt", "two.txt", "three.txt"]
    for name in names {
      try Data("content-\(name)".utf8).write(to: fixture.inbox.appendingPathComponent(name))
    }
    let targetDirectories = [fixture.docs, lockedDirectory, fixture.docs]
    let operations = try names.enumerated().map { index, name -> PlannedOperation in
      let source = fixture.inbox.appendingPathComponent(name)
      return PlannedOperation(
        sequence: index, kind: .move, sourcePath: source.path,
        destinationPath: targetDirectories[index].appendingPathComponent(name).path,
        preSnapshot: try .capture(source))
    }
    let plan = OrganizationPlan(sessionID: fixture.sessionID, operations: operations)
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)

    // 只读目标目录：预检通过，apply 阶段失败。
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: lockedDirectory.path)
    #expect((await executor.preflight(plan)).isReady, "只读目录不应被预检拦下")

    let outcome = try await runExecution(executor, plan: plan)
    let states = Dictionary(uniqueKeysWithValues: outcome.results.map { ($0.operationID, $0.state) })
    let blockedOperation = operations[1]

    #expect(states[operations[0].id] == .completed)
    #expect(states[blockedOperation.id] == .failed, "权限拒绝发生在 apply 阶段，应记为 failed")
    #expect(states[operations[2].id] == .completed, "一项失败不应中止后续操作")
    #expect(!outcome.wasCancelled)
    // `isFinal` 表示"执行流已跑完"，而不是"全部成功"：正常跑完即使有失败项
    // 也是 isFinal == true；false 只出现在取消/中断路径。
    // 逐项结果本身已经把失败如实记录下来。
    #expect(outcome.isFinal)
    #expect(outcome.results.contains { $0.state == .failed })
    // 中间回执确实落库，供跨启动恢复使用。
    let stored = try #require(try fixture.database.receipt(planID: plan.id))
    #expect(stored.results.count == 3)
    // 失败项必须还原权限后才能清理，因此这里只断言未成功移动。
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.inbox.appendingPathComponent("two.txt").path))
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.docs.appendingPathComponent("one.txt").path))
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.docs.appendingPathComponent("three.txt").path))
  }

  /// 重跑同一不可变计划时，已完成项不得重复执行（`SafePlanExecutor.swift:167`）。
  @Test func rerunningCompletedPlanDoesNotRepeatOperations() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let names = ["alpha.txt", "beta.txt"]
    for name in names {
      try Data("body-\(name)".utf8).write(to: fixture.inbox.appendingPathComponent(name))
    }
    let operations = try names.enumerated().map { index, name -> PlannedOperation in
      let source = fixture.inbox.appendingPathComponent(name)
      return PlannedOperation(
        sequence: index, kind: .move, sourcePath: source.path,
        destinationPath: fixture.docs.appendingPathComponent(name).path,
        preSnapshot: try .capture(source))
    }
    let plan = OrganizationPlan(sessionID: fixture.sessionID, operations: operations)
    let executor = SafePlanExecutor(workspace: fixture.workspace, database: fixture.database)

    let first = try await runExecution(executor, plan: plan)
    #expect(first.results.allSatisfy { $0.state == .completed })

    // 重跑：源已消失、目标快照一致、数据库状态为 completed → 视为已完成。
    #expect((await executor.preflight(plan)).isReady)
    let second = try await runExecution(executor, plan: plan)
    #expect(second.results.allSatisfy { $0.state == .completed })
    #expect(second.results.map(\.operationID) == first.results.map(\.operationID))
    for name in names {
      let path = fixture.docs.appendingPathComponent(name).path
      #expect(FileManager.default.fileExists(atPath: path))
      #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("body-\(name)".utf8))
    }
  }

  /// 收集执行流，返回最终回执。
  private func runExecution(
    _ executor: SafePlanExecutor, plan: OrganizationPlan
  ) async throws -> ExecutionReceipt {
    var receipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { receipt = value }
    }
    return try #require(receipt)
  }

  /// 收集撤销流，返回最终回执。
  private func runUndo(
    _ executor: SafePlanExecutor, plan: OrganizationPlan, receipt: ExecutionReceipt
  ) async throws -> ExecutionReceipt {
    var undone: ExecutionReceipt?
    for try await event in executor.undo(plan: plan, receipt: receipt) {
      if case .finished(let value) = event { undone = value }
    }
    return try #require(undone)
  }

  @Test func staleFolderProposalCannotOverrideManualDestination() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.inbox.appendingPathComponent("manual.pdf")
    try Data("manual".utf8).write(to: source)
    let item = ItemSnapshot(
      sessionID: fixture.sessionID, path: source.path, name: source.lastPathComponent,
      kind: .file, fileExtension: "pdf")
    let manualDestination = DestinationProfile(relativePath: "Docs", displayName: "Docs")
    let manual = ClassificationProposal(
      sessionID: fixture.sessionID, itemID: item.id, action: .move,
      destinationID: manualDestination.id, source: .user, reviewDecision: .ready,
      status: .overridden, reason: "manual")
    let stale = FolderProposal(
      sessionID: fixture.sessionID, normalizedName: "research", displayName: "Research",
      status: .approved, relatedItemIDs: [item.id])

    let plan = try PlanBuilder().build(
      sessionID: fixture.sessionID, workspace: fixture.workspace,
      items: [item], destinations: [manualDestination], proposals: [manual],
      folderProposals: [stale])

    let move = try #require(plan.operations.first { $0.kind == .move })
    #expect(move.destinationPath == fixture.docs.appendingPathComponent("manual.pdf").path)
    #expect(!plan.operations.contains { $0.kind == .createDirectory })
  }

  private func makeFixture() throws -> (
    root: URL, inbox: URL, library: URL, docs: URL,
    workspace: Workspace, database: AppDatabase, sessionID: UUID
  ) {
    let root = try temporaryDirectory()
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
