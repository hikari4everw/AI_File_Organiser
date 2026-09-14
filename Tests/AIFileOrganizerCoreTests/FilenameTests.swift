import Foundation
import Testing

@testable import AIFileOrganizerCore

private struct FilenameTestExtractor: ContentExtractor {
  let text: String
  func extractContext(for item: ItemSnapshot) async -> ExtractedContext {
    ExtractedContext(text: text, source: "test", status: .success)
  }
}

private struct FilenameTestProvider: FilenameSuggestionProvider {
  var availabilityDescription: String { available ? "available" : "unavailable" }
  let available: Bool
  let suggestions: [ModelFilenameSuggestion]
  var isAvailable: Bool { available }

  func suggestNames(requests: [FilenameSuggestionRequest]) async throws
    -> [ModelFilenameSuggestion]
  {
    suggestions
  }
}

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

  @Test func validatorRejectsCandidateThatInjectsLockedExtension() {
    let item = ItemSnapshot(
      sessionID: UUID(), path: "/tmp/source.pdf", name: "source.pdf", kind: .file,
      fileExtension: "pdf")

    #expect(throws: OrganizerError.self) {
      try FilenameValidator().validatedFullName(baseName: "renamed.pdf", item: item)
    }
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

  @Test(arguments: [
    "550e8400-e29b-41d4-a716-446655440000.pdf",
    "8f14e45fceea167a5a36dedd4bea2543.pdf",
    "%E6%9C%88%E5%85%89.pdf",
    "bad\u{FFFD}name.pdf",
  ])
  func qualityDetectorFlagsOnlyClearUnreadablePatterns(_ name: String) {
    #expect(FilenameQualityDetector().requiresSuggestion(name: name))
  }

  @Test(arguments: ["report-2026.pdf", "IMG_1234.jpg", "Moonlight Sonata.pdf"])
  func qualityDetectorKeepsReadableNames(_ name: String) {
    #expect(!FilenameQualityDetector().requiresSuggestion(name: name))
  }

  @Test func aiSuggestionIsPendingAndUsesExtractedContent() async throws {
    let sessionID = UUID()
    let item = ItemSnapshot(
      sessionID: sessionID,
      path: "/tmp/550e8400-e29b-41d4-a716-446655440000.pdf",
      name: "550e8400-e29b-41d4-a716-446655440000.pdf",
      kind: .file,
      fileExtension: "pdf")
    let suggestion = ModelFilenameSuggestion(
      itemID: item.id,
      suggestedBaseName: "Moonlight Sonata",
      fields: [.title: "Moonlight Sonata"],
      reason: "PDF 首页标题")

    let result = await FilenameSuggestionPipeline(
      extractor: FilenameTestExtractor(text: "Moonlight Sonata"),
      provider: FilenameTestProvider(available: true, suggestions: [suggestion])
    ).run(sessionID: sessionID, items: [item])

    let proposal = try #require(result.proposals.first)
    #expect(proposal.suggestedBaseName == "Moonlight Sonata")
    #expect(proposal.disposition == .pending)
    #expect(proposal.source == .foundationModel)
    #expect(result.contextsByItem[item.id]?.extracted.text == "Moonlight Sonata")
  }

  @Test func unavailableModelDoesNotCreateFakeRenameSuggestion() async {
    let sessionID = UUID()
    let item = ItemSnapshot(
      sessionID: sessionID, path: "/tmp/8f14e45fceea167a5a36dedd4bea2543.pdf",
      name: "8f14e45fceea167a5a36dedd4bea2543.pdf", kind: .file, fileExtension: "pdf")

    let result = await FilenameSuggestionPipeline(
      extractor: FilenameTestExtractor(text: "Report"),
      provider: FilenameTestProvider(available: false, suggestions: [])
    ).run(sessionID: sessionID, items: [item])

    #expect(result.proposals.isEmpty)
    #expect(result.modelStatus == "unavailable")
  }

  @Test func manualRequestCanSuggestRenameForReadableName() async throws {
    let sessionID = UUID()
    let item = ItemSnapshot(
      sessionID: sessionID, path: "/tmp/report.pdf", name: "report.pdf", kind: .file,
      fileExtension: "pdf")
    let suggestion = ModelFilenameSuggestion(
      itemID: item.id, suggestedBaseName: "Annual Report 2026", reason: "document title")

    let result = await FilenameSuggestionPipeline(
      extractor: FilenameTestExtractor(text: "Annual Report 2026"),
      provider: FilenameTestProvider(available: true, suggestions: [suggestion])
    ).run(sessionID: sessionID, items: [item], requestedItemIDs: [item.id])

    #expect(try #require(result.proposals.first).suggestedBaseName == "Annual Report 2026")
  }

  @Test func pipelineKeepsConflictingNamingRulesBlockedEvenWhenModelSuggestsName() async throws {
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
    let model = ModelFilenameSuggestion(
      itemID: item.id, suggestedBaseName: "Model Override", reason: "model")

    let result = await FilenameSuggestionPipeline(
      extractor: FilenameTestExtractor(text: "Model Override"),
      provider: FilenameTestProvider(available: true, suggestions: [model])
    ).run(sessionID: sessionID, items: [item], namingRules: [first, second])

    let proposal = try #require(result.proposals.first)
    #expect(proposal.disposition == .blocked)
    #expect(proposal.reason.contains("多个命名规则"))
  }

  @Test func modelDateCannotFillRuleWithoutDeterministicDateEvidence() async throws {
    let sessionID = UUID()
    let item = ItemSnapshot(
      sessionID: sessionID, path: "/tmp/source.pdf", name: "source.pdf", kind: .file,
      fileExtension: "pdf", creationDate: nil)
    let rule = NamingRule(
      workspaceID: UUID(), originalText: "date", condition: RuleCondition(fileExtensions: ["pdf"]),
      template: FilenameTemplate(pattern: "{日期} - {原标题}"))
    let model = ModelFilenameSuggestion(
      itemID: item.id, suggestedBaseName: "2026-09-14 - source",
      fields: [.date: "2026-09-14"], reason: "model")

    let result = await FilenameSuggestionPipeline(
      extractor: FilenameTestExtractor(text: ""),
      provider: FilenameTestProvider(available: true, suggestions: [model])
    ).run(sessionID: sessionID, items: [item], namingRules: [rule])

    let proposal = try #require(result.proposals.first)
    #expect(proposal.disposition == .blocked)
    #expect(proposal.missingFields == [.date])
  }

  @Test func evidenceBackedAISuggestionCarriesLearnableTemplate() async throws {
    let sessionID = UUID()
    let item = ItemSnapshot(
      sessionID: sessionID, path: "/tmp/8f14e45fceea167a5a36dedd4bea2543.pdf",
      name: "8f14e45fceea167a5a36dedd4bea2543.pdf", kind: .file,
      fileExtension: "pdf")
    let model = ModelFilenameSuggestion(
      itemID: item.id, suggestedBaseName: "Beethoven - Moonlight Sonata",
      fields: [.author: "Beethoven", .title: "Moonlight Sonata"], reason: "model")

    let result = await FilenameSuggestionPipeline(
      extractor: FilenameTestExtractor(text: "Beethoven Moonlight Sonata"),
      provider: FilenameTestProvider(available: true, suggestions: [model])
    ).run(sessionID: sessionID, items: [item])

    #expect(try #require(result.proposals.first).templatePattern == "{作者} - {标题}")
  }

  @Test func acceptedAISuggestionCarriesTemplateIntoPlanLearningFeatures() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let inbox = root.appendingPathComponent("Inbox")
    let library = root.appendingPathComponent("Library")
    let docs = library.appendingPathComponent("Docs")
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let source = inbox.appendingPathComponent("8f14e45fceea167a5a36dedd4bea2543.pdf")
    try Data("Beethoven Moonlight Sonata".utf8).write(to: source)
    let item = ItemSnapshot(
      sessionID: sessionID, path: source.path, name: source.lastPathComponent,
      kind: .file, fileExtension: "pdf")
    let output = ModelFilenameSuggestion(
      itemID: item.id, suggestedBaseName: "Beethoven - Moonlight Sonata",
      fields: [.author: "Beethoven", .title: "Moonlight Sonata"], reason: "model")
    let result = await FilenameSuggestionPipeline(
      extractor: FilenameTestExtractor(text: "Beethoven Moonlight Sonata"),
      provider: FilenameTestProvider(available: true, suggestions: [output])
    ).run(sessionID: sessionID, items: [item])
    var rename = try #require(result.proposals.first)
    rename.disposition = .approved
    let destination = DestinationProfile(relativePath: "Docs", displayName: "Docs")
    let move = ClassificationProposal(
      sessionID: sessionID, itemID: item.id, action: .move,
      destinationID: destination.id, source: .user, reviewDecision: .ready,
      status: .approved, reason: "user")
    let workspace = Workspace(
      inboxPath: inbox.path, libraryPath: library.path,
      inboxVolumeID: "volume", libraryVolumeID: "volume")

    let plan = try PlanBuilder().build(
      sessionID: sessionID, workspace: workspace, items: [item],
      destinations: [destination], proposals: [move], folderProposals: [],
      renameProposals: [rename])

    #expect(plan.operations.first?.namingDecisionFeatures?.templatePattern == "{作者} - {标题}")
    #expect(plan.operations.first?.namingSampleSource == .acceptedSuggestion)
  }
}
