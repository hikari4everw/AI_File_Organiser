import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct ScannerTests {
  @Test func scansOnlyDirectChildrenAndSkipsHiddenAndSymlink() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: inbox.appendingPathComponent("note.txt"))
    try Data().write(to: inbox.appendingPathComponent(".hidden"))
    let folder = inbox.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data().write(to: folder.appendingPathComponent("nested.pdf"))
    try FileManager.default.createSymbolicLink(
      at: inbox.appendingPathComponent("link"),
      withDestinationURL: inbox.appendingPathComponent("note.txt")
    )
    let volume = try PathSafety.volumeIdentifier(for: inbox)
    let workspace = Workspace(
      inboxPath: inbox.path, libraryPath: library.path,
      inboxVolumeID: volume, libraryVolumeID: volume
    )
    var items: [ItemSnapshot] = []
    var total: Int?
    var processed = 0
    var skipped = 0
    for try await event in LocalInboxScanner().scan(workspace, sessionID: UUID()) {
      switch event {
      case .started(let value):
        total = value
      case .discovered(let item):
        items.append(item)
        processed += 1
      case .skipped:
        skipped += 1
        processed += 1
      case .finished:
        break
      }
    }
    #expect(Set(items.map(\.name)) == ["note.txt", "Folder"])
    #expect(items.first(where: { $0.name == "Folder" })?.kind == .directory)
    #expect(total == processed)
    #expect(skipped == 1)
  }

  @Test func scansThousandItemsWithAccurateIncrementalCount() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    for index in 0..<1_000 {
      try Data().write(to: inbox.appendingPathComponent("item-\(index).txt"))
    }
    let volume = try PathSafety.volumeIdentifier(for: inbox)
    let workspace = Workspace(
      inboxPath: inbox.path,
      libraryPath: library.path,
      inboxVolumeID: volume,
      libraryVolumeID: volume
    )
    var total: Int?
    var completed = 0

    for try await event in LocalInboxScanner().scan(workspace, sessionID: UUID()) {
      switch event {
      case .started(let value): total = value
      case .discovered, .skipped: completed += 1
      case .finished: break
      }
    }

    #expect(total == 1_000)
    #expect(completed == total)
  }
}
