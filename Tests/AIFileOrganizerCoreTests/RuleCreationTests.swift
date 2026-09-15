import Foundation
import Testing

@testable import AIFileOrganizerCore

private enum InterpretationTestError: LocalizedError, Sendable {
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .failed(let message): message
    }
  }
}

private enum InterpretationTestOutput<Value: Sendable>: Sendable {
  case drafts([Value])
  case failure(String)
}

private struct TestRuleInterpreter: RuleInterpreter, NamingRuleInterpreting {
  let organization: InterpretationTestOutput<RuleDraft>
  let naming: InterpretationTestOutput<NamingRuleDraft>

  func interpret(text: String, destinations: [DestinationProfile]) async throws -> [RuleDraft] {
    switch organization {
    case .drafts(let drafts): drafts
    case .failure(let message): throw InterpretationTestError.failed(message)
    }
  }

  func interpretNaming(text: String) async throws -> [NamingRuleDraft] {
    switch naming {
    case .drafts(let drafts): drafts
    case .failure(let message): throw InterpretationTestError.failed(message)
    }
  }
}

@Suite struct RuleCreationTests {
  @Test func namingDraftSurvivesOrganizationInterpretationFailure() async throws {
    let namingDraft = NamingRuleDraft(
      originalText: "删除前缀",
      condition: RuleCondition(filenameKeywords: ["draft_"]),
      operations: [.removeLiteralPrefix("draft_")])
    let interpreter = TestRuleInterpreter(
      organization: .failure("整理模型失败"),
      naming: .drafts([namingDraft]))

    let result = try await RuleInterpretationEngine().interpret(
      text: namingDraft.originalText,
      destinations: [],
      interpreter: interpreter)

    #expect(result.organizationDrafts.isEmpty)
    #expect(result.namingDrafts == [namingDraft])
    #expect(result.warnings.contains(where: { $0.contains("整理模型失败") }))
  }

  @Test func namingDraftSurvivesEmptyOrganizationInterpretation() async throws {
    let namingDraft = NamingRuleDraft(
      originalText: "删除前缀",
      condition: RuleCondition(filenameKeywords: ["draft_"]),
      operations: [.removeLiteralPrefix("draft_")])
    let interpreter = TestRuleInterpreter(
      organization: .drafts([]),
      naming: .drafts([namingDraft]))

    let result = try await RuleInterpretationEngine().interpret(
      text: namingDraft.originalText,
      destinations: [],
      interpreter: interpreter)

    #expect(result.namingDrafts == [namingDraft])
    #expect(result.warnings.contains(where: { $0.contains("未生成整理规则") }))
  }

  @Test func organizationDraftSurvivesNamingInterpretationFailure() async throws {
    let organizationDraft = RuleDraft(
      originalText: "PDF 保留原处",
      action: .keep,
      condition: RuleCondition(fileExtensions: ["pdf"]))
    let interpreter = TestRuleInterpreter(
      organization: .drafts([organizationDraft]),
      naming: .failure("命名模型失败"))

    let result = try await RuleInterpretationEngine().interpret(
      text: organizationDraft.originalText,
      destinations: [],
      interpreter: interpreter)

    #expect(result.organizationDrafts == [organizationDraft])
    #expect(result.namingDrafts.isEmpty)
    #expect(result.warnings.contains(where: { $0.contains("命名模型失败") }))
  }

  @Test func interpretationThrowsOnlyWhenNeitherPathProducesDraft() async {
    let interpreter = TestRuleInterpreter(
      organization: .failure("整理模型失败"),
      naming: .drafts([]))

    await #expect(throws: OrganizerError.self) {
      _ = try await RuleInterpretationEngine().interpret(
        text: "无法识别",
        destinations: [],
        interpreter: interpreter)
    }
  }

  @Test func exactUserExampleProducesExtensionPreservingUnverifiedPreview() throws {
    let original = "nhentai-651786 - 月光.pdf"
    let evaluation = NamingRuleExampleEvaluator().evaluate(
      operations: [.removeNumericPrefix(prefix: "nhentai-", suffix: " - ")],
      condition: RuleCondition(
        filenameKeywords: ["nhentai-"],
        semanticDescription: "同人志"),
      originalName: original,
      expectedName: "月光.pdf")

    let preview = try #require(evaluation.preview)
    #expect(preview.originalName == original)
    #expect(preview.suggestedName == "月光.pdf")
    #expect(preview.isSemanticConditionUnverified)
    #expect(evaluation.canSave)
    #expect(evaluation.blockingReason == nil)
  }

  @Test func previewMatchesProductionRuleExecution() throws {
    let sessionID = UUID()
    let item = ItemSnapshot(
      sessionID: sessionID,
      path: "/tmp/nhentai-42 - Example.PDF",
      name: "nhentai-42 - Example.PDF",
      kind: .file,
      fileExtension: "PDF")
    let rule = NamingRule(
      workspaceID: UUID(),
      originalText: "同人志删除编号",
      condition: RuleCondition(
        filenameKeywords: ["nhentai-"],
        semanticDescription: "同人志"),
      operations: [.removeNumericPrefix(prefix: "nhentai-", suffix: " - ")])
    let proposal = try #require(NamingRuleEngine().proposals(
      sessionID: sessionID,
      contexts: [ItemContext(snapshot: item, normalizedKeywords: [])],
      rules: [rule],
      semanticEvaluationsByItem: [item.id: [rule.id: .match(reason: "示例")]]
    ).first)
    let productionName = try FilenameValidator().validatedFullName(
      baseName: proposal.suggestedBaseName,
      item: item)

    let evaluation = NamingRuleExampleEvaluator().evaluate(
      operations: rule.operations,
      condition: rule.condition,
      originalName: item.name,
      expectedName: nil)

    #expect(evaluation.preview?.suggestedName == productionName)
  }

  @Test func noOpAndInvalidExamplesBlockSavingWithReasons() {
    let noOp = NamingRuleExampleEvaluator().evaluate(
      operations: [.removeLiteralPrefix("draft_")],
      condition: RuleCondition(filenameKeywords: ["draft_"]),
      originalName: "report.pdf",
      expectedName: nil)
    let invalid = NamingRuleExampleEvaluator().evaluate(
      operations: [.replaceLiteral(target: "_", replacement: "/")],
      condition: RuleCondition(filenameKeywords: ["_"]),
      originalName: "annual_report.pdf",
      expectedName: nil)

    #expect(!noOp.canSave)
    #expect(noOp.blockingReason?.contains("没有变化") == true)
    #expect(!invalid.canSave)
    #expect(invalid.blockingReason?.contains("非法字符") == true)
  }

  @Test func omittedExampleDoesNotBlockValidOperations() {
    let evaluation = NamingRuleExampleEvaluator().evaluate(
      operations: [.removeLiteralPrefix("draft_")],
      condition: RuleCondition(filenameKeywords: ["draft_"]),
      originalName: "",
      expectedName: "")

    #expect(evaluation.preview == nil)
    #expect(evaluation.canSave)
  }

  @Test func expectedNameMismatchBlocksSavingAndShowsActualPreview() {
    let evaluation = NamingRuleExampleEvaluator().evaluate(
      operations: [.removeLiteralPrefix("draft_")],
      condition: RuleCondition(filenameKeywords: ["draft_"]),
      originalName: "draft_report.pdf",
      expectedName: "summary.pdf")

    #expect(evaluation.preview?.suggestedName == "report.pdf")
    #expect(!evaluation.canSave)
    #expect(evaluation.blockingReason?.contains("预期名称") == true)
  }
}
