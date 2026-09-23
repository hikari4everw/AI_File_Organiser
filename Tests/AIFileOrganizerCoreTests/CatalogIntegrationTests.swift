import Foundation
import Testing

@testable import AIFileOrganizerCore

private struct OfflineProvider: ClassificationProvider {
  var availabilityDescription: String { "不可用" }
  var isAvailable: Bool { false }
  func classify(items: [ItemContext], destinations: [DestinationProfile]) async throws
    -> [ModelProposal] { [] }
}

@Suite struct CatalogIntegrationTests {
  @Test func exampleDoujinshiCanBeReviewedMovedIntoCreatorFolderAndUndone() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let category = library.appendingPathComponent("bunga", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
    for name in [
      "[青空工房 (まめ)] 旧作 [DL版]",
      "[月影亭 (あき)] 別作 [中国翻訳]",
      "[雨の庭 (ゆき)] 再録 [DL版]",
    ] {
      let work = category.appendingPathComponent(name, isDirectory: true)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      try Data([0]).write(to: work.appendingPathComponent("001.jpg"))
    }
    let name = "[おじたん屋さん (まめおじたん)] 愛娘性活 [中国翻訳] [DL版] [山樱汉化]"
    let source = inbox.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data([1]).write(to: source.appendingPathComponent("001.jpg"))
    let volume = try PathSafety.volumeIdentifier(for: inbox)
    let workspace = Workspace(inboxPath: inbox.path, libraryPath: library.path,
      inboxVolumeID: volume, libraryVolumeID: volume)
    let database = try AppDatabase.inMemory()
    let session = OrganizationSession(workspaceID: workspace.id)
    try database.saveWorkspace(workspace)
    try database.saveSession(session)
    let index = try LibraryWorkIndexer().index(root: library)
    let catalog = try await CatalogAnalysisService(database: database).analyze(
      index: index, workspaceID: workspace.id, root: library)
    let destinations = try DestinationIndexer().index(workspace: workspace)
    let item = ItemSnapshot(sessionID: session.id, path: source.path,
      name: name, kind: .directory)
    let parsed = WorkNameParser().parse(name)
    let author = CreatorIdentity(workspaceID: workspace.id,
      japaneseName: try #require(parsed.authorNames.first), englishName: nil,
      circleName: parsed.circleName)
    let result = await ClassificationPipeline(provider: OfflineProvider()).run(
      sessionID: session.id, items: [item], destinations: destinations,
      catalog: catalog, creatorResolutions: [item.id: .confirmed(author)])
    let suggestion = try #require(result.proposals.first)
    #expect(suggestion.destinationID == destinations.first?.id)
    #expect(suggestion.reviewDecision == .needsReview)
    #expect(suggestion.suggestedFolderName != nil)
    var folder = try #require(result.folderProposals.first)
    #expect(folder.parentDestinationID == destinations.first?.id)
    folder.status = .approved
    let plan = try PlanBuilder().build(sessionID: session.id, workspace: workspace,
      items: [item], destinations: destinations, proposals: [suggestion],
      folderProposals: [folder], catalogRevision: catalog.revision)
    let executor = SafePlanExecutor(workspace: workspace, database: database,
      catalogRevision: catalog.revision)
    #expect((await executor.preflight(plan)).isReady)
    var receipt: ExecutionReceipt?
    for try await event in executor.execute(plan) {
      if case .finished(let value) = event { receipt = value }
    }
    let newPath = category.appendingPathComponent(folder.displayName,
      isDirectory: true).appendingPathComponent(name)
    #expect(FileManager.default.fileExists(atPath: newPath.appendingPathComponent("001.jpg").path))
    for try await _ in executor.undo(plan: plan, receipt: try #require(receipt)) {}
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("001.jpg").path))
    #expect(!FileManager.default.fileExists(atPath: newPath.path))
  }
}
