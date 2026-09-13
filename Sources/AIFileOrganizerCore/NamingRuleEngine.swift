import Foundation

public struct NamingRuleEngine: Sendable {
  public init() {}

  public func proposals(
    sessionID: UUID,
    contexts: [ItemContext],
    rules: [NamingRule]
  ) -> [RenameProposal] {
    contexts.compactMap { context -> RenameProposal? in
      guard context.snapshot.kind != .applicationBundle else { return nil }
      let matches = rules.filter { $0.isEnabled && conditionMatches($0.condition, context: context) }
      guard !matches.isEmpty else { return nil }
      if matches.contains(where: { $0.condition.semanticDescription != nil }) {
        return blockedProposal(
          sessionID: sessionID, context: context, ruleID: matches.first?.id,
          reason: "命名规则需要本地 AI 判断")
      }
      let fields = fields(for: context)
      let evaluated: [(rule: NamingRule, result: TemplateRenderResult, fullName: String?)] = matches.map {
        let result = (try? FilenameTemplateEngine().render(template: $0.template, fields: fields))
          ?? TemplateRenderResult(value: originalBaseName(context.snapshot))
        let fullName = result.missingFields.isEmpty
          ? try? FilenameValidator().validatedFullName(baseName: result.value, item: context.snapshot)
          : nil
        return ($0, result, fullName)
      }
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
        reason: "匹配用户命名规则"
      )
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

  private func conditionMatches(_ condition: RuleCondition, context: ItemContext) -> Bool {
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
}
