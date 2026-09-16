import Foundation
import Testing

@testable import AIFileOrganizerCore

private struct EmptyExtractor: ContentExtractor {
  func extractContext(for item: ItemSnapshot) async -> ExtractedContext { .init() }
}

private struct MockProvider: ClassificationProvider {
  let result: [ModelProposal]
  var availabilityDescription: String { "测试模型可用" }
  var isAvailable: Bool { true }
  func classify(items: [ItemContext], destinations: [DestinationProfile]) async throws
    -> [ModelProposal]
  { result }
}

private struct UnavailableProvider: ClassificationProvider {
  var availabilityDescription: String { "不可用" }
  var isAvailable: Bool { false }
  func classify(items: [ItemContext], destinations: [DestinationProfile]) async throws
    -> [ModelProposal]
  { [] }
}

private actor ProgressRecorder {
  private var values: [OrganizationProgress] = []

  func record(_ value: OrganizationProgress) { values.append(value) }
  func snapshot() -> [OrganizationProgress] { values }
}

@Suite struct ClassificationTests {
  @Test func conceptCandidateStillAllowsIndependentSemanticRuleToSuggestInReview() async {
    let session = UUID()
    let item = ItemSnapshot(
      sessionID: session, path: "/tmp/document.pdf", name: "document.pdf", kind: .file)
    let concept = FileConcept(name: "账单")
    let destination = DestinationProfile(
      relativePath: "Finance", displayName: "Finance", keywords: [])
    let semantic = OrganizationRule(
      workspaceID: UUID(), originalText: "财务材料放 Finance",
      condition: RuleCondition(semanticDescription: "财务材料"),
      destinationID: destination.id)
    let recognition = ConceptRecognitionResult(
      itemIdentity: item.path, status: .needsReview,
      confirmedConceptIDs: [], candidates: [ConceptCandidate(
        conceptID: concept.id, similarity: 0.8, supportingExampleIDs: [])])
    let provider = MockProvider(result: [ModelProposal(
      itemID: item.id, action: .move, destinationID: destination.id,
      reason: "匹配独立语义规则")])
    let result = await ClassificationPipeline(
      extractor: EmptyExtractor(), provider: provider
    ).run(
      sessionID: session, items: [item], destinations: [destination],
      rules: [semantic], concepts: [concept],
      recognitionByItem: [item.id: recognition])
    #expect(result.proposals.first?.destinationID == destination.id)
    #expect(result.proposals.first?.reviewDecision == .needsReview)
  }

  @Test func taughtConceptRoutesOnlyThroughItsRule() async {
    let session = UUID()
    let item = ItemSnapshot(
      sessionID: session, path: "/tmp/lecture.pdf", name: "lecture.pdf", kind: .file)
    let concept = FileConcept(name: "讲义")
    let destination = DestinationProfile(
      relativePath: "Study", displayName: "Study", keywords: [])
    let route = OrganizationRule(
      workspaceID: UUID(), originalText: "讲义放 Study",
      condition: RuleCondition(conceptID: concept.id), destinationID: destination.id)
    let recognition = ConceptRecognitionResult(
      itemIdentity: item.path, status: .confirmed,
      confirmedConceptIDs: [concept.id], candidates: [])
    let result = await ClassificationPipeline(
      extractor: EmptyExtractor(), provider: UnavailableProvider()
    ).run(
      sessionID: session, items: [item], destinations: [destination],
      rules: [route], concepts: [concept], recognitionByItem: [item.id: recognition])
    #expect(result.proposals.first?.destinationID == destination.id)
    #expect(result.proposals.first?.reviewDecision == .ready)
  }

  @Test func knownConceptWithoutRouteWaitsForReview() async {
    let session = UUID()
    let item = ItemSnapshot(
      sessionID: session, path: "/tmp/lecture.pdf", name: "lecture.pdf", kind: .file)
    let concept = FileConcept(name: "讲义")
    let destination = DestinationProfile(
      relativePath: "Study", displayName: "Study", keywords: ["lecture", "pdf"])
    let recognition = ConceptRecognitionResult(
      itemIdentity: item.path, status: .confirmed,
      confirmedConceptIDs: [concept.id], candidates: [])
    let result = await ClassificationPipeline(
      extractor: EmptyExtractor(), provider: UnavailableProvider()
    ).run(
      sessionID: session, items: [item], destinations: [destination],
      concepts: [concept], recognitionByItem: [item.id: recognition])
    #expect(result.proposals.first?.action == .keep)
    #expect(result.proposals.first?.reviewDecision == .needsReview)
    #expect(result.proposals.first?.destinationID == nil)
  }

