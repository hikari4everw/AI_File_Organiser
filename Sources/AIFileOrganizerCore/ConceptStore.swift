import Foundation

public struct ConceptStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) { self.database = database }

  public func concepts() throws -> [FileConcept] { try database.concepts() }

  public func examples(conceptID: UUID) throws -> [ConceptExample] {
    try database.conceptExamples(conceptID: conceptID)
  }

  public func save(_ concept: FileConcept) throws {
    let name = concept.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw OrganizerError.persistenceFailed("概念名称不能为空") }
    let existing = try concepts()
    let normalized = RuleCondition.normalize(name)
    guard !existing.contains(where: {
      $0.id != concept.id && RuleCondition.normalize($0.name) == normalized
    }) else { throw OrganizerError.persistenceFailed("概念名称已存在") }
    let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    var visited: Set<UUID> = [concept.id]
    var ancestorID = concept.parentID
    while let id = ancestorID {
      guard !visited.contains(id), let parent = byID[id] else {
        throw OrganizerError.persistenceFailed("概念上级无效或形成循环")
      }
      visited.insert(id)
      ancestorID = parent.parentID
    }
    var cleaned = concept
    cleaned.name = name
    cleaned.description = concept.description.trimmingCharacters(in: .whitespacesAndNewlines)
    cleaned.aliases = Array(Set(concept.aliases.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty })).sorted()
    try database.saveConcept(cleaned)
  }

  public func teach(_ example: ConceptExample) throws {
    guard try concepts().contains(where: { $0.id == example.conceptID }) else {
      throw OrganizerError.persistenceFailed("概念不存在")
    }
    guard !example.itemIdentity.isEmpty, !example.features.modelVersion.isEmpty,
      (!example.features.visualVector.isEmpty
        || !example.features.textVector.isEmpty
        || example.features.modelVersion == "manual-only-v1"),
      example.features.visualVector.allSatisfy(\.isFinite),
      example.features.textVector.allSatisfy(\.isFinite),
      (example.features.textVector.isEmpty || example.features.textModelVersion != nil)
    else { throw OrganizerError.persistenceFailed("样本特征无效") }
    try database.saveConceptExample(example)
  }

  public func retract(_ exampleID: UUID) throws { try database.deleteConceptExample(exampleID) }

  public func delete(_ conceptID: UUID) throws { try database.deleteConcept(conceptID) }
}
