import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct ConceptStoreTests {
  @Test func explicitExamplesSurviveRestartWithoutSourceFile() throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).sqlite").path
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }
    let concept = FileConcept(name: "钢琴谱", description: "用于钢琴演奏的乐谱")
    let feature = ConceptFeatureSnapshot(
      modelVersion: "test-model", itemKind: .file, visualVector: [0.2, 0.8])
    let example = ConceptExample(
      conceptID: concept.id, itemIdentity: "resource:missing-after-move",
      isPositive: true, features: feature)

    do {
      let store = ConceptStore(database: try AppDatabase(path: path))
      try store.save(concept)
      try store.teach(example)
    }
    let reloaded = ConceptStore(database: try AppDatabase(path: path))
    #expect(try reloaded.concepts() == [concept])
    #expect(try reloaded.examples(conceptID: concept.id) == [example])
  }

  @Test func correctingOneLabelReplacesItsPriorEvidence() throws {
    let store = ConceptStore(database: try AppDatabase.inMemory())
    let concept = FileConcept(name: "漫画")
    try store.save(concept)
    let feature = ConceptFeatureSnapshot(
      modelVersion: "test-model", itemKind: .directory, visualVector: [0.8, 0.2])
    let positive = ConceptExample(
      conceptID: concept.id, itemIdentity: "resource:one", isPositive: true,
      features: feature)
    try store.teach(positive)
    try store.teach(ConceptExample(
      conceptID: concept.id, itemIdentity: "resource:one", isPositive: false,
      features: feature))

    let evidence = try store.examples(conceptID: concept.id)
    #expect(evidence.count == 1)
    #expect(evidence.first?.isPositive == false)
    #expect(evidence.first?.features == feature)
  }

  @Test func conceptParentCannotFormCycle() throws {
    let store = ConceptStore(database: try AppDatabase.inMemory())
    let parent = FileConcept(name: "课程资料")
    let child = FileConcept(name: "课程讲义", parentID: parent.id)
    try store.save(parent)
    try store.save(child)
    var changed = parent
    changed.parentID = child.id

    #expect(throws: OrganizerError.self) { try store.save(changed) }
    #expect(try store.concepts().first(where: { $0.id == parent.id })?.parentID == nil)
  }

  @Test func deletingConceptRemovesExamplesAndDetachesChildren() throws {
    let database = try AppDatabase.inMemory()
    let store = ConceptStore(database: database)
    let parent = FileConcept(name: "漫画")
    let child = FileConcept(name: "普通漫画", parentID: parent.id)
    try store.save(parent)
    try store.save(child)
    try store.teach(ConceptExample(
      conceptID: parent.id, itemIdentity: "resource:one", isPositive: true,
      features: ConceptFeatureSnapshot(
        modelVersion: "test-model", itemKind: .directory, visualVector: [1, 0])))

    try store.delete(parent.id)

    #expect(try store.concepts() == [FileConcept(
      id: child.id, name: child.name, parentID: nil, createdAt: child.createdAt)])
    #expect(try store.examples(conceptID: parent.id).isEmpty)
  }
}
