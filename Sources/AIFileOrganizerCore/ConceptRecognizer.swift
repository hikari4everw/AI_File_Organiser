import Foundation

public enum ConceptRecognitionStatus: String, Codable, Hashable, Sendable {
  case confirmed, needsReview, unknown
}

public struct ConceptCandidate: Codable, Hashable, Sendable {
  public var conceptID: UUID
  public var similarity: Float
  public var supportingExampleIDs: [UUID]

  public init(conceptID: UUID, similarity: Float, supportingExampleIDs: [UUID]) {
    self.conceptID = conceptID
    self.similarity = similarity
    self.supportingExampleIDs = supportingExampleIDs
  }
}

public struct ConceptRecognitionResult: Codable, Hashable, Sendable {
  public var itemIdentity: String
  public var status: ConceptRecognitionStatus
  public var confirmedConceptIDs: Set<UUID>
  public var candidates: [ConceptCandidate]

  public init(
    itemIdentity: String, status: ConceptRecognitionStatus,
    confirmedConceptIDs: Set<UUID>, candidates: [ConceptCandidate]
  ) {
    self.itemIdentity = itemIdentity
    self.status = status
    self.confirmedConceptIDs = confirmedConceptIDs
    self.candidates = candidates
  }
}

public struct ConceptRecognizer: Sendable {
  public init() {}

  public func recognize(
    itemIdentity: String, features: ConceptFeatureSnapshot,
    concepts: [FileConcept], examples: [ConceptExample]
  ) -> ConceptRecognitionResult {
    let byID = Dictionary(uniqueKeysWithValues: concepts.map { ($0.id, $0) })
    let knownIDs = Set(byID.keys)
    let exact = examples.filter { $0.itemIdentity == itemIdentity && knownIDs.contains($0.conceptID) }
    let negatives = Set(exact.filter { !$0.isPositive }.map(\.conceptID))
    var confirmed = Set(exact.filter { $0.isPositive }.map(\.conceptID)).subtracting(negatives)
    for id in Array(confirmed) {
      var ancestorID = byID[id]?.parentID
      var visited: Set<UUID> = [id]
      while let ancestor = ancestorID, !visited.contains(ancestor),
        let concept = byID[ancestor]
      {
        visited.insert(ancestor)
        if !negatives.contains(ancestor) { confirmed.insert(ancestor) }
        ancestorID = concept.parentID
      }
    }

    var candidates: [ConceptCandidate] = []
    if let query = Self.normalized(features.visualVector) {
      for concept in concepts where !negatives.contains(concept.id)
        && !confirmed.contains(concept.id)
      {
        let relevant = examples.filter {
          $0.conceptID == concept.id && $0.features.modelVersion == features.modelVersion
        }
        var positives: [(UUID, Float)] = []
        var negativeScore: Float = -1
        for example in relevant {
          guard let vector = Self.normalized(example.features.visualVector),
            vector.count == query.count else { continue }
          let score = Self.similarity(query, vector)
          if example.isPositive {
            positives.append((example.id, score))
          } else {
            negativeScore = max(negativeScore, score)
          }
        }
        positives.sort { lhs, rhs in
          lhs.1 == rhs.1 ? lhs.0.uuidString < rhs.0.uuidString : lhs.1 > rhs.1
        }
        let best = Array(positives.prefix(3))
        guard !best.isEmpty else { continue }
        let score = best.reduce(Float(0)) { $0 + $1.1 } / Float(best.count)
        guard score > 0, score > negativeScore else { continue }
        candidates.append(ConceptCandidate(
          conceptID: concept.id, similarity: score,
          supportingExampleIDs: best.map(\.0)))
      }
    }
    candidates.sort { lhs, rhs in
      lhs.similarity == rhs.similarity
        ? lhs.conceptID.uuidString < rhs.conceptID.uuidString
        : lhs.similarity > rhs.similarity
    }
    let status: ConceptRecognitionStatus = !confirmed.isEmpty ? .confirmed
      : (candidates.isEmpty ? .unknown : .needsReview)
    return ConceptRecognitionResult(
      itemIdentity: itemIdentity, status: status,
      confirmedConceptIDs: confirmed, candidates: candidates)
  }

  private static func normalized(_ vector: [Float]) -> [Float]? {
    guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
    let length = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
    guard length > 0 else { return nil }
    return vector.map { $0 / length }
  }

  private static func similarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
    zip(lhs, rhs).reduce(Float(0)) { $0 + $1.0 * $1.1 }
  }
}
