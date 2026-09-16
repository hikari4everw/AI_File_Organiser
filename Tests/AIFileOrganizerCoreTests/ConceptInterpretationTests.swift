import Foundation
import Testing

@testable import AIFileOrganizerCore

private struct FailingConceptInterpreter: RuleInterpreter, NamingRuleInterpreting {
  func interpret(text: String, destinations: [DestinationProfile]) async throws -> [RuleDraft] {
    throw OrganizerError.invalidModelOutput("不应调用模型")
  }

  func interpretNaming(text: String) async throws -> [NamingRuleDraft] {
    throw OrganizerError.invalidModelOutput("不应调用模型")
  }
}

private struct CompoundConceptInterpreter: RuleInterpreter, NamingRuleInterpreting {
  func interpret(text: String, destinations: [DestinationProfile]) async throws -> [RuleDraft] {
    throw OrganizerError.invalidModelOutput("整理路径不应调用模型")
  }

  func interpretNaming(text: String) async throws -> [NamingRuleDraft] {
    [NamingRuleDraft(
      originalText: text, condition: RuleCondition(),
      operations: [.removeLiteralPrefix("draft_")])]
  }
}

@Suite struct ConceptInterpretationTests {
  @Test func compoundSentenceKeepsNamingDraft() async throws {
    let concept = FileConcept(name: "课件")
    let destination = DestinationProfile(
      relativePath: "Study", displayName: "Study", keywords: [], depth: 1)
    let result = try await RuleInterpretationEngine().interpret(
      text: "课件放到 Study，并改名为课程标题", destinations: [destination],
      concepts: [concept], interpreter: CompoundConceptInterpreter())
    #expect(result.organizationDrafts.first?.condition.conceptID == concept.id)
    #expect(result.namingDrafts.count == 1)
  }

  @Test func knownConceptAndDestinationBypassModel() async throws {
    let concept = FileConcept(name: "课程讲义", aliases: ["课件"])
    let destination = DestinationProfile(
      relativePath: "Study Materials", displayName: "Study Materials", keywords: [], depth: 1)
    let result = try await RuleInterpretationEngine().interpret(
      text: "所有课件都放到 Study Materials", destinations: [destination],
      concepts: [concept], interpreter: FailingConceptInterpreter())

    #expect(result.organizationDrafts.count == 1)
    #expect(result.organizationDrafts.first?.condition.conceptID == concept.id)
    #expect(result.organizationDrafts.first?.destinationID == destination.id)
    #expect(result.organizationDrafts.first?.condition.semanticDescription == nil)
    #expect(result.namingDrafts.isEmpty)
  }

  @Test func ambiguousConceptAliasRemainsEditable() async throws {
    let first = FileConcept(name: "讲义", aliases: ["课件"])
    let second = FileConcept(name: "幻灯片", aliases: ["课件"])
    let destination = DestinationProfile(
      relativePath: "Study", displayName: "Study", keywords: [], depth: 1)
    let result = try await RuleInterpretationEngine().interpret(
      text: "课件放到 Study", destinations: [destination], concepts: [first, second],
      interpreter: FailingConceptInterpreter())

    #expect(result.organizationDrafts.first?.condition.conceptID == nil)
    #expect(result.organizationDrafts.first?.destinationID == destination.id)
    #expect(result.warnings.contains { $0.contains("多个概念") })
  }

  @Test func unknownDestinationDoesNotBecomeExecutable() async throws {
    let concept = FileConcept(name: "发票")
    let result = try await RuleInterpretationEngine().interpret(
      text: "所有发票都放到 Tax/2026", destinations: [], concepts: [concept],
      interpreter: FailingConceptInterpreter())

    #expect(result.organizationDrafts.first?.condition.conceptID == concept.id)
    #expect(result.organizationDrafts.first?.destinationID == nil)
    #expect(result.warnings.contains { $0.contains("目标目录") })
  }
}
