import Foundation

public struct ClassificationPipelineResult: Sendable {
  public var proposals: [ClassificationProposal]
  public var folderProposals: [FolderProposal]
  public var modelStatus: String
  public var contextsByItem: [UUID: ItemContext]
  public var recognitionByItem: [UUID: ConceptRecognitionResult]

  public init(
    proposals: [ClassificationProposal], folderProposals: [FolderProposal], modelStatus: String,
    contextsByItem: [UUID: ItemContext] = [:],
    recognitionByItem: [UUID: ConceptRecognitionResult] = [:]
  ) {
    self.proposals = proposals
    self.folderProposals = folderProposals
    self.modelStatus = modelStatus
    self.contextsByItem = contextsByItem
    self.recognitionByItem = recognitionByItem
  }
}

public struct ClassificationPipeline: Sendable {
  private let classifier: DeterministicClassifier
  private let extractor: any ContentExtractor
  private let provider: any ClassificationProvider
  private let policy: any DecisionPolicy
  private let directoryAnalyzer: DirectoryAnalyzer

  public init(
    classifier: DeterministicClassifier = .init(),
    extractor: any ContentExtractor = NativeContentExtractor(),
    provider: any ClassificationProvider = AppleFoundationModelProvider(),
    policy: any DecisionPolicy = DefaultDecisionPolicy(),
    directoryAnalyzer: DirectoryAnalyzer = .init()
  ) {
    self.classifier = classifier
    self.extractor = extractor
    self.provider = provider
    self.policy = policy
    self.directoryAnalyzer = directoryAnalyzer
  }

  public func run(
    sessionID: UUID,
    items: [ItemSnapshot],
    destinations: [DestinationProfile],
    rules: [OrganizationRule] = [],
    concepts: [FileConcept] = [],
    recognitionByItem: [UUID: ConceptRecognitionResult] = [:],
    catalog: CatalogAnalysisResult? = nil,
    creatorResolutions: [UUID: CreatorResolution] = [:]
  ) async -> ClassificationPipelineResult {
    await run(
      sessionID: sessionID,
      items: items,
      destinations: destinations,
      rules: rules,
      concepts: concepts,
      recognitionByItem: recognitionByItem,
      catalog: catalog,
      creatorResolutions: creatorResolutions,
      progress: { _ in }
    )
  }

