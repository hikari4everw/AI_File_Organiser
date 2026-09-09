import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct DestinationCatalogTests {
  @Test func discoversFourLevelsAndKeepsDuplicateLeafPathsDistinct() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let first = library.appendingPathComponent("Work/Contracts/2026/Signed", isDirectory: true)
    let duplicate = library.appendingPathComponent("Personal/Contracts", isDirectory: true)
    let tooDeep = first.appendingPathComponent("Archive", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tooDeep, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: duplicate, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let volume = try PathSafety.volumeIdentifier(for: inbox)
    let workspace = Workspace(
      inboxPath: inbox.path,
      libraryPath: library.path,
      inboxVolumeID: volume,
      libraryVolumeID: volume
    )

    let values = try DestinationIndexer().index(workspace: workspace, maxDepth: 4)
    let paths = Set(values.map(\.relativePath))

    #expect(paths.contains("Work/Contracts/2026/Signed"))
    #expect(paths.contains("Personal/Contracts"))
    #expect(!paths.contains("Work/Contracts/2026/Signed/Archive"))
    #expect(values.filter { $0.displayName == "Contracts" }.count == 2)
    #expect(Set(values.map(\.id)).count == values.count)
  }

  @Test func excludedDestinationPrunesItsSubtree() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(
      at: library.appendingPathComponent("Private/Receipts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let volume = try PathSafety.volumeIdentifier(for: inbox)
    let workspace = Workspace(
      inboxPath: inbox.path,
      libraryPath: library.path,
      inboxVolumeID: volume,
      libraryVolumeID: volume
    )

    let values = try DestinationIndexer().index(
      workspace: workspace,
      maxDepth: 4,
      kindsByRelativePath: ["Private": .excluded]
    )

    #expect(values.contains { $0.relativePath == "Private" && $0.kind == .excluded })
    #expect(!values.contains { $0.relativePath == "Private/Receipts" })
  }
}

