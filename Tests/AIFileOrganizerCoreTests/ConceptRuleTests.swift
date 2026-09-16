import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct ConceptRuleTests {
  @Test func confirmedConceptRoutesWhileCandidateWaitsForReview() throws {
    let concept = FileConcept(name: "钢琴谱")
    let destination = UUID()
    let item = context(name: "score.pdf")
    let rule = OrganizationRule(
      workspaceID: UUID(), originalText: "钢琴谱放到 Scores",
      condition: RuleCondition(conceptID: concept.id), destinationID: destination)
    let confirmed = recognition(item: item, confirmed: [concept.id])
    let unresolved = ConceptRecognitionResult(
      itemIdentity: item.snapshot.path, status: .needsReview,
      confirmedConceptIDs: [], candidates: [ConceptCandidate(
        conceptID: concept.id, similarity: 0.9, supportingExampleIDs: [])])

    #expect(RuleEngine().evaluate(item: item, rules: [rule], recognition: confirmed)
      == .matchedMove(ruleID: rule.id, destinationID: destination))
    #expect(RuleEngine().evaluate(item: item, rules: [rule], recognition: unresolved) == .none)
  }

  @Test func childConceptRouteOverridesOnlyItsAncestor() {
    let parent = FileConcept(name: "课程讲义")
    let child = FileConcept(name: "COMP2012 讲义", parentID: parent.id)
    let item = context(name: "lecture.pdf")
    let parentRule = OrganizationRule(
      workspaceID: UUID(), originalText: "讲义放 Study",
      condition: RuleCondition(conceptID: parent.id), destinationID: UUID())
    let childDestination = UUID()
    let childRule = OrganizationRule(
      workspaceID: UUID(), originalText: "COMP2012 讲义放课程目录",
      condition: RuleCondition(conceptID: child.id), destinationID: childDestination)

    #expect(RuleEngine().evaluate(
      item: item, rules: [parentRule, childRule],
      recognition: recognition(item: item, confirmed: [parent.id, child.id]),
      concepts: [parent, child])
      == .matchedMove(ruleID: childRule.id, destinationID: childDestination))
  }

  @Test func unrelatedConceptRoutesWithDifferentTargetsStillConflict() {
    let manga = FileConcept(name: "漫画")
    let translated = FileConcept(name: "译本")
    let item = context(name: "book.pdf")
    let rules = [manga, translated].map { concept in
      OrganizationRule(
        workspaceID: UUID(), originalText: concept.name,
        condition: RuleCondition(conceptID: concept.id), destinationID: UUID())
    }

    #expect(RuleEngine().evaluate(
      item: item, rules: rules,
      recognition: recognition(item: item, confirmed: [manga.id, translated.id]),
      concepts: [manga, translated]) == .conflict(ruleIDs: rules.map(\.id)))
  }

  @Test func namingRuleCanUseConfirmedConceptWithoutSemanticGuess() throws {
    let concept = FileConcept(name: "R18 同人志")
    let item = context(name: "nhentai-42 - Example.pdf")
    let rule = NamingRule(
      workspaceID: UUID(), originalText: "同人志删除前缀",
      condition: RuleCondition(conceptID: concept.id),
      operations: [.removeNumericPrefix(prefix: "nhentai-", suffix: " - ")])

    let proposals = NamingRuleEngine().proposals(
      sessionID: item.snapshot.sessionID, contexts: [item], rules: [rule],
      recognitionByItem: [item.id: recognition(item: item, confirmed: [concept.id])])

    #expect(proposals.first?.suggestedBaseName == "Example")
    #expect(proposals.first?.disposition == .selectedByRule)
  }

  @Test func childConceptNamingRuleOverridesParent() throws {
    let parent = FileConcept(name: "漫画")
    let child = FileConcept(name: "普通漫画", parentID: parent.id)
    let item = context(name: "pre-title.pdf")
    let parentRule = NamingRule(
      workspaceID: UUID(), originalText: "漫画删除前缀",
      condition: RuleCondition(conceptID: parent.id),
      operations: [.removeLiteralPrefix("pre-")])
    let childRule = NamingRule(
      workspaceID: UUID(), originalText: "普通漫画替换前缀",
      condition: RuleCondition(conceptID: child.id),
      operations: [.replaceLiteral(target: "pre-", replacement: "new-")])
    let proposal = NamingRuleEngine().proposals(
      sessionID: item.snapshot.sessionID, contexts: [item],
      rules: [parentRule, childRule],
      recognitionByItem: [item.id: recognition(item: item, confirmed: [parent.id, child.id])],
      concepts: [parent, child]).first
    #expect(proposal?.suggestedBaseName == "new-title")
    #expect(proposal?.ruleID == childRule.id)
  }

  @Test func oldRuleConditionDecodesWithoutConceptID() throws {
    let data = Data("""
      {"itemKinds":[],"fileExtensions":["pdf"],"filenameKeywords":[],
       "contentKeywords":[],"semanticDescription":null}
      """.utf8)
    let decoded = try JSONDecoder().decode(RuleCondition.self, from: data)
    #expect(decoded.conceptID == nil)
  }

  private func context(name: String) -> ItemContext {
    ItemContext(snapshot: ItemSnapshot(
      sessionID: UUID(), path: "/tmp/\(name)", name: name,
      kind: .file, fileExtension: "pdf"), normalizedKeywords: [])
  }

  private func recognition(
    item: ItemContext, confirmed: Set<UUID>
  ) -> ConceptRecognitionResult {
    ConceptRecognitionResult(
      itemIdentity: item.snapshot.path, status: .confirmed,
      confirmedConceptIDs: confirmed, candidates: [])
  }
}