  @Test func deterministicImageClassificationIsReady() {
    let session = UUID()
    let item = ItemSnapshot(
      sessionID: session, path: "/tmp/photo.jpg", name: "photo.jpg",
      kind: .file, contentType: "public.jpeg", fileExtension: "jpg"
    )
    let destination = DestinationProfile(relativePath: "图片", displayName: "图片", keywords: ["图片"])
    let classifier = DeterministicClassifier()
    let context = classifier.context(for: item)
    let ranked = classifier.rank(context, destinations: [destination])
    #expect(ranked.first?.destinationID == destination.id)
    #expect(
      classifier.proposal(sessionID: session, item: context, candidates: ranked)?.reviewDecision
        == .ready)
  }

  @Test func modelSuggestionMustRemainInReview() async {
    let session = UUID()
    let item = ItemSnapshot(
      sessionID: session, path: "/tmp/x.unknown", name: "x.unknown", kind: .file)
    let provider = MockProvider(result: [
      ModelProposal(
        itemID: item.id, action: .suggestFolder, suggestedFolderName: "研究", reason: "研究资料")
    ])
    let pipeline = ClassificationPipeline(extractor: EmptyExtractor(), provider: provider)
    let result = await pipeline.run(
      sessionID: session, items: [item],
      destinations: [
        DestinationProfile(relativePath: "文档", displayName: "文档")
      ])
    #expect(result.proposals.first?.reviewDecision == .needsReview)
    #expect(result.folderProposals.first?.displayName == "研究")
  }

  @Test func unavailableModelFallsBackToNeedsReview() async {
    let session = UUID()
    let item = ItemSnapshot(
      sessionID: session, path: "/tmp/mystery.bin", name: "mystery.bin", kind: .file)
    let pipeline = ClassificationPipeline(
      extractor: EmptyExtractor(), provider: UnavailableProvider())
    let result = await pipeline.run(sessionID: session, items: [item], destinations: [])
    #expect(result.proposals.first?.reviewDecision == .needsReview)
    #expect(result.proposals.first?.action == .keep)
  }

  @Test func reportsRealAnalysisAndAIProgress() async {
    let session = UUID()
    let item = ItemSnapshot(
      sessionID: session, path: "/tmp/mystery.bin", name: "mystery.bin", kind: .file)
    let provider = MockProvider(result: [
      ModelProposal(itemID: item.id, action: .keep, reason: "test")
    ])
    let recorder = ProgressRecorder()

    _ = await ClassificationPipeline(extractor: EmptyExtractor(), provider: provider).run(
      sessionID: session,
      items: [item],
      destinations: [],
      progress: { value in await recorder.record(value) }
    )

    let values = await recorder.snapshot()
    let analysis = values.filter { $0.phase == .analyzing }
    let ai = values.filter { $0.phase == .aiClassifying }
    #expect(analysis.map(\.completed) == [0, 1])
    #expect(analysis.allSatisfy { $0.total == 1 })
    #expect(ai.first?.isIndeterminate == true)
    #expect(ai.first?.total == 1)
    #expect(ai.last?.completed == 1)
    #expect(ai.last?.isIndeterminate == false)
  }

  @Test func unavailableModelDoesNotReportFakeAIProgress() async {
    let session = UUID()
    let item = ItemSnapshot(
      sessionID: session, path: "/tmp/mystery.bin", name: "mystery.bin", kind: .file)
    let recorder = ProgressRecorder()

    _ = await ClassificationPipeline(
      extractor: EmptyExtractor(), provider: UnavailableProvider()
    ).run(
      sessionID: session,
      items: [item],
      destinations: [],
      progress: { value in await recorder.record(value) }
    )

    let values = await recorder.snapshot()
    #expect(values.contains { $0.phase == .analyzing })
    #expect(!values.contains { $0.phase == .aiClassifying })
  }

  @Test func invalidModelOutputIsRejectedAtPipelineBoundary() async {
    let session = UUID()
    let item = ItemSnapshot(
      sessionID: session, path: "/tmp/mystery.bin", name: "mystery.bin", kind: .file)
    let provider = MockProvider(result: [
      ModelProposal(
        itemID: item.id, action: .move, destinationID: UUID(), reason: "invented destination"),
      ModelProposal(
        itemID: item.id, action: .suggestFolder, suggestedFolderName: "../escape", reason: "bad"),
    ])
    let result = await ClassificationPipeline(extractor: EmptyExtractor(), provider: provider).run(
      sessionID: session,
      items: [item],
      destinations: [DestinationProfile(relativePath: "文档", displayName: "文档")]
    )
    #expect(result.folderProposals.isEmpty)
    #expect(result.proposals.first?.destinationID == nil)
    #expect(result.proposals.first?.reviewDecision == .needsReview)
  }

  @Test func folderSuggestionsAreCoalescedCaseInsensitively() {
    let session = UUID()
    let values = ["Research", "research"].map {
      ClassificationProposal(
        sessionID: session, itemID: UUID(), action: .suggestFolder,
        suggestedFolderName: $0, source: .foundationModel,
        reviewDecision: .needsReview, reason: "test"
      )
    }
    let result = ClassificationPipeline.coalesceFolderProposals(
      sessionID: session, proposals: values)
    #expect(result.count == 1)
    #expect(result.first?.relatedItemIDs.count == 2)
  }
}
