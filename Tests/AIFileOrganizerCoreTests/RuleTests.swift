import Foundation
import Testing

@testable import AIFileOrganizerCore

#if canImport(FoundationModels)
  import FoundationModels
#endif

private struct RuleEmptyExtractor: ContentExtractor {
  func extractContext(for item: ItemSnapshot) async -> ExtractedContext { .init() }
}

private struct RuleUnavailableProvider: ClassificationProvider {
  var availabilityDescription: String { "不可用" }
  var isAvailable: Bool { false }
  func classify(items: [ItemContext], destinations: [DestinationProfile]) async throws
    -> [ModelProposal] { [] }
}

private struct LegacyOrganizationRule: Encodable {
  var id: UUID
  var workspaceID: UUID
  var originalText: String
  var condition: RuleCondition
  var destinationID: UUID
  var isEnabled: Bool
  var isDerived: Bool
  var createdAt: Date
}

@Suite struct RuleTests {
  @Test func unextractedArchiveKeepTextProducesDeterministicDraft() async throws {
    let drafts = try await AppleRuleInterpreter().interpret(
      text: "未解压文件不用移动",
      destinations: []
    )

    let draft = try #require(drafts.first)
    #expect(draft.action == .keep)
    #expect(draft.destinationID == nil)
    #expect(draft.condition.itemKinds == [.file])
    #expect(draft.condition.fileExtensions == ["zip", "7z", "rar", "tar", "gz"])
  }

#if canImport(FoundationModels)
  @Test func guardrailViolationUsesLocalizedRuleError() throws {
    let error = LanguageModelSession.GenerationError.guardrailViolation(
      .init(debugDescription: "Detected content likely to be unsafe"))

    let localized = try #require(AppleRuleInterpreter.localizedGenerationError(error))

    #expect(localized.localizedDescription == "本地 AI 无法处理这条规则描述，请改写后重试")
  }
#endif

  @Test func keepRuleMatchesArchivesButNotOtherFiles() {
    let rule = OrganizationRule(
      workspaceID: UUID(),
      originalText: "未解压文件不用移动",
      action: .keep,
      condition: RuleCondition(fileExtensions: ["zip", "7z", "rar", "tar", "gz"])
    )
    let archive = ItemContext(
      snapshot: ItemSnapshot(
        sessionID: UUID(), path: "/tmp/archive.zip", name: "archive.zip", kind: .file,
        fileExtension: "zip"),
      normalizedKeywords: []
    )
    let document = ItemContext(
      snapshot: ItemSnapshot(
        sessionID: UUID(), path: "/tmp/report.pdf", name: "report.pdf", kind: .file,
        fileExtension: "pdf"),
      normalizedKeywords: []
    )

    #expect(RuleEngine().evaluate(item: archive, rules: [rule]) == .matchedKeep(ruleID: rule.id))
    #expect(RuleEngine().evaluate(item: document, rules: [rule]) == .none)
  }

