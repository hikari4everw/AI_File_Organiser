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
    for try await event in LocalInboxScanner().scan(workspace, sessionID: UUID()) {
      if case .discovered(let item) = event { items.append(item) }
    }
    #expect(Set(items.map(\.name)) == ["note.txt", "Folder"])
    #expect(items.first(where: { $0.name == "Folder" })?.kind == .directory)
  }
}
