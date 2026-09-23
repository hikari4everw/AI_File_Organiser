import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct CatalogAnalysisTests {
  @Test func profilesEveryWorkNameAndReusesCachedResults() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let category = root.appendingPathComponent("bunga", isDirectory: true)
    try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for number in 0..<65 {
      let work = category.appendingPathComponent("[Circle (Author)] Work \(number)", isDirectory: true)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      try Data([0]).write(to: work.appendingPathComponent("001.jpg"))
    }
    let database = try AppDatabase.inMemory()
    let workspaceID = UUID()
    let index = try LibraryWorkIndexer().index(root: root)
    let service = CatalogAnalysisService(database: database)
    let first = try await service.analyze(index: index, workspaceID: workspaceID, root: root)
    let profile = try #require(first.profiles.first { $0.relativePath == "bunga" })
    #expect(profile.workNames.count == 65)
    #expect(profile.workNames.contains("[Circle (Author)] Work 64"))
    #expect(profile.totalWorks == 65)
    #expect(profile.contentAnalyzedWorks < 65)

    try service.setPurpose("同人志", for: "bunga", workspaceID: workspaceID)
    let second = try await service.analyze(index: index, workspaceID: workspaceID, root: root)
    #expect(second.reusedWorkCount == 65)
    #expect(second.profiles.first?.userPurpose == "同人志")
  }

  @Test func representativePagesAreDispersedAndBounded() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let work = root.appendingPathComponent("bunga/Work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for number in 1...11 {
      try Data([0]).write(to: work.appendingPathComponent(String(format: "%03d.jpg", number)))
    }
    let result = try await CatalogAnalysisService(database: try .inMemory()).analyze(
      index: LibraryWorkIndexer().index(root: root), workspaceID: UUID(), root: root)
    let sample = try #require(result.workAnalyses.first { $0.relativePath == "bunga/Work" })
    #expect(sample.representativePaths.count == 5)
    #expect(sample.representativePaths.first?.hasSuffix("001.jpg") == true)
    #expect(sample.representativePaths.last?.hasSuffix("011.jpg") == true)
  }

  @Test func corruptOptionalVisualModelDoesNotBlockNameAnalysis() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let work = root.appendingPathComponent("bunga/Work", isDirectory: true)
    let modelRoot = root.appendingPathComponent("model", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: modelRoot.appendingPathComponent("MobileCLIP-BLT.mlmodelc"),
      withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([0]).write(to: work.appendingPathComponent("001.jpg"))

    let result = try await CatalogAnalysisService(
      database: .inMemory(), modelManager: ConceptModelManager(root: modelRoot)
    ).analyze(index: LibraryWorkIndexer().index(root: root), workspaceID: UUID(), root: root)

    #expect(result.profiles.first { $0.relativePath == "bunga" }?.workNames == ["Work"])
  }

  @Test func excludingMistakenSampleChangesCatalogRevision() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let work = root.appendingPathComponent("bunga/Work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([0]).write(to: work.appendingPathComponent("001.jpg"))
    let database = try AppDatabase.inMemory()
    let workspaceID = UUID()
    let service = CatalogAnalysisService(database: database)
    let index = try LibraryWorkIndexer().index(root: root)

    let before = try await service.analyze(index: index, workspaceID: workspaceID, root: root)
    try database.saveCatalogProfileOverride(
      CatalogProfileOverride(excludedWorkPaths: ["bunga/Work"]),
      workspaceID: workspaceID, path: "bunga")
    let after = try await service.analyze(index: index, workspaceID: workspaceID, root: root)

    #expect(after.profiles.first?.workNames.isEmpty == true)
    #expect(after.revision != before.revision)
  }
}
