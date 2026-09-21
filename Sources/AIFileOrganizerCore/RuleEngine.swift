import Foundation

public struct RuleEngine: Sendable {
  private enum MatchTarget: Hashable {
    case move(UUID)
    case keep
  }

  public init() {}

  public func evaluate(
    item: ItemContext, rules: [OrganizationRule],
    recognition: ConceptRecognitionResult? = nil, concepts: [FileConcept]? = nil
  ) -> RuleEvaluation {
    let knownConceptIDs = concepts.map { Set($0.map(\.id)) }
    var matches: [(ruleID: UUID, target: MatchTarget, conceptID: UUID?)] = []
    var semantic: [UUID] = []
    for rule in rules where rule.isEnabled {
      guard deterministicPartMatches(
        rule.condition, item: item, recognition: recognition,
        knownConceptIDs: knownConceptIDs) else {
        continue
      }
      if rule.condition.semanticDescription != nil {
        semantic.append(rule.id)
      } else if rule.condition.hasDeterministicConditions {
        switch rule.action {
        case .move:
          if let destinationID = rule.destinationID {
            matches.append((rule.id, .move(destinationID), rule.condition.conceptID))
          }
        case .keep:
          matches.append((rule.id, .keep, rule.condition.conceptID))
        }
      }
    }
    let parentByID = Dictionary(uniqueKeysWithValues: (concepts ?? []).map { ($0.id, $0.parentID) })
    let matchedConceptIDs = Set(matches.compactMap(\.conceptID))
    matches.removeAll { match in
      guard let conceptID = match.conceptID else { return false }
      return matchedConceptIDs.contains { otherID in
        otherID != conceptID && isAncestor(conceptID, of: otherID, parentByID: parentByID)
      }
    }
    let targets = Set(matches.map(\.target))
    if targets.count > 1 { return .conflict(ruleIDs: matches.map(\.ruleID)) }
    if let first = matches.first {
      switch first.target {
      case .move(let destinationID):
        return .matchedMove(ruleID: first.ruleID, destinationID: destinationID)
      case .keep:
        return .matchedKeep(ruleID: first.ruleID)
      }
    }
    if !semantic.isEmpty { return .semanticCandidates(semantic) }
    return .none
  }

  private func deterministicPartMatches(
    _ condition: RuleCondition, item: ItemContext,
    recognition: ConceptRecognitionResult?, knownConceptIDs: Set<UUID>?
  ) -> Bool {
    if let conceptID = condition.conceptID {
      if knownConceptIDs.map({ !$0.contains(conceptID) }) == true { return false }
      if recognition?.confirmedConceptIDs.contains(conceptID) != true { return false }
    }
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
