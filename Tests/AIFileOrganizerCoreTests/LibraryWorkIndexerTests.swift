import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct LibraryWorkIndexerTests {
  @Test func mixedPagesAndBonusDirectoryAreNotClassifiedAsCategory() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bonus = root.appendingPathComponent("bunga/作品/特典", isDirectory: true)
    try FileManager.default.createDirectory(at: bonus, withIntermediateDirectories: true)
    try Data([1]).write(to: root.appendingPathComponent("bunga/作品/001.jpg"))
    try Data([2]).write(to: bonus.appendingPathComponent("bonus.jpg"))
    let index = try LibraryWorkIndexer().index(root: root)
    #expect(index.nodes.first { $0.relativePath == "bunga/作品" }?.role == .uncertain)
    #expect(index.nodes.first { $0.relativePath == "bunga/作品/特典" }?.role == .uncertain)
    #expect(!index.nodes.contains { $0.relativePath.hasPrefix("bunga/作品/")
      && $0.role == .work })
    let workspace = Workspace(inboxPath: "/tmp", libraryPath: root.path,
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    let destinations = try DestinationIndexer().index(workspace: workspace, maxDepth: 4)
    #expect(!destinations.contains { $0.relativePath == "bunga/作品" && $0.kind == .category })
  }
  @Test func uncertainDirectoryCanBeCorrectedToCategory() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("unknown", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let automatic = try LibraryWorkIndexer().index(root: root)
    #expect(automatic.nodes.first?.role == .uncertain)
    let corrected = try LibraryWorkIndexer().index(root: root,
      roleOverrides: ["unknown": .category])
    #expect(corrected.nodes.first?.role == .category)
  }
  @Test func imageWorkIsOneUnitAndCreatorIsNotADestination() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let nestedWork = root.appendingPathComponent("bunga/作者/作品", isDirectory: true)
    let directWork = root.appendingPathComponent("bunga/单独作品", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedWork, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: directWork, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: nestedWork.appendingPathComponent("001.jpg"))
    try Data().write(to: nestedWork.appendingPathComponent("002.jpg"))
    try Data().write(to: directWork.appendingPathComponent("01.jpg"))
    try Data().write(to: root.appendingPathComponent("bunga/.hidden.jpg"))

    let index = try LibraryWorkIndexer().index(root: root)
    let roles = Dictionary(uniqueKeysWithValues: index.nodes.map { ($0.relativePath, $0.role) })

    #expect(roles["bunga"] == .category)
    #expect(roles["bunga/作者"] == .creator)
    #expect(roles["bunga/作者/作品"] == .work)
    #expect(roles["bunga/单独作品"] == .work)
    #expect(roles["bunga/作者/作品/001.jpg"] == nil)
    #expect(!index.destinations.contains { $0.relativePath == "bunga/作者" })
    #expect(!index.destinations.contains { $0.relativePath == "bunga/作者/作品" })
    let workspace = Workspace(
      inboxPath: "/tmp", libraryPath: root.path,
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    let indexedDestinations = try DestinationIndexer().index(workspace: workspace, maxDepth: 4)
    #expect(indexedDestinations.map(\.relativePath) == ["bunga"])
  }

  @Test func symlinkedWorkIsNotIndexed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    try Data().write(to: outside.appendingPathComponent("001.jpg"))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("linked"), withDestinationURL: outside)

    let index = try LibraryWorkIndexer().index(root: root)
    #expect(index.nodes.isEmpty)
  }
}
