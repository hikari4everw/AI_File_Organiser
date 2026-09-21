import Foundation

public struct ConceptProposalInvalidator: Sendable {
  public init() {}

  public func changedConfirmedConceptIDs(
    before: [UUID: ConceptRecognitionResult],
    after: [UUID: ConceptRecognitionResult],
    itemIDs: Set<UUID>
  ) -> Set<UUID> {
    itemIDs.reduce(into: Set<UUID>()) { changed, itemID in
      let oldIDs = before[itemID]?.confirmedConceptIDs ?? []
      let newIDs = after[itemID]?.confirmedConceptIDs ?? []
      changed.formUnion(oldIDs.symmetricDifference(newIDs))
    }
  }

  public func invalidate(
    proposals: [ClassificationProposal], renames: [RenameProposal],
    moveRuleIDs: Set<UUID>, namingRuleIDs: Set<UUID>,
    itemIDs: Set<UUID> = []
  ) -> (proposals: [ClassificationProposal], renames: [RenameProposal]) {
    let moves = proposals.map { proposal -> ClassificationProposal in
      guard (itemIDs.isEmpty || itemIDs.contains(proposal.itemID)),
        proposal.evidence.contains(where: {
          $0.kind == "rule"
            && UUID(uuidString: $0.detail).map { moveRuleIDs.contains($0) } == true
        }) else { return proposal }
      var invalid = proposal
      invalid.action = .keep
      invalid.destinationID = nil
      invalid.suggestedFolderName = nil
      invalid.reviewDecision = .needsReview
      invalid.status = .pending
      invalid.reason = "关联概念已更新，请重新确认目标"
      invalid.evidence = []
      return invalid
    }
    let names = renames.map { rename -> RenameProposal in
      guard (itemIDs.isEmpty || itemIDs.contains(rename.itemID)),
        rename.ruleID.map({ namingRuleIDs.contains($0) }) == true
      else { return rename }
      var invalid = rename
      invalid.disposition = .blocked
      invalid.editedBaseName = nil
      invalid.reason = "关联概念已更新，请重新确认命名"
      return invalid
    }
    return (moves, names)
  }
}
