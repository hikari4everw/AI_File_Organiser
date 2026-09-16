import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct ConceptRecognizerTests {
  private let version = "test-encoder-v1"

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

  @Test func similarUnlabeledFileOffersReviewableCandidateOnly() {
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

    #expect(result.status == .needsReview)
    #expect(result.confirmedConceptIDs.isEmpty)
    #expect(result.candidates.map(\.conceptID) == [manga.id])
    #expect(result.candidates.first?.supportingExampleIDs == [example.id])
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
