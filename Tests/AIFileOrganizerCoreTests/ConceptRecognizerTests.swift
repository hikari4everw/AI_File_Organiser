import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct ConceptRecognizerTests {
  @Test func oneItemCanConfirmMultipleIndependentConcepts() {
    let manga = FileConcept(name: "漫画")
    let translated = FileConcept(name: "中文译本")
    let features = ConceptFeatureSnapshot(
      modelVersion: "manual-only-v1", itemKind: .file, visualVector: [])
    let examples = [manga, translated].map {
      ConceptExample(
        conceptID: $0.id, itemIdentity: "resource:one",
        isPositive: true, features: features)
    }

    let result = ConceptRecognizer().recognize(
      itemIdentity: "resource:one", features: features,
      concepts: [manga, translated], examples: examples)

    #expect(result.status == .confirmed)
    #expect(result.confirmedConceptIDs == [manga.id, translated.id])
  }

  private let version = ConceptModelManager.modelVersion

  @Test func explicitLabelAndAncestorAreConfirmedWithoutDestination() {
    let parent = FileConcept(name: "课程资料")
    let child = FileConcept(name: "课程讲义", parentID: parent.id)
    let snapshot = ConceptFeatureSnapshot(
      modelVersion: version, itemKind: .file, visualVector: [1, 0])
    let example = ConceptExample(
      conceptID: child.id, itemIdentity: "item-a", isPositive: true, features: snapshot)

    let result = ConceptRecognizer().recognize(
      itemIdentity: "item-a", features: snapshot,
      concepts: [parent, child], examples: [example])

    #expect(result.status == .confirmed)
    #expect(result.confirmedConceptIDs == [parent.id, child.id])
  }

  @Test func similarUnlabeledFileOffersConfidentReviewableCandidate() {
    let manga = FileConcept(name: "漫画")
    let example = ConceptExample(
      conceptID: manga.id, itemIdentity: "example", isPositive: true,
      features: ConceptFeatureSnapshot(
        modelVersion: version, itemKind: .directory, visualVector: [1, 0]))
    let result = ConceptRecognizer().recognize(
      itemIdentity: "new-item",
      features: ConceptFeatureSnapshot(
        modelVersion: version, itemKind: .directory, visualVector: [0.98, 0.02]),
      concepts: [manga], examples: [example])

    #expect(result.status == .confident)
    #expect(result.confirmedConceptIDs.isEmpty)
    #expect(result.candidates.map(\.conceptID) == [manga.id])
    #expect(result.candidates.first?.supportingExampleIDs == [example.id])
  }

  @Test func calibratedVisualMatchNeedsMarginBeforeBecomingConfident() {
    let first = FileConcept(name: "漫画")
    let second = FileConcept(name: "同人志")
    let examples = [
      ConceptExample(
        conceptID: first.id, itemIdentity: "first", isPositive: true,
        features: ConceptFeatureSnapshot(
          modelVersion: version, itemKind: .directory, visualVector: [1, 0])),
      ConceptExample(
        conceptID: second.id, itemIdentity: "second", isPositive: true,
        features: ConceptFeatureSnapshot(
          modelVersion: version, itemKind: .directory, visualVector: [0.9999, 0.014])),
    ]

    let result = ConceptRecognizer().recognize(
      itemIdentity: "new", features: ConceptFeatureSnapshot(
        modelVersion: version, itemKind: .directory, visualVector: [1, 0]),
      concepts: [first, second], examples: examples)

    #expect(result.status == .needsReview)
  }

  @Test func textOnlySimilarityNeverUsesVisualConfidenceThreshold() {
    let concept = FileConcept(name: "讲义")
    let example = ConceptExample(
      conceptID: concept.id, itemIdentity: "example", isPositive: true,
      features: ConceptFeatureSnapshot(
        modelVersion: "none", itemKind: .file, visualVector: [],
        textModelVersion: "hashed-text-v1", textVector: [1, 0]))
    let result = ConceptRecognizer().recognize(
      itemIdentity: "new", features: ConceptFeatureSnapshot(
        modelVersion: "none", itemKind: .file, visualVector: [],
        textModelVersion: "hashed-text-v1", textVector: [1, 0]),
      concepts: [concept], examples: [example])

    #expect(result.status == .needsReview)
  }

  @Test func textNegativeCannotIncreaseVisualConfidenceMargin() {
    let first = FileConcept(name: "漫画")
    let second = FileConcept(name: "同人志")
    let examples = [
      ConceptExample(
        conceptID: first.id, itemIdentity: "first", isPositive: true,
        features: ConceptFeatureSnapshot(
          modelVersion: version, itemKind: .directory, visualVector: [0.8, 0.6])),
      ConceptExample(
        conceptID: second.id, itemIdentity: "second-positive", isPositive: true,
        features: ConceptFeatureSnapshot(
          modelVersion: version, itemKind: .directory, visualVector: [0.79, 0.613],
          textModelVersion: "hashed-text-v1", textVector: [0, 1])),
      ConceptExample(
        conceptID: second.id, itemIdentity: "second-negative", isPositive: false,
        features: ConceptFeatureSnapshot(
          modelVersion: version, itemKind: .directory, visualVector: [0, 1],
          textModelVersion: "hashed-text-v1", textVector: [1, 0])),
    ]
    let result = ConceptRecognizer().recognize(
      itemIdentity: "new", features: ConceptFeatureSnapshot(
        modelVersion: version, itemKind: .directory, visualVector: [1, 0],
        textModelVersion: "hashed-text-v1", textVector: [1, 0]),
      concepts: [first, second], examples: examples)

    #expect(result.status == .needsReview)
  }

  @Test func explicitNegativeExcludesConceptWithoutRejectingOtherLabels() {
    let comic = FileConcept(name: "漫画")
    let score = FileConcept(name: "钢琴谱")
    let features = ConceptFeatureSnapshot(
      modelVersion: version, itemKind: .file, visualVector: [1, 0])
    let examples = [
      ConceptExample(conceptID: comic.id, itemIdentity: "same-file", isPositive: false,
        features: features),
      ConceptExample(conceptID: score.id, itemIdentity: "same-file", isPositive: true,
        features: features),
    ]

    let result = ConceptRecognizer().recognize(
      itemIdentity: "same-file", features: features,
      concepts: [comic, score], examples: examples)

    #expect(result.confirmedConceptIDs == [score.id])
    #expect(!result.candidates.contains(where: { $0.conceptID == comic.id }))
  }

  @Test func incompatibleFeatureVersionNeverProducesCandidate() {
    let concept = FileConcept(name: "钢琴谱")
    let example = ConceptExample(
      conceptID: concept.id, itemIdentity: "old", isPositive: true,
      features: ConceptFeatureSnapshot(
        modelVersion: "old-model", itemKind: .file, visualVector: [1, 0]))

    let result = ConceptRecognizer().recognize(
      itemIdentity: "new", features: ConceptFeatureSnapshot(
        modelVersion: version, itemKind: .file, visualVector: [1, 0]),
      concepts: [concept], examples: [example])

    #expect(result.status == .unknown)
    #expect(result.candidates.isEmpty)
  }
}