  @Test func multipleKeepRulesDoNotConflict() {
    let workspaceID = UUID()
    let first = OrganizationRule(
      workspaceID: workspaceID,
      originalText: "压缩包保留原处",
      action: .keep,
      condition: RuleCondition(fileExtensions: ["zip"])
    )
    let second = OrganizationRule(
      workspaceID: workspaceID,
      originalText: "备份文件不移动",
      action: .keep,
      condition: RuleCondition(filenameKeywords: ["backup"])
    )
    let item = ItemContext(
      snapshot: ItemSnapshot(
        sessionID: UUID(), path: "/tmp/backup.zip", name: "backup.zip", kind: .file,
        fileExtension: "zip"),
      normalizedKeywords: []
    )

    #expect(
      RuleEngine().evaluate(item: item, rules: [first, second]) == .matchedKeep(ruleID: first.id))
  }

  @Test func keepAndMoveRulesRequireReview() {
    let workspaceID = UUID()
    let keep = OrganizationRule(
      workspaceID: workspaceID,
      originalText: "压缩包不移动",
      action: .keep,
      condition: RuleCondition(fileExtensions: ["zip"])
    )
    let move = OrganizationRule(
      workspaceID: workspaceID,
      originalText: "ZIP 放归档",
      condition: RuleCondition(fileExtensions: ["zip"]),
      destinationID: UUID()
    )
    let item = ItemContext(
      snapshot: ItemSnapshot(
        sessionID: UUID(), path: "/tmp/archive.zip", name: "archive.zip", kind: .file,
        fileExtension: "zip"),
      normalizedKeywords: []
    )

    #expect(
      RuleEngine().evaluate(item: item, rules: [keep, move])
        == .conflict(ruleIDs: [keep.id, move.id]))
  }

  @Test func keepRuleProducesAutomaticKeepProposal() async {
    let session = UUID()
    let item = ItemSnapshot(
      sessionID: session, path: "/tmp/archive.rar", name: "archive.rar", kind: .file,
      fileExtension: "rar")
    let rule = OrganizationRule(
      workspaceID: UUID(),
      originalText: "未解压文件不用移动",
      action: .keep,
      condition: RuleCondition(fileExtensions: ["rar"])
    )

    let result = await ClassificationPipeline(
      extractor: RuleEmptyExtractor(), provider: RuleUnavailableProvider()
    ).run(sessionID: session, items: [item], destinations: [], rules: [rule])

    #expect(result.proposals.count == 1)
    let proposal = result.proposals[0]
    #expect(proposal.action == .keep)
    #expect(proposal.destinationID == nil)
    #expect(proposal.source == .user)
    #expect(proposal.reviewDecision == .keep)
  }

  @Test func keepRulesPersistWithoutDestination() throws {
    let database = try AppDatabase.inMemory()
    let workspaceID = UUID()
    let rule = OrganizationRule(
      workspaceID: workspaceID,
      originalText: "未解压文件不用移动",
      action: .keep,
      condition: RuleCondition(fileExtensions: ["zip"])
    )

    try database.saveRule(rule)

    let loaded = try #require(database.rules(workspaceID: workspaceID).first)
    #expect(loaded.action == .keep)
    #expect(loaded.destinationID == nil)
  }

  @Test func legacyRulePayloadDefaultsToMove() throws {
    let destinationID = UUID()
    let legacy = LegacyOrganizationRule(
      id: UUID(),
      workspaceID: UUID(),
      originalText: "PDF 放文档",
      condition: RuleCondition(fileExtensions: ["pdf"]),
      destinationID: destinationID,
      isEnabled: true,
      isDerived: false,
      createdAt: Date(timeIntervalSinceReferenceDate: 123)
    )

    let data = try JSONEncoder().encode(legacy)
    let decoded = try JSONDecoder().decode(OrganizationRule.self, from: data)

    #expect(decoded.action == .move)
    #expect(decoded.destinationID == destinationID)
  }

  @Test func explicitRuleMatchesAllConditionGroups() {
    let workspaceID = UUID()
    let destinationID = UUID()
    let item = ItemContext(
      snapshot: ItemSnapshot(
        sessionID: UUID(),
        path: "/tmp/moonlight-score.pdf",
        name: "Moonlight Piano Score.pdf",
        kind: .file,
        contentType: "com.adobe.pdf",
        fileExtension: "pdf"
      ),
      normalizedKeywords: ["moonlight", "piano", "score"],
      extracted: ExtractedContext(text: "Piano Sonata No. 14", source: "pdf")
    )
    let rule = OrganizationRule(
      workspaceID: workspaceID,
      originalText: "钢琴乐谱放到钢琴目录",
      condition: RuleCondition(
        itemKinds: [.file],
        fileExtensions: ["pdf"],
        filenameKeywords: ["score", "乐谱"]
      ),
      destinationID: destinationID
    )

    let result = RuleEngine().evaluate(item: item, rules: [rule])

    #expect(result == .matchedMove(ruleID: rule.id, destinationID: destinationID))
  }

  @Test func rulesForDifferentDestinationsProduceReviewConflict() {
    let workspaceID = UUID()
    let item = ItemContext(
      snapshot: ItemSnapshot(
        sessionID: UUID(), path: "/tmp/chapter.pdf", name: "chapter.pdf", kind: .file,
        fileExtension: "pdf"),
      normalizedKeywords: ["chapter"]
    )
    let first = OrganizationRule(
      workspaceID: workspaceID,
      originalText: "PDF 放文档",
      condition: RuleCondition(fileExtensions: ["pdf"]),
      destinationID: UUID()
    )
    let second = OrganizationRule(
      workspaceID: workspaceID,
      originalText: "章节放漫画",
      condition: RuleCondition(filenameKeywords: ["chapter"]),
      destinationID: UUID()
    )

    let result = RuleEngine().evaluate(item: item, rules: [first, second])

    #expect(result == .conflict(ruleIDs: [first.id, second.id]))
  }

  @Test func semanticOnlyRuleRequiresModelReview() {
    let rule = OrganizationRule(
      workspaceID: UUID(),
      originalText: "漫画放漫画库",
      condition: RuleCondition(semanticDescription: "漫画作品"),
      destinationID: UUID()
    )
    let item = ItemContext(
      snapshot: ItemSnapshot(
        sessionID: UUID(), path: "/tmp/unknown", name: "unknown", kind: .directory),
      normalizedKeywords: []
    )

    #expect(RuleEngine().evaluate(item: item, rules: [rule]) == .semanticCandidates([rule.id]))
  }

  @Test func rulesPersistAndCanBeDisabled() throws {
    let database = try AppDatabase.inMemory()
    let workspaceID = UUID()
    let rule = OrganizationRule(
      workspaceID: workspaceID,
      originalText: "PDF 放到文档",
      condition: RuleCondition(fileExtensions: ["pdf"]),
      destinationID: UUID()
    )
    try database.saveRule(rule)
    let loaded = try #require(database.rules(workspaceID: workspaceID).first)
    #expect(loaded.id == rule.id)
    #expect(loaded.condition == rule.condition)
    #expect(loaded.destinationID == rule.destinationID)

    var disabled = rule
    disabled.isEnabled = false
    try database.saveRule(disabled)
    #expect(try database.rules(workspaceID: workspaceID).first?.isEnabled == false)
    try database.deleteRule(rule.id)
    #expect(try database.rules(workspaceID: workspaceID).isEmpty)
  }

  @Test func matchingRuleOverridesHeuristicsAndConflictRequiresReview() async {
    let session = UUID()
    let workspaceID = UUID()
    let pdf = ItemSnapshot(
      sessionID: session, path: "/tmp/score.pdf", name: "score.pdf", kind: .file,
      fileExtension: "pdf")
    let scores = DestinationProfile(relativePath: "Music/Scores", displayName: "Scores")
    let papers = DestinationProfile(relativePath: "Research/Papers", displayName: "Papers")
    let scoreRule = OrganizationRule(
      workspaceID: workspaceID,
      originalText: "PDF 乐谱放 Scores",
      condition: RuleCondition(fileExtensions: ["pdf"]),
      destinationID: scores.id
    )
    let pipeline = ClassificationPipeline(
      extractor: RuleEmptyExtractor(), provider: RuleUnavailableProvider())
    let matched = await pipeline.run(
      sessionID: session, items: [pdf], destinations: [scores, papers], rules: [scoreRule])
    #expect(matched.proposals.first?.destinationID == scores.id)
    #expect(matched.proposals.first?.source == .user)
    #expect(matched.proposals.first?.reviewDecision == .ready)

    let conflictRule = OrganizationRule(
      workspaceID: workspaceID,
      originalText: "PDF 放 Papers",
      condition: RuleCondition(fileExtensions: ["pdf"]),
      destinationID: papers.id
    )
    let conflicted = await pipeline.run(
      sessionID: session, items: [pdf], destinations: [scores, papers],
      rules: [scoreRule, conflictRule])
    #expect(conflicted.proposals.first?.reviewDecision == .needsReview)
    #expect(conflicted.proposals.first?.destinationID == nil)
  }
}
