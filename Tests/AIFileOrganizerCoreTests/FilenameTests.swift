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

  @Test func namingRuleProducesSelectedRenameWhenFieldsAreAvailable() throws {
    let sessionID = UUID()
    let item = ItemSnapshot(
      sessionID: sessionID, path: "/tmp/source.pdf", name: "source.pdf", kind: .file,
      fileExtension: "pdf")
    let context = ItemContext(
      snapshot: item,
      normalizedKeywords: [],
      spotlightTitle: "Moonlight Sonata",
      spotlightAuthors: ["Beethoven"]
    )
    let rule = NamingRule(
      workspaceID: UUID(),
      originalText: "PDF 命名为作者-标题",
      condition: RuleCondition(fileExtensions: ["pdf"]),
      template: FilenameTemplate(pattern: "{作者} - {标题}")
    )

    let proposals = NamingRuleEngine().proposals(
      sessionID: sessionID, contexts: [context], rules: [rule])

    let proposal = try #require(proposals.first)
    #expect(proposal.suggestedBaseName == "Beethoven - Moonlight Sonata")
    #expect(proposal.disposition == .selectedByRule)
    #expect(proposal.missingFields.isEmpty)
  }

  @Test func namingRuleKeepsOriginalNameWhenARequiredFieldIsMissing() throws {
    let sessionID = UUID()
    let item = ItemSnapshot(
      sessionID: sessionID, path: "/tmp/source.pdf", name: "source.pdf", kind: .file,
      fileExtension: "pdf")
    let rule = NamingRule(
      workspaceID: UUID(),
      originalText: "PDF 命名为作者-标题",
      condition: RuleCondition(fileExtensions: ["pdf"]),
      template: FilenameTemplate(pattern: "{作者} - {标题}")
    )

    let proposals = NamingRuleEngine().proposals(
      sessionID: sessionID,
      contexts: [ItemContext(snapshot: item, normalizedKeywords: [], spotlightTitle: "Report")],
      rules: [rule]
    )

    let proposal = try #require(proposals.first)
    #expect(proposal.suggestedBaseName == "source")
    #expect(proposal.disposition == .blocked)
    #expect(proposal.missingFields == [.author])
  }

  @Test func conflictingNamingRulesBlockRenameWithoutChoosingEitherName() throws {
    let sessionID = UUID()
    let item = ItemSnapshot(
      sessionID: sessionID, path: "/tmp/source.pdf", name: "source.pdf", kind: .file,
      fileExtension: "pdf")
    let first = NamingRule(
      workspaceID: UUID(), originalText: "A", condition: RuleCondition(fileExtensions: ["pdf"]),
      template: FilenameTemplate(pattern: "A - {原标题}"))
    let second = NamingRule(
      workspaceID: first.workspaceID, originalText: "B",
      condition: RuleCondition(fileExtensions: ["pdf"]),
      template: FilenameTemplate(pattern: "B - {原标题}"))

    let proposal = try #require(NamingRuleEngine().proposals(
      sessionID: sessionID,
      contexts: [ItemContext(snapshot: item, normalizedKeywords: [])],
      rules: [first, second]
    ).first)

    #expect(proposal.disposition == .blocked)
    #expect(proposal.suggestedBaseName == "source")
    #expect(proposal.reason.contains("多个命名规则"))
  }

  @Test func fallbackNamingInterpreterExtractsEditableTemplate() async throws {
    let drafts = try await AppleRuleInterpreter().interpretNaming(
      text: "PDF 乐谱命名为 {作者} - {标题}")

    let draft = try #require(drafts.first)
    #expect(draft.condition.fileExtensions == ["pdf"])
    #expect(draft.template.pattern == "{作者} - {标题}")
  }
}
