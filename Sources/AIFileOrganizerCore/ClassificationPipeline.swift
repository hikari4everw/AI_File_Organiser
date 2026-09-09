import Foundation

public struct ClassificationPipelineResult: Sendable {
  public var proposals: [ClassificationProposal]
  public var folderProposals: [FolderProposal]
  public var modelStatus: String

  public init(
    proposals: [ClassificationProposal], folderProposals: [FolderProposal], modelStatus: String
  ) {
    self.proposals = proposals
    self.folderProposals = folderProposals
    self.modelStatus = modelStatus
  }
}

public struct ClassificationPipeline: Sendable {
  private let classifier: DeterministicClassifier
  private let extractor: any ContentExtractor
  private let provider: any ClassificationProvider
  private let policy: any DecisionPolicy

  public init(
    classifier: DeterministicClassifier = .init(),
    extractor: any ContentExtractor = NativeContentExtractor(),
    provider: any ClassificationProvider = AppleFoundationModelProvider(),
    policy: any DecisionPolicy = DefaultDecisionPolicy()
  ) {
    self.classifier = classifier
    self.extractor = extractor
    self.provider = provider
    self.policy = policy
  }

  public func run(
    sessionID: UUID,
    items: [ItemSnapshot],
    destinations: [DestinationProfile]
  ) async -> ClassificationPipelineResult {
    await run(
      sessionID: sessionID,
      items: items,
      destinations: destinations,
      progress: { _ in }
    )
  }

  public func run(
    sessionID: UUID,
    items: [ItemSnapshot],
    destinations: [DestinationProfile],
    progress: @escaping OrganizationProgressHandler
  ) async -> ClassificationPipelineResult {
    var final: [UUID: ClassificationProposal] = [:]
    var candidatesByItem: [UUID: [RankedCandidate]] = [:]
    var ambiguous: [ItemContext] = []

    if !Task.isCancelled {
      await progress(
        OrganizationProgress(phase: .analyzing, total: items.count, isCancellable: true))
    }
    for (index, item) in items.enumerated() {
      if Task.isCancelled { break }
      let basic = classifier.context(for: item)
      let candidates = classifier.rank(basic, destinations: destinations)
      candidatesByItem[item.id] = candidates
      if let proposal = classifier.proposal(
        sessionID: sessionID, item: basic, candidates: candidates),
        proposal.reviewDecision == .ready
      {
        final[item.id] = proposal
      } else {
        let extracted = await extractor.extractContext(for: item)
        let enriched = classifier.context(for: item, extracted: extracted)
        let reranked = classifier.rank(enriched, destinations: destinations)
        candidatesByItem[item.id] = reranked
        ambiguous.append(enriched)
      }
      if !Task.isCancelled {
        await progress(
          OrganizationProgress(
            phase: .analyzing,
            completed: index + 1,
            total: items.count,
            isCancellable: true
          ))
      }
    }

    var modelStatus = provider.availabilityDescription
    var modelByItem: [UUID: ModelProposal] = [:]
    if provider.isAvailable, !ambiguous.isEmpty, !Task.isCancelled {
      await progress(
        OrganizationProgress(
          phase: .aiClassifying,
          total: ambiguous.count,
          isIndeterminate: true,
          isCancellable: true
        ))
      do {
        let requestedItemIDs = Set(ambiguous.map(\.id))
        let allowedDestinationIDs = Set(destinations.map(\.id))
        let existingRootFolderKeys = Set(
          destinations.filter { !$0.relativePath.contains("/") }
            .map { PathSafety.normalizedFolderKey($0.displayName) })
        let rawProposals = try await provider.classify(
          items: ambiguous,
          destinations: destinations
        )
        for raw in rawProposals
        where requestedItemIDs.contains(raw.itemID) && modelByItem[raw.itemID] == nil {
          guard
            let validated = Self.validateModelProposal(
              raw,
              allowedDestinationIDs: allowedDestinationIDs,
              existingRootFolderKeys: existingRootFolderKeys
            )
          else { continue }
          modelByItem[raw.itemID] = validated
        }
        if !Task.isCancelled {
          await progress(
            OrganizationProgress(
              phase: .aiClassifying,
              completed: ambiguous.count,
              total: ambiguous.count,
              isCancellable: true
            ))
        }
      } catch {
        modelStatus = "AI 已降级：\(error.localizedDescription)"
      }
    }

    for context in ambiguous {
      let candidates = candidatesByItem[context.id] ?? []
      if let model = modelByItem[context.id] {
        let decision =
          context.snapshot.isCloudPlaceholder
          ? ReviewDecision.needsReview
          : policy.evaluate(proposal: model, deterministicCandidates: candidates)
        final[context.id] = ClassificationProposal(
          sessionID: sessionID,
          itemID: context.id,
          action: model.action,
          destinationID: model.destinationID,
          suggestedFolderName: model.suggestedFolderName,
          source: .foundationModel,
          reviewDecision: decision,
          reason: model.reason,
          evidence: candidates.first?.evidence ?? []
        )
      } else if let deterministic = classifier.proposal(
        sessionID: sessionID,
        item: context,
        candidates: candidates
      ) {
        var fallback = deterministic
        fallback.reviewDecision = .needsReview
        final[context.id] = fallback
      } else {
        final[context.id] = ClassificationProposal(
          sessionID: sessionID,
          itemID: context.id,
          action: .keep,
          source: .deterministic,
          reviewDecision: .needsReview,
          reason: context.snapshot.isCloudPlaceholder ? "云端文件尚未下载" : "没有足够证据确定目标"
        )
      }
    }

    let proposals = items.compactMap { final[$0.id] }
    let folderProposals = Self.coalesceFolderProposals(sessionID: sessionID, proposals: proposals)
    return ClassificationPipelineResult(
      proposals: proposals, folderProposals: folderProposals, modelStatus: modelStatus)
  }

  public static func coalesceFolderProposals(
    sessionID: UUID,
    proposals: [ClassificationProposal]
  ) -> [FolderProposal] {
    let grouped = Dictionary(
      grouping: proposals.filter {
        $0.action == .suggestFolder && $0.suggestedFolderName != nil
      }
    ) { PathSafety.normalizedFolderKey($0.suggestedFolderName ?? "") }
    return grouped.keys.sorted().compactMap { key in
      guard !key.isEmpty, let values = grouped[key], let first = values.first,
        let display = first.suggestedFolderName
      else { return nil }
      return FolderProposal(
        sessionID: sessionID,
        normalizedName: key,
        displayName: display,
        relatedItemIDs: values.map(\.itemID)
      )
    }
  }

  private static func validateModelProposal(
    _ proposal: ModelProposal,
    allowedDestinationIDs: Set<UUID>,
    existingRootFolderKeys: Set<String>
  ) -> ModelProposal? {
    let reason = String(proposal.reason.prefix(240))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    switch proposal.action {
    case .move:
      guard let destinationID = proposal.destinationID,
        allowedDestinationIDs.contains(destinationID)
      else { return nil }
      return ModelProposal(
        itemID: proposal.itemID,
        action: .move,
        destinationID: destinationID,
        reason: reason
      )
    case .keep:
      return ModelProposal(itemID: proposal.itemID, action: .keep, reason: reason)
    case .suggestFolder:
      guard let rawName = proposal.suggestedFolderName,
        let name = try? PathSafety.validateFolderName(rawName),
        !existingRootFolderKeys.contains(PathSafety.normalizedFolderKey(name))
      else { return nil }
      return ModelProposal(
        itemID: proposal.itemID,
        action: .suggestFolder,
        suggestedFolderName: name,
        reason: reason
      )
    }
  }
}
