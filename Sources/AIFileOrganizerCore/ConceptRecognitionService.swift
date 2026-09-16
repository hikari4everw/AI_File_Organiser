import Foundation

public struct ConceptRecognitionService: Sendable {
  public init() {}

  public func recognize(
    items: [ItemSnapshot], concepts: [FileConcept], examples: [ConceptExample],
    provider: (any ImageEmbeddingProvider)?
  ) async -> [UUID: ConceptRecognitionResult] {
    guard !concepts.isEmpty else { return [:] }
    let extractor = provider.map { ConceptFeatureExtractor(provider: $0) }
    var results: [UUID: ConceptRecognitionResult] = [:]
    for item in items {
      if Task.isCancelled { break }
      var features = await ConceptTextFeatureExtractor().extract(item: item)
      if let visual = try? await extractor?.extract(item: item) {
        features.modelVersion = visual.modelVersion
        features.visualVector = visual.visualVector
      }
      let result = ConceptRecognizer().recognize(
        itemIdentity: ConceptIdentity.of(item), features: features,
        concepts: concepts, examples: examples)
      results[item.id] = result
    }
    return results
  }
}
