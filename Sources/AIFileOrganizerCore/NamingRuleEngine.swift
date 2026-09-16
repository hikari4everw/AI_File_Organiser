import Foundation

public struct NamingRuleEngine: Sendable {
  public init() {}

  public func proposals(
    sessionID: UUID,
    contexts: [ItemContext],
    rules: [NamingRule],
    semanticEvaluationsByItem: [UUID: [UUID: SemanticNamingConditionEvaluation]] = [:],
    recognitionByItem: [UUID: ConceptRecognitionResult] = [:],
    concepts: [FileConcept] = []
  ) -> [RenameProposal] {
    contexts.compactMap { context -> RenameProposal? in
      guard context.snapshot.kind != .applicationBundle else { return nil }
      let candidates = rules.filter {
        $0.isEnabled && !$0.operations.isEmpty
          && conditionMatches(
            $0.condition, context: context, recognition: recognitionByItem[context.id])
      }
      var matches: [NamingRule] = []
      var unresolved: [(rule: NamingRule, reason: String)] = []
      for rule in candidates {
        guard rule.condition.semanticDescription != nil else {
          matches.append(rule)
          continue
        }
        switch semanticEvaluationsByItem[context.id]?[rule.id] {
        case .match:
          matches.append(rule)
        case .noMatch:
          continue
        case .uncertain(let reason):
          unresolved.append((rule, reason))
        case nil:
          unresolved.append((rule, "需要本地 AI 判断"))
        }
      }
      if let first = unresolved.first {
        return blockedProposal(
          sessionID: sessionID, context: context,
          ruleID: unresolved.count == 1 ? first.rule.id : nil,
          reason: "命名规则语义判断不确定：\(first.reason)")
      }
      let parentByID = Dictionary(uniqueKeysWithValues: concepts.map { ($0.id, $0.parentID) })
      let matchedIDs = Set(matches.compactMap(\.condition.conceptID))
      matches.removeAll { rule in
        guard let conceptID = rule.condition.conceptID else { return false }
        return matchedIDs.contains { otherID in
          otherID != conceptID && isAncestor(conceptID, of: otherID, parentByID: parentByID)
        }
      }
      guard !matches.isEmpty else { return nil }
      let fields = fields(for: context)
      let baseName = originalBaseName(context.snapshot)
      let evaluated: [(rule: NamingRule, result: TemplateRenderResult, fullName: String?)] =
        matches.compactMap {
          let result = (try? NamingOperationEngine().render(
            operations: $0.operations,
            baseName: baseName,
            fields: fields))
            ?? TemplateRenderResult(value: baseName)
          guard !hasTransformation($0.operations) || result.value != baseName else { return nil }
          let fullName = result.missingFields.isEmpty
            ? try? FilenameValidator().validatedFullName(baseName: result.value, item: context.snapshot)
            : nil
          return ($0, result, fullName)
        }
      guard !evaluated.isEmpty else { return nil }
      if evaluated.count > 1 {
        let names = Set(evaluated.compactMap(\.fullName).map(normalizedKey))
        if names.count > 1 {
          return blockedProposal(
            sessionID: sessionID, context: context, ruleID: nil,
            reason: "多个命名规则给出了不同名称")
        }
      }
      guard let first = evaluated.first else { return nil }
      guard first.result.missingFields.isEmpty, first.fullName != nil else {
        return RenameProposal(
          sessionID: sessionID,
          itemID: context.id,
          originalName: context.snapshot.name,
          suggestedBaseName: originalBaseName(context.snapshot),
          source: .namingRule,
          disposition: .blocked,
          ruleID: first.rule.id,
          templatePattern: first.rule.template.pattern,
          missingFields: first.result.missingFields,
          reason: first.result.missingFields.isEmpty ? "命名结果不合法" : "命名规则缺少必要字段"
        )
      }
      return RenameProposal(
        sessionID: sessionID,
        itemID: context.id,
        originalName: context.snapshot.name,
        suggestedBaseName: first.result.value,
        source: .namingRule,
        disposition: .selectedByRule,
        ruleID: first.rule.id,
        templatePattern: first.rule.template.pattern,
        reason: "匹配用户命名规则"
      )
    }
  }

  public func semanticCandidateRules(
    context: ItemContext, rules: [NamingRule],
    recognition: ConceptRecognitionResult? = nil
  ) -> [NamingRule] {
    guard context.snapshot.kind != .applicationBundle else { return [] }
    return rules.filter {
      $0.isEnabled && !$0.operations.isEmpty && $0.condition.semanticDescription != nil
        && conditionMatches($0.condition, context: context, recognition: recognition)
    }
  }

  private func fields(for context: ItemContext) -> [FilenameField: String] {
    var values: [FilenameField: String] = [
      .originalTitle: originalBaseName(context.snapshot)
    ]
    if let title = context.spotlightTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
      !title.isEmpty
    {
      values[.title] = title
    }
    if let author = context.spotlightAuthors.first?.trimmingCharacters(in: .whitespacesAndNewlines),
      !author.isEmpty
    {
      values[.author] = author
    }
    if let date = context.snapshot.creationDate {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy-MM-dd"
      values[.date] = formatter.string(from: date)
    }
    return values
  }

  private func originalBaseName(_ item: ItemSnapshot) -> String {
    guard item.kind == .file, !item.fileExtension.isEmpty else { return item.name }
    return URL(fileURLWithPath: item.name).deletingPathExtension().lastPathComponent
  }

  private func conditionMatches(
    _ condition: RuleCondition, context: ItemContext,
    recognition: ConceptRecognitionResult?
  ) -> Bool {
    if let conceptID = condition.conceptID,
      recognition?.confirmedConceptIDs.contains(conceptID) != true
    {
      return false
    }
    if !condition.itemKinds.isEmpty, !condition.itemKinds.contains(context.snapshot.kind) {
      return false
    }
    if !condition.fileExtensions.isEmpty,
      !condition.fileExtensions.contains(context.snapshot.fileExtension.lowercased())
    {
      return false
    }
    let name = RuleCondition.normalize(context.snapshot.name)
    if !condition.filenameKeywords.isEmpty,
      !condition.filenameKeywords.contains(where: name.contains)
    {
      return false
    }
    let content = RuleCondition.normalize(context.extracted.text)
    if !condition.contentKeywords.isEmpty,
      !condition.contentKeywords.contains(where: content.contains)
    {
      return false
    }
    return condition.hasDeterministicConditions || condition.semanticDescription != nil
  }

  private func blockedProposal(
    sessionID: UUID, context: ItemContext, ruleID: UUID?, reason: String
  ) -> RenameProposal {
    RenameProposal(
      sessionID: sessionID,
      itemID: context.id,
      originalName: context.snapshot.name,
      suggestedBaseName: originalBaseName(context.snapshot),
      source: .namingRule,
      disposition: .blocked,
      ruleID: ruleID,
      reason: reason
    )
  }

  private func normalizedKey(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  private func hasTransformation(_ operations: [NamingOperation]) -> Bool {
    operations.contains { operation in
      if case .renderTemplate = operation { return false }
      return true
    }
  }

  private func isAncestor(
    _ ancestorID: UUID, of childID: UUID, parentByID: [UUID: UUID?]
  ) -> Bool {
    var current = parentByID[childID] ?? nil
    var visited: Set<UUID> = [childID]
    while let id = current, !visited.contains(id) {
      if id == ancestorID { return true }
      visited.insert(id)
      current = parentByID[id] ?? nil
    }
    return false
  }
}
