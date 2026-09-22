import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct PathSafetyTests {
  @Test func rejectsOverlappingWorkspace() throws {
    let root = try temporaryDirectory()
    let child = root.appendingPathComponent("child", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) {
      try PathSafety.validateWorkspace(inbox: root, library: child)
    }
  }

  @Test func allowsSeparateDirectoriesOnSameVolume() throws {
    let root = try temporaryDirectory()
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    let result = try PathSafety.validateWorkspace(inbox: inbox, library: library)
    #expect(result.0 == result.1)
  }

  @Test func folderNameValidation() throws {
    #expect(try PathSafety.validateFolderName("  工作资料  ") == "工作资料")
    for invalid in ["", ".hidden", "a/b", "a:b", ".."] {
      #expect(throws: (any Error).self) { try PathSafety.validateFolderName(invalid) }
    }
  }

  @Test func safeDestinationCannotEscapeLibrary() throws {
    let root = URL(fileURLWithPath: "/tmp/library", isDirectory: true)
    #expect(throws: (any Error).self) {
      try PathSafety.safeDestination(library: root, relativePath: "../escape")
    }
    #expect(
      try PathSafety.safeDestination(library: root, relativePath: "Docs").path
        == "/tmp/library/Docs")
  }

  /// 资料库内的符号链接指向库外时，包含关系必须按**解析后**的路径判定，
  /// 否则 `safeDestination` 会成为一条绕过资料库边界的写出路径。
  /// 此前只用 `../escape` 这类字面路径测过，从未建过真实符号链接。
  @Test func symlinkInsideLibraryCannotEscapeContainment() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let outside = root.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let link = library.appendingPathComponent("Escape", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    // 解析后落在库外 → 不属于资料库。
    #expect(!PathSafety.contains(library, link))
    #expect(!PathSafety.contains(library, outside.appendingPathComponent("payload.txt")))

    var thrown: (any Error)?
    do {
      _ = try PathSafety.safeDestination(library: library, relativePath: "Escape")
    } catch {
      thrown = error
    }
    guard case .invalidWorkspace(let message) = try #require(thrown as? OrganizerError) else {
      Issue.record("期望 invalidWorkspace，实际为 \(String(describing: thrown))")
      return
    }
    #expect(message.contains("超出资料库范围"))
  }

  /// 指向收件箱外的符号链接不能被当作收件箱直接子项——否则计划里就会出现
  /// 一个源在收件箱之外的移动操作。
  @Test func symlinkPointingOutsideInboxIsNotADirectChild() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let outside = root.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let realFile = outside.appendingPathComponent("real.txt")
    try Data("outside".utf8).write(to: realFile)
    let link = inbox.appendingPathComponent("shortcut.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)

    #expect(!PathSafety.isDirectChild(link, of: inbox))
    // 同一目录下的普通文件仍然算直接子项，证明拒绝来自符号链接解析而非路径拼写。
    let plain = inbox.appendingPathComponent("plain.txt")
    try Data("plain".utf8).write(to: plain)
    #expect(PathSafety.isDirectChild(plain, of: inbox))
  }

  /// 扫描器必须跳过真实符号链接并把它计入 skipped，而不是跟随链接读取内容。
  @Test func scannerSkipsRealSymlinkAndCountsIt() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    let realFile = inbox.appendingPathComponent("note.txt")
    try Data("hello".utf8).write(to: realFile)
    try FileManager.default.createSymbolicLink(
      at: inbox.appendingPathComponent("link.txt"), withDestinationURL: realFile)

    let volume = try PathSafety.volumeIdentifier(for: inbox)
    let workspace = Workspace(
      inboxPath: inbox.path, libraryPath: library.path,
      inboxVolumeID: volume, libraryVolumeID: volume)

    var discovered: [String] = []
    var skippedReasons: [String] = []
    for try await event in LocalInboxScanner().scan(workspace, sessionID: UUID()) {
      switch event {
      case .discovered(let item): discovered.append(item.name)
      case .skipped(_, let reason): skippedReasons.append(reason)
      case .started, .finished: break
      }
    }

    #expect(discovered == ["note.txt"])
    #expect(skippedReasons.contains("符号链接"))
    #expect(!discovered.contains("link.txt"))
  }
}

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
