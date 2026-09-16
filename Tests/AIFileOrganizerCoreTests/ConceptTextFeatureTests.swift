import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct ConceptTextFeatureTests {
  @Test func oldVisualSnapshotDecodesWithoutTextFields() throws {
    let data = Data("""
      {"modelVersion":"old","itemKind":"file","visualVector":[1,0]}
      """.utf8)
    let snapshot = try JSONDecoder().decode(ConceptFeatureSnapshot.self, from: data)
    #expect(snapshot.textVector.isEmpty)
    #expect(snapshot.textModelVersion == nil)
  }

  @Test func similarTextCreatesReviewableCandidateWithoutImageModel() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let taughtURL = directory.appendingPathComponent("COMP2012 lecture 1.txt")
    let newURL = directory.appendingPathComponent("COMP2012 lecture 2.txt")
    try Data("Algorithms and data structures lecture notes".utf8).write(to: taughtURL)
    try Data("Algorithms and data structures lecture slides".utf8).write(to: newURL)
    let taught = ItemSnapshot(
      sessionID: UUID(), path: taughtURL.path, name: taughtURL.lastPathComponent,
      kind: .file, fileExtension: "txt")
    let incoming = ItemSnapshot(
      sessionID: UUID(), path: newURL.path, name: newURL.lastPathComponent,
      kind: .file, fileExtension: "txt")
    let textFeatures = ConceptTextFeatureExtractor()
    let taughtFeature = await textFeatures.extract(item: taught)
    #expect(!taughtFeature.textVector.isEmpty)
    let concept = FileConcept(name: "COMP2012 讲义")
    let example = ConceptExample(
      conceptID: concept.id, itemIdentity: ConceptIdentity.of(taught),
      isPositive: true, features: taughtFeature)

    let results = await ConceptRecognitionService().recognize(
      items: [incoming], concepts: [concept], examples: [example], provider: nil)
    #expect(results[incoming.id]?.status == .needsReview)
    #expect(results[incoming.id]?.candidates.first?.conceptID == concept.id)
    #expect(results[incoming.id]?.confirmedConceptIDs.isEmpty == true)
  }

  @Test func textFeatureVersionMismatchDoesNotSuggest() {
    let concept = FileConcept(name: "发票")
    let example = ConceptExample(
      conceptID: concept.id, itemIdentity: "a", isPositive: true,
      features: ConceptFeatureSnapshot(
        modelVersion: "manual-only-v1", itemKind: .file, visualVector: [],
        textModelVersion: "old", textVector: [1, 0]))
    let query = ConceptFeatureSnapshot(
      modelVersion: "manual-only-v1", itemKind: .file, visualVector: [],
      textModelVersion: "new", textVector: [1, 0])
    let result = ConceptRecognizer().recognize(
      itemIdentity: "b", features: query, concepts: [concept], examples: [example])
    #expect(result.candidates.isEmpty)
  }
}
