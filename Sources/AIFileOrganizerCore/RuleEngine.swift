import Foundation

public struct RuleEngine: Sendable {
  public init() {}

  public func evaluate(item: ItemContext, rules: [OrganizationRule]) -> RuleEvaluation {
    var matches: [(UUID, UUID)] = []
    var semantic: [UUID] = []
    for rule in rules where rule.isEnabled {
      guard deterministicPartMatches(rule.condition, item: item) else { continue }
      if rule.condition.semanticDescription != nil {
        semantic.append(rule.id)
      } else if rule.condition.hasDeterministicConditions {
        matches.append((rule.id, rule.destinationID))
      }
    }
    let destinations = Set(matches.map(\.1))
    if destinations.count > 1 { return .conflict(ruleIDs: matches.map(\.0)) }
    if let first = matches.first { return .matched(ruleID: first.0, destinationID: first.1) }
    if !semantic.isEmpty { return .semanticCandidates(semantic) }
    return .none
  }

  private func deterministicPartMatches(_ condition: RuleCondition, item: ItemContext) -> Bool {
    if !condition.itemKinds.isEmpty, !condition.itemKinds.contains(item.snapshot.kind) { return false }
    if !condition.fileExtensions.isEmpty,
      !condition.fileExtensions.contains(item.snapshot.fileExtension.lowercased())
    {
      return false
    }
    let name = RuleCondition.normalize(item.snapshot.name)
    if !condition.filenameKeywords.isEmpty,
      !condition.filenameKeywords.contains(where: name.contains)
    {
      return false
    }
    let content = RuleCondition.normalize(item.extracted.text)
    if !condition.contentKeywords.isEmpty,
      !condition.contentKeywords.contains(where: content.contains)
    {
      return false
    }
    return condition.hasDeterministicConditions || condition.semanticDescription != nil
  }
}
