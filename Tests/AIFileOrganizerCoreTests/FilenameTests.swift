import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct FilenameTests {
  @Test func templateRendersKnownFieldsAndReportsMissingOnes() throws {
    let result = try FilenameTemplateEngine().render(
      template: FilenameTemplate(pattern: "{作者} - {标题} - {日期}"),
      fields: [.author: "Beethoven", .title: "Moonlight Sonata"]
    )

    #expect(result.value == "Beethoven - Moonlight Sonata - {日期}")
    #expect(result.missingFields == [.date])
  }

  @Test func templateRejectsUnknownAndUnclosedPlaceholders() {
    #expect(throws: OrganizerError.self) {
      try FilenameTemplateEngine().validate(FilenameTemplate(pattern: "{作曲家} - {标题}"))
    }
    #expect(throws: OrganizerError.self) {
      try FilenameTemplateEngine().validate(FilenameTemplate(pattern: "{标题"))
    }
    #expect(throws: OrganizerError.self) {
      try FilenameTemplateEngine().validate(FilenameTemplate(pattern: "   "))
    }
  }

  @Test func validatorPreservesFileExtensionAndNormalizesName() throws {
    let item = ItemSnapshot(
      sessionID: UUID(), path: "/tmp/source.PDF", name: "source.PDF", kind: .file,
      fileExtension: "PDF")

    let result = try FilenameValidator().validatedFullName(
      baseName: "  Cafe\u{301} / Notes.pdf  ".replacingOccurrences(of: " / Notes.pdf", with: ""),
      item: item
    )

    #expect(result == "Café.PDF")
  }

  @Test func validatorTreatsDirectoryNameAsCompleteName() throws {
    let item = ItemSnapshot(
      sessionID: UUID(), path: "/tmp/Comic.old", name: "Comic.old", kind: .directory)

    #expect(
      try FilenameValidator().validatedFullName(baseName: "Moonlight Comic", item: item)
        == "Moonlight Comic")
  }

  @Test(arguments: ["", ".", "..", ".hidden", "a/b", "a:b", "bad\u{0}name"])
  func validatorRejectsUnsafeNames(_ candidate: String) {
    let item = ItemSnapshot(
      sessionID: UUID(), path: "/tmp/source.txt", name: "source.txt", kind: .file,
      fileExtension: "txt")

    #expect(throws: OrganizerError.self) {
      try FilenameValidator().validatedFullName(baseName: candidate, item: item)
    }
  }

  @Test func validatorRejectsNamesLongerThanSafetyBudget() {
    let item = ItemSnapshot(
      sessionID: UUID(), path: "/tmp/source.txt", name: "source.txt", kind: .file,
      fileExtension: "txt")

    #expect(throws: OrganizerError.self) {
      try FilenameValidator().validatedFullName(baseName: String(repeating: "乐", count: 80), item: item)
    }
  }

  @Test func validatorRejectsApplicationBundles() {
    let item = ItemSnapshot(
      sessionID: UUID(), path: "/tmp/Example.app", name: "Example.app", kind: .applicationBundle,
      fileExtension: "app")

    #expect(throws: OrganizerError.self) {
      try FilenameValidator().validatedFullName(baseName: "Renamed", item: item)
    }
  }
}