  public func run(
    sessionID: UUID,
    items: [ItemSnapshot],
    destinations: [DestinationProfile],
    rules: [OrganizationRule] = [],
    concepts: [FileConcept] = [],
    recognitionByItem: [UUID: ConceptRecognitionResult] = [:],
    catalog: CatalogAnalysisResult? = nil,
    creatorResolutions: [UUID: CreatorResolution] = [:],
    progress: @escaping OrganizationProgressHandler
  ) async -> ClassificationPipelineResult {
    var final: [UUID: ClassificationProposal] = [:]
    var candidatesByItem: [UUID: [RankedCandidate]] = [:]
    var ambiguous: [ItemContext] = []
    var contextsByItem: [UUID: ItemContext] = [:]
    let validDestinationIDs = Set(destinations.filter { $0.kind == .category }.map(\.id))
    let ruleEngine = RuleEngine()
    let featureExtractor: ConceptFeatureExtractor? =
      catalog?.workAnalyses.contains(where: { !$0.visualVector.isEmpty }) == true
      ? (try? ConceptModelManager().provider()).map(ConceptFeatureExtractor.init(provider:))
      : nil

    if !Task.isCancelled {
      await progress(
        OrganizationProgress(phase: .analyzing, total: items.count, isCancellable: true))
    }
    for (index, item) in items.enumerated() {
      if Task.isCancelled { break }
      let basic = classifier.context(for: item)
      contextsByItem[item.id] = basic
      let recognition = recognitionByItem[item.id]
      let basicRule = ruleEngine.evaluate(
        item: basic, rules: rules, recognition: recognition, concepts: concepts)
      if case .matchedMove(let ruleID, let destinationID) = basicRule,
        validDestinationIDs.contains(destinationID)
      {
        final[item.id] = Self.ruleProposal(
          sessionID: sessionID, itemID: item.id, ruleID: ruleID,
          destinationID: destinationID)
        if !Task.isCancelled {
          await progress(.init(phase: .analyzing, completed: index + 1, total: items.count,
            isCancellable: true))
        }
        continue
      }
      if case .matchedKeep(let ruleID) = basicRule {
        final[item.id] = Self.ruleKeepProposal(
          sessionID: sessionID, itemID: item.id, ruleID: ruleID)
        if !Task.isCancelled {
          await progress(.init(phase: .analyzing, completed: index + 1, total: items.count,
            isCancellable: true))
        }
        continue
      }
      if case .conflict(let ruleIDs) = basicRule {
        final[item.id] = Self.ruleConflictProposal(
          sessionID: sessionID, itemID: item.id, ruleIDs: ruleIDs)
        if !Task.isCancelled {
          await progress(.init(phase: .analyzing, completed: index + 1, total: items.count,
            isCancellable: true))
        }
        continue
      }
      let candidates = classifier.rank(basic, destinations: destinations, catalog: catalog)
      candidatesByItem[item.id] = candidates
      if (recognition?.status == .unknown || recognition == nil) && !(catalog != nil && item.kind == .file),
        let proposal = classifier.proposal(
        sessionID: sessionID, item: basic, candidates: candidates),
        proposal.reviewDecision == .ready
      {
        final[item.id] = proposal
      } else {
        let extracted = await extractor.extractContext(for: item)
        let summary = item.kind == .directory
          ? await directoryAnalyzer.analyze(URL(fileURLWithPath: item.path, isDirectory: true))
          : nil
        var enriched = classifier.context(
          for: item,
          extracted: extracted,
          directorySummary: summary
        )
        contextsByItem[item.id] = enriched
        let enrichedRule = ruleEngine.evaluate(
          item: enriched, rules: rules, recognition: recognition, concepts: concepts)
        if case .matchedMove(let ruleID, let destinationID) = enrichedRule,
          validDestinationIDs.contains(destinationID)
        {
          final[item.id] = Self.ruleProposal(
            sessionID: sessionID, itemID: item.id, ruleID: ruleID,
            destinationID: destinationID)
          if !Task.isCancelled {
            await progress(.init(phase: .analyzing, completed: index + 1, total: items.count,
              isCancellable: true))
          }
          continue
        }
        if case .matchedKeep(let ruleID) = enrichedRule {
          final[item.id] = Self.ruleKeepProposal(
            sessionID: sessionID, itemID: item.id, ruleID: ruleID)
          if !Task.isCancelled {
            await progress(.init(phase: .analyzing, completed: index + 1, total: items.count,
              isCancellable: true))
          }
          continue
        }
        if case .conflict(let ruleIDs) = enrichedRule {
          final[item.id] = Self.ruleConflictProposal(
            sessionID: sessionID, itemID: item.id, ruleIDs: ruleIDs)
          if !Task.isCancelled {
            await progress(.init(phase: .analyzing, completed: index + 1, total: items.count,
              isCancellable: true))
          }
          continue
        }
        let hasSemanticRule: Bool
        if case .semanticCandidates = enrichedRule { hasSemanticRule = true }
        else { hasSemanticRule = false }
        if let recognition, recognition.status != .unknown, !hasSemanticRule {
          let reason = recognition.confirmedConceptIDs.isEmpty
            ? "找到相似概念，请先确认文件类型和目标"
            : "已识别文件概念，但没有适用的整理规则，请选择目标"
          final[item.id] = ClassificationProposal(
            sessionID: sessionID, itemID: item.id, action: .keep,
            source: .user, reviewDecision: .needsReview, reason: reason)
          if !Task.isCancelled {
            await progress(.init(phase: .analyzing, completed: index + 1,
              total: items.count, isCancellable: true))
          }
          continue
        }
        if case .semanticCandidates(let ruleIDs) = enrichedRule {
          let selected = rules.filter { ruleIDs.contains($0.id) }
          enriched.ruleHints = selected.compactMap { rule in
            guard let meaning = rule.condition.semanticDescription else { return nil }
            switch rule.action {
            case .move:
              guard let destinationID = rule.destinationID else { return nil }
              return "\(meaning) => action=move destinationID=\(destinationID.uuidString)"
            case .keep:
              return "\(meaning) => action=keep"
            }
          }
        }
        let visualVector = (try? await featureExtractor?.extract(item: item))?.visualVector ?? []
        let reranked = classifier.rank(enriched, destinations: destinations, catalog: catalog,
          visualVector: visualVector)
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
            || recognitionByItem[context.id]?.status == .needsReview
            || recognitionByItem[context.id]?.status == .confident
            || recognitionByItem[context.id]?.status == .confirmed
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

    let destinationsByID = Dictionary(uniqueKeysWithValues: destinations.map { ($0.id, $0) })
    let proposals = items.compactMap { item -> ClassificationProposal? in
      guard var proposal = final[item.id] else { return nil }
      proposal.topCandidates = Array((candidatesByItem[item.id] ?? []).prefix(3))
      proposal.catalogRevision = catalog?.revision
      guard proposal.action == .move,
        !((proposal.status == .overridden || proposal.status == .approved) && proposal.source == .user),
        let destinationID = proposal.destinationID,
        let category = destinationsByID[destinationID]
      else { return proposal }
      switch creatorResolutions[item.id] {
      case .confirmed(let creator):
        proposal.creatorID = creator.id
        if let bound = creator.preferredDestinations[category.relativePath],
          bound.hasPrefix(category.relativePath + "/"),
          !bound.dropFirst(category.relativePath.count + 1).contains("/")
        {
          proposal.creatorDestinationPath = bound
          proposal.evidence.append(Evidence(kind: "creator",
            detail: "已确认作者及其现有目录", weight: 1))
        } else if let name = try? PathSafety.validateFolderName(creator.proposedDirectoryName) {
          proposal.suggestedFolderName = name
          proposal.reviewDecision = .needsReview
          proposal.evidence.append(Evidence(kind: "creator",
            detail: "已确认作者，需审核新作者目录", weight: 1))
        }
      case .candidates, .ambiguous:
        proposal.reviewDecision = .needsReview
        proposal.evidence.append(Evidence(kind: "creator",
          detail: "作者身份有歧义，请人工确认", weight: 0))
      case .unknown, nil:
        break
      }
      return proposal
    }
    let folderProposals = Self.coalesceFolderProposals(sessionID: sessionID, proposals: proposals)
    return ClassificationPipelineResult(
      proposals: proposals, folderProposals: folderProposals, modelStatus: modelStatus,
      contextsByItem: contextsByItem, recognitionByItem: recognitionByItem)
  }

  private static func ruleProposal(
    sessionID: UUID, itemID: UUID, ruleID: UUID, destinationID: UUID
  ) -> ClassificationProposal {
    ClassificationProposal(
      sessionID: sessionID, itemID: itemID, action: .move,
      destinationID: destinationID, source: .user, reviewDecision: .ready,
      reason: "匹配用户规则", evidence: [
        Evidence(kind: "rule", detail: ruleID.uuidString, weight: 1)
      ])
  }

  private static func ruleKeepProposal(
    sessionID: UUID, itemID: UUID, ruleID: UUID
  ) -> ClassificationProposal {
    ClassificationProposal(
      sessionID: sessionID, itemID: itemID, action: .keep,
      source: .user, reviewDecision: .keep,
      reason: "匹配用户保留规则", evidence: [
        Evidence(kind: "rule", detail: ruleID.uuidString, weight: 1)
      ])
  }

  private static func ruleConflictProposal(
    sessionID: UUID, itemID: UUID, ruleIDs: [UUID]
  ) -> ClassificationProposal {
    ClassificationProposal(
      sessionID: sessionID, itemID: itemID, action: .keep,
      source: .user, reviewDecision: .needsReview,
      reason: "同时匹配了多个目标不同的规则，请手动选择",
      evidence: ruleIDs.map { Evidence(kind: "rule-conflict", detail: $0.uuidString, weight: 1) }
    )
  }

  public static func coalesceFolderProposals(
    sessionID: UUID,
    proposals: [ClassificationProposal]
  ) -> [FolderProposal] {
    let grouped = Dictionary(
      grouping: proposals.filter {
        ($0.action == .suggestFolder || $0.action == .move)
          && $0.suggestedFolderName != nil
      }
    ) { proposal in
      let parent = proposal.action == .move ? proposal.destinationID?.uuidString ?? "missing" : "root"
      return parent + ":" + PathSafety.normalizedFolderKey(proposal.suggestedFolderName ?? "")
    }
    return grouped.keys.sorted().compactMap { key in
      guard !key.isEmpty, let values = grouped[key], let first = values.first,
        let display = first.suggestedFolderName
      else { return nil }
      return FolderProposal(
        sessionID: sessionID,
        normalizedName: PathSafety.normalizedFolderKey(display),
        displayName: display,
        relatedItemIDs: values.map(\.itemID),
        parentDestinationID: first.action == .move ? first.destinationID : nil
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
