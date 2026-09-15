import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct NamingOperationTests {
  @Test(arguments: [
    ("nhentai-1 - First", "First"),
    ("nhentai-651786 - Example", "Example"),
    ("nhentai-999999999999 - Last", "Last"),
  ])
  func constrainedNumericPrefixAcceptsDifferentNumbers(input: String, expected: String) throws {
    let result = try NamingOperationEngine().render(
      operations: [.removeNumericPrefix(prefix: "nhentai-", suffix: " - ")],
      baseName: input,
      fields: [:])

    #expect(result.value == expected)
    #expect(result.missingFields.isEmpty)
  }

  @Test(arguments: [
    "Intro nhentai-651786 - Example",
    "nhentai- - Example",
    "nhentai-651786-Example",
    "nhentai-abc - Example",
  ])
  func constrainedNumericPrefixDoesNotRemoveMiddleOrMalformedText(input: String) throws {
    let result = try NamingOperationEngine().render(
      operations: [.removeNumericPrefix(prefix: "nhentai-", suffix: " - ")],
      baseName: input,
      fields: [:])

    #expect(result.value == input)
  }

  @Test func literalAndNumericSuffixOperationsOnlyRemoveMatchingEndings() throws {
    let engine = NamingOperationEngine()

    #expect(try engine.render(
      operations: [.removeLiteralSuffix(" - 副本")],
      baseName: "报告 - 副本",
      fields: [:]).value == "报告")
    #expect(try engine.render(
      operations: [.removeLiteralSuffix(" - 副本")],
      baseName: "报告 - 副本 - 最终",
      fields: [:]).value == "报告 - 副本 - 最终")
    #expect(try engine.render(
      operations: [.removeNumericSuffix(prefix: " - ", suffix: "页")],
      baseName: "报告 - 42页",
      fields: [:]).value == "报告")
    #expect(try engine.render(
      operations: [.removeNumericSuffix(prefix: " - ", suffix: "页")],
      baseName: "报告 - 四十二页",
      fields: [:]).value == "报告 - 四十二页")
  }

  @Test func literalReplacementReplacesEveryExactOccurrence() throws {
    let result = try NamingOperationEngine().render(
      operations: [.replaceLiteral(target: "_", replacement: " ")],
      baseName: "Annual_Report_2026",
      fields: [:])

    #expect(result.value == "Annual Report 2026")
  }

  @Test func operationsRunInDeclaredOrderAndTemplateUsesCurrentBaseName() throws {
    let result = try NamingOperationEngine().render(
      operations: [
        .removeLiteralPrefix("draft_"),
        .replaceLiteral(target: "_", replacement: " "),
        .renderTemplate(FilenameTemplate(pattern: "Final - {原标题} - {作者}")),
      ],
      baseName: "draft_Moonlight_Sonata",
      fields: [.author: "Beethoven"])

    #expect(result.value == "Final - Moonlight Sonata - Beethoven")
    #expect(result.missingFields.isEmpty)
  }

  @Test func operationEnginePreservesTemplateMissingFieldReporting() throws {
    let result = try NamingOperationEngine().render(
      operations: [
        .removeLiteralPrefix("draft_"),
        .renderTemplate(FilenameTemplate(pattern: "{原标题} - {作者}")),
      ],
      baseName: "draft_Report",
      fields: [:])

    #expect(result.value == "Report - {作者}")
    #expect(result.missingFields == [.author])
  }

  @Test func namingRuleEngineAppliesOperationsToFilesAndPreservesExtensionContract() throws {
    let sessionID = UUID()
    let item = ItemSnapshot(
      sessionID: sessionID,
      path: "/tmp/nhentai-651786 - Example.PDF",
      name: "nhentai-651786 - Example.PDF",
      kind: .file,
      fileExtension: "PDF")
    let rule = NamingRule(
      workspaceID: UUID(),
      originalText: "删除数字前缀",
      condition: RuleCondition(filenameKeywords: ["nhentai-"]),
      operations: [.removeNumericPrefix(prefix: "nhentai-", suffix: " - ")])

    let proposal = try #require(NamingRuleEngine().proposals(
      sessionID: sessionID,
      contexts: [ItemContext(snapshot: item, normalizedKeywords: [])],
      rules: [rule]
    ).first)

    #expect(proposal.suggestedBaseName == "Example")
    #expect(proposal.disposition == .selectedByRule)
  }

  @Test func namingRuleEngineDoesNotProposeWhenNumericPrefixOccursInMiddle() {
    let sessionID = UUID()
    let item = ItemSnapshot(
      sessionID: sessionID,
      path: "/tmp/Intro nhentai-651786 - Example.pdf",
      name: "Intro nhentai-651786 - Example.pdf",
      kind: .file,
      fileExtension: "pdf")
    let rule = NamingRule(
      workspaceID: UUID(),
      originalText: "删除数字前缀",
      condition: RuleCondition(filenameKeywords: ["nhentai-"]),
      operations: [.removeNumericPrefix(prefix: "nhentai-", suffix: " - ")])

    let proposals = NamingRuleEngine().proposals(
      sessionID: sessionID,
      contexts: [ItemContext(snapshot: item, normalizedKeywords: [])],
      rules: [rule])

    #expect(proposals.isEmpty)
  }

  @Test func namingRuleEngineAppliesOperationsToCompleteDirectoryName() throws {
    let sessionID = UUID()
    let item = ItemSnapshot(
      sessionID: sessionID,
      path: "/tmp/draft_Project.old",
      name: "draft_Project.old",
      kind: .directory)
    let rule = NamingRule(
      workspaceID: UUID(),
      originalText: "目录删除前缀",
      condition: RuleCondition(itemKinds: [.directory], filenameKeywords: ["draft_"]),
      operations: [.removeLiteralPrefix("draft_")])

    let proposal = try #require(NamingRuleEngine().proposals(
      sessionID: sessionID,
      contexts: [ItemContext(snapshot: item, normalizedKeywords: [])],
      rules: [rule]
    ).first)

    #expect(proposal.suggestedBaseName == "Project.old")
    #expect(proposal.disposition == .selectedByRule)
  }

  @Test func legacyNamingRuleAndDraftPayloadsDecodeAsTemplateOperations() throws {
    let rule = NamingRule(
      workspaceID: UUID(),
      originalText: "PDF 命名为标题",
      condition: RuleCondition(fileExtensions: ["pdf"]),
      template: FilenameTemplate(pattern: "{标题}"))
    let draft = NamingRuleDraft(
      originalText: "PDF 命名为标题",
      condition: RuleCondition(fileExtensions: ["pdf"]),
      template: FilenameTemplate(pattern: "{标题}"))

    let legacyRule = try removingOperations(from: JSONEncoder().encode(rule))
    let legacyDraft = try removingOperations(from: JSONEncoder().encode(draft))

    #expect(
      try JSONDecoder().decode(NamingRule.self, from: legacyRule).operations
        == [.renderTemplate(FilenameTemplate(pattern: "{标题}"))])
    #expect(
      try JSONDecoder().decode(NamingRuleDraft.self, from: legacyDraft).operations
        == [.renderTemplate(FilenameTemplate(pattern: "{标题}"))])
  }

  @Test func existingTemplateInitializersCreateTemplateOperations() {
    let template = FilenameTemplate(pattern: "{原标题}")
    let rule = NamingRule(
      workspaceID: UUID(), originalText: "keep source",
      condition: RuleCondition(fileExtensions: ["txt"]), template: template)
    let draft = NamingRuleDraft(
      originalText: "keep source", condition: RuleCondition(fileExtensions: ["txt"]),
      template: template)

    #expect(rule.operations == [.renderTemplate(template)])
    #expect(draft.operations == [.renderTemplate(template)])
  }

  @Test func exactDoujinshiSentenceCreatesSafeConstrainedOperation() async throws {
    let sentence = "对于同人志，删除前缀无意义编码，例如 nhentai-651786 - ...，删除 nhentai-651786 -"

    let draft = try #require(
      try await AppleRuleInterpreter().interpretNaming(text: sentence).first)

    #expect(draft.originalText == sentence)
    #expect(draft.condition.semanticDescription == "同人志")
    #expect(draft.condition.filenameKeywords == ["nhentai-"])
    #expect(
      draft.operations == [.removeNumericPrefix(prefix: "nhentai-", suffix: " - ")])
    #expect(draft.warnings.isEmpty)
  }

  @Test func combinedSemanticAndExtensionConditionArePreserved() async throws {
    let draft = try #require(
      try await AppleRuleInterpreter().interpretNaming(
        text: "对于同人志 PDF 文件，删除前缀「draft_」").first)

    #expect(draft.condition.fileExtensions == ["pdf"])
    #expect(draft.condition.semanticDescription == "同人志")
    #expect(draft.operations == [.removeLiteralPrefix("draft_")])
  }

  @Test func nhentaiSpecialCaseAddsConstraintWithoutDiscardingExplicitConditions() async throws {
    let draft = try #require(
      try await AppleRuleInterpreter().interpretNaming(
        text: "对于名称包含「月光」的同人志 PDF 文件，删除前缀无意义编码，例如 nhentai-651786 - ..."
      ).first)

    #expect(draft.condition.itemKinds == [.file])
    #expect(draft.condition.fileExtensions == ["pdf"])
    #expect(draft.condition.filenameKeywords == ["月光", "nhentai-"])
    #expect(draft.condition.semanticDescription == "同人志")
    #expect(
      draft.operations == [.removeNumericPrefix(prefix: "nhentai-", suffix: " - ")])
  }

  @Test func nhentaiMeaningAfterOperationMarkerStillRequiresSemanticDecision() async throws {
    let draft = try #require(
      try await AppleRuleInterpreter().interpretNaming(
        text: "对于 PDF 文件，删除前缀无意义编码，例如 nhentai-651786 - 同人志").first)
    #expect(draft.condition.fileExtensions == ["pdf"])
    #expect(draft.condition.filenameKeywords == ["nhentai-"])
    #expect(draft.condition.semanticDescription == "同人志")

    let rule = NamingRule(
      workspaceID: UUID(),
      originalText: draft.originalText,
      condition: draft.condition,
      operations: draft.operations)
    let sessionID = UUID()
    let item = ItemSnapshot(
      sessionID: sessionID,
      path: "/tmp/nhentai-42 - Example.pdf",
      name: "nhentai-42 - Example.pdf",
      kind: .file,
      fileExtension: "pdf")

    let proposal = try #require(NamingRuleEngine().proposals(
      sessionID: sessionID,
      contexts: [ItemContext(snapshot: item, normalizedKeywords: [])],
      rules: [rule]
    ).first)

    #expect(proposal.disposition == .blocked)
    #expect(proposal.reason.contains("需要本地 AI 判断"))
  }

  @Test func nhentaiExampleWithoutDoujinshiMeaningIsNotExecutable() async throws {
    let draft = try #require(
      try await AppleRuleInterpreter().interpretNaming(
        text: "删除前缀无意义编码，例如 nhentai-651786 - ...").first)

    #expect(draft.condition.semanticDescription == nil)
    #expect(draft.operations.isEmpty)
    #expect(draft.warnings.contains(where: { $0.contains("同人志") }))
  }

  @Test func interpreterParsesLiteralSuffixAndReplacementExpressions() async throws {
    let suffix = try #require(
      try await AppleRuleInterpreter().interpretNaming(
        text: "对于 PDF 文件，删除后缀「 - 副本」").first)
    let replacement = try #require(
      try await AppleRuleInterpreter().interpretNaming(
        text: "对于 TXT 文件，把下划线 _ 替换为短横线 -").first)

    #expect(suffix.condition.fileExtensions == ["pdf"])
    #expect(suffix.operations == [.removeLiteralSuffix(" - 副本")])
    #expect(replacement.condition.fileExtensions == ["txt"])
    #expect(replacement.operations == [.replaceLiteral(target: "_", replacement: "-")])
  }

  @Test func replacementOperandsAreReadOnlyFromOperationFragment() async throws {
    let draft = try #require(
      try await AppleRuleInterpreter().interpretNaming(
        text: "对于名称包含「draft」的 PDF 文件，把「_」替换为「-」").first)

    #expect(draft.condition.itemKinds == [.file])
    #expect(draft.condition.fileExtensions == ["pdf"])
    #expect(draft.condition.filenameKeywords == ["draft"])
    #expect(draft.condition.semanticDescription == nil)
    #expect(draft.operations == [.replaceLiteral(target: "_", replacement: "-")])
  }

  @Test func multipleTransformationsAreRejectedWhenOrderCannotBeParsedReliably() async throws {
    let draft = try #require(
      try await AppleRuleInterpreter().interpretNaming(
        text: "对于 PDF 文件，删除前缀「draft_」，再把「_」替换为「-」").first)

    #expect(draft.condition.fileExtensions == ["pdf"])
    #expect(draft.operations.isEmpty)
    #expect(draft.warnings.contains(where: { $0.contains("多项") && $0.contains("顺序") }))
  }

  @Test func naturalLanguageCombinedSemanticAndDeterministicConditionsReachExecution() async throws {
    let draft = try #require(
      try await AppleRuleInterpreter().interpretNaming(
        text: "对于同人志 PDF 文件，删除前缀「draft_」").first)
    let rule = NamingRule(
      workspaceID: UUID(),
      originalText: draft.originalText,
      condition: draft.condition,
      operations: draft.operations)
    let sessionID = UUID()
    let pdf = ItemSnapshot(
      sessionID: sessionID,
      path: "/tmp/draft_chapter.pdf",
      name: "draft_chapter.pdf",
      kind: .file,
      fileExtension: "pdf")
    let text = ItemSnapshot(
      sessionID: sessionID,
      path: "/tmp/draft_chapter.txt",
      name: "draft_chapter.txt",
      kind: .file,
      fileExtension: "txt")

    let proposals = NamingRuleEngine().proposals(
      sessionID: sessionID,
      contexts: [
        ItemContext(snapshot: pdf, normalizedKeywords: []),
        ItemContext(snapshot: text, normalizedKeywords: []),
      ],
      rules: [rule],
      semanticEvaluationsByItem: [
        pdf.id: [rule.id: .match(reason: "是同人志")],
        text.id: [rule.id: .match(reason: "是同人志")],
      ])

    #expect(proposals.map(\.itemID) == [pdf.id])
    #expect(proposals.first?.suggestedBaseName == "chapter")
  }

  @Test func naturalLanguageNhentaiRuleKeepsFileTypeConstraintDuringExecution() async throws {
    let draft = try #require(
      try await AppleRuleInterpreter().interpretNaming(
        text: "对于同人志 PDF 文件，删除前缀无意义编码，例如 nhentai-651786 - ...").first)
    let rule = NamingRule(
      workspaceID: UUID(),
      originalText: draft.originalText,
      condition: draft.condition,
      operations: draft.operations)
    let sessionID = UUID()
    let pdf = ItemSnapshot(
      sessionID: sessionID,
      path: "/tmp/nhentai-651786 - 月光.pdf",
      name: "nhentai-651786 - 月光.pdf",
      kind: .file,
      fileExtension: "pdf")
    let image = ItemSnapshot(
      sessionID: sessionID,
      path: "/tmp/nhentai-651786 - 月光.jpg",
      name: "nhentai-651786 - 月光.jpg",
      kind: .file,
      fileExtension: "jpg")

    let proposals = NamingRuleEngine().proposals(
      sessionID: sessionID,
      contexts: [
        ItemContext(snapshot: pdf, normalizedKeywords: []),
        ItemContext(snapshot: image, normalizedKeywords: []),
      ],
      rules: [rule],
      semanticEvaluationsByItem: [
        pdf.id: [rule.id: .match(reason: "是同人志")],
        image.id: [rule.id: .match(reason: "是同人志")],
      ])

    #expect(proposals.map(\.itemID) == [pdf.id])
    #expect(proposals.first?.suggestedBaseName == "月光")
  }

  @Test func naturalLanguageQuotedConditionAndReplacementReachExecution() async throws {
    let draft = try #require(
      try await AppleRuleInterpreter().interpretNaming(
        text: "对于名称包含「draft」的 PDF 文件，把「_」替换为「-」").first)
    let rule = NamingRule(
      workspaceID: UUID(),
      originalText: draft.originalText,
      condition: draft.condition,
      operations: draft.operations)
    let sessionID = UUID()
    let matching = ItemSnapshot(
      sessionID: sessionID,
      path: "/tmp/draft_report.pdf",
      name: "draft_report.pdf",
      kind: .file,
      fileExtension: "pdf")
    let other = ItemSnapshot(
      sessionID: sessionID,
      path: "/tmp/final_report.pdf",
      name: "final_report.pdf",
      kind: .file,
      fileExtension: "pdf")

    let proposals = NamingRuleEngine().proposals(
      sessionID: sessionID,
      contexts: [
        ItemContext(snapshot: matching, normalizedKeywords: []),
        ItemContext(snapshot: other, normalizedKeywords: []),
      ],
      rules: [rule])

    #expect(proposals.map(\.itemID) == [matching.id])
    #expect(proposals.first?.suggestedBaseName == "draft-report")
  }

  @Test func ambiguousTransformationReturnsWarningWithoutExecutableOperation() async throws {
    let draft = try #require(
      try await AppleRuleInterpreter().interpretNaming(
        text: "对于 PDF 文件，删除文件名中无意义的部分").first)

    #expect(draft.operations.isEmpty)
    #expect(draft.warnings.contains(where: { $0.contains("无法安全解析") }))
  }

  @Test func unquotedDescriptiveReplacementIsNotTreatedAsLiteralText() async throws {
    let draft = try #require(
      try await AppleRuleInterpreter().interpretNaming(
        text: "对于 TXT 文件，把空格替换为下划线").first)

    #expect(draft.operations.isEmpty)
    #expect(draft.warnings.contains(where: { $0.contains("无法安全解析") }))
  }

  @Test func emptyOperationsFailSaveValidation() {
    #expect(throws: OrganizerError.self) {
      try NamingOperationEngine().validate(operations: [])
    }
  }

  @Test func namingRuleEngineIgnoresUnexpectedEmptyOperationRule() {
    let sessionID = UUID()
    let item = ItemSnapshot(
      sessionID: sessionID,
      path: "/tmp/report.pdf",
      name: "report.pdf",
      kind: .file,
      fileExtension: "pdf")
    let rule = NamingRule(
      workspaceID: UUID(),
      originalText: "ambiguous",
      condition: RuleCondition(fileExtensions: ["pdf"]),
      operations: [])

    let proposals = NamingRuleEngine().proposals(
      sessionID: sessionID,
      contexts: [ItemContext(snapshot: item, normalizedKeywords: [])],
      rules: [rule])

    #expect(proposals.isEmpty)
  }

  private func removingOperations(from data: Data) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "operations")
    return try JSONSerialization.data(withJSONObject: object)
  }
}
