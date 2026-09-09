import Foundation
import Testing

@testable import AIFileOrganizerCore

private struct RuleEmptyExtractor: ContentExtractor {
  func extractContext(for item: ItemSnapshot) async -> ExtractedContext { .init() }
}

private struct RuleUnavailableProvider: ClassificationProvider {
  var availabilityDescription: String { "不可用" }
  var isAvailable: Bool { false }
  func classify(items: [ItemContext], destinations: [DestinationProfile]) async throws
    -> [ModelProposal] { [] }
}

@Suite struct RuleTests {
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

    #expect(result == .matched(ruleID: rule.id, destinationID: destinationID))
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
