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
}

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
