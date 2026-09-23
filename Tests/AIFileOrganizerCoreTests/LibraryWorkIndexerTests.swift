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
    // 作者层名字能在子作品名里作为社团出现 → 作者容器。
    let nestedWork = root.appendingPathComponent(
      "bunga/おじたん屋さん/[おじたん屋さん (まめおじたん)] 旧作 [DL版]", isDirectory: true)
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
    #expect(roles["bunga/おじたん屋さん"] == .creator)
    #expect(roles["bunga/おじたん屋さん/[おじたん屋さん (まめおじたん)] 旧作 [DL版]"] == .work)
    #expect(roles["bunga/单独作品"] == .work)
    #expect(roles["bunga/おじたん屋さん/[おじたん屋さん (まめおじたん)] 旧作 [DL版]/001.jpg"] == nil)
    #expect(!index.destinations.contains { $0.relativePath == "bunga/おじたん屋さん" })
    let workspace = Workspace(
      inboxPath: "/tmp", libraryPath: root.path,
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    let indexedDestinations = try DestinationIndexer().index(workspace: workspace, maxDepth: 4)
    #expect(indexedDestinations.map(\.relativePath) == ["bunga"])
  }

  /// 回归：中间层曾被一律判为作者容器，导致“分类/分类/作品”这类深层分类目录
  /// 从目标列表整体消失，只能靠人工角色修正救回来。
  @Test func deepCategoryIsNotSwallowedAsCreatorContainer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let deep = root.appendingPathComponent("Media/Comics/Deep", isDirectory: true)
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: deep.appendingPathComponent("001.jpg"))

    let index = try LibraryWorkIndexer().index(root: root)
    let roles = Dictionary(uniqueKeysWithValues: index.nodes.map { ($0.relativePath, $0.role) })
    #expect(roles["Media"] == .category)
    #expect(roles["Media/Comics"] == .category)
    #expect(roles["Media/Comics/Deep"] == .work)

    let workspace = Workspace(
      inboxPath: "/tmp", libraryPath: root.path,
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    let destinations = try DestinationIndexer().index(workspace: workspace, maxDepth: 4)
    #expect(destinations.map(\.relativePath) == ["Media", "Media/Comics"])
  }

  /// 同一类歧义也存在于“只放压缩包”的层：名字不匹配子作品时按分类处理。
  @Test func archiveOnlyLayerDefaultsToCategoryUnlessNameMatchesChildWork() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let nestedCategory = root.appendingPathComponent("Media/単行本", isDirectory: true)
    let creator = root.appendingPathComponent("bunga/おじたん屋さん", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedCategory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: creator, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: nestedCategory.appendingPathComponent("volume-1.cbz"))
    try Data().write(
      to: creator.appendingPathComponent("[おじたん屋さん (まめおじたん)] 旧作 [DL版].cbz"))

    let index = try LibraryWorkIndexer().index(root: root)
    let roles = Dictionary(uniqueKeysWithValues: index.nodes.map { ($0.relativePath, $0.role) })
    #expect(roles["Media/単行本"] == .category)
    #expect(roles["bunga/おじたん屋さん"] == .creator)
  }

  /// 回归：作者目录里的作品常常只写标题（如“旧作”），名字里不含社团/作者。
  /// 这类目录必须仍然被认成作者容器，否则已有作者目录无法被复用。
  @Test func authorFolderWithPlainlyTitledWorksStaysCreatorContainer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let plain = root.appendingPathComponent("bunga/[おじたん屋さん] まめおじたん/旧作",
      isDirectory: true)
    let bracketed = root.appendingPathComponent("bunga/[青空 (作者甲)]/新作", isDirectory: true)
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bracketed, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: plain.appendingPathComponent("001.jpg"))
    try Data().write(to: bracketed.appendingPathComponent("001.jpg"))

    let index = try LibraryWorkIndexer().index(root: root)
    let roles = Dictionary(uniqueKeysWithValues: index.nodes.map { ($0.relativePath, $0.role) })
    #expect(roles["bunga/[おじたん屋さん] まめおじたん"] == .creator)
    #expect(roles["bunga/[青空 (作者甲)]"] == .creator)
    #expect(!index.destinations.contains { $0.relativePath.hasPrefix("bunga/[") })
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
