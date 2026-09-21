import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct ConceptStoreTests {
  @Test func manualExampleConfirmsSameItemWithoutModel() throws {
    let store = ConceptStore(database: try AppDatabase.inMemory())
    let concept = FileConcept(name: "银行账单")
    try store.save(concept)
    let snapshot = ItemSnapshot(
      sessionID: UUID(), path: "/tmp/statement.pdf", name: "statement.pdf",
      kind: .file, resourceIdentifier: "123", volumeIdentifier: "disk")
    let identity = ConceptIdentity.of(snapshot)
    try store.teach(ConceptExample(
      conceptID: concept.id, itemIdentity: identity, isPositive: true,
      features: ConceptFeatureSnapshot(
        modelVersion: "manual-only-v1", itemKind: .file, visualVector: [])))
    let result = ConceptRecognizer().recognize(
      itemIdentity: identity,
      features: ConceptFeatureSnapshot(
        modelVersion: "manual-only-v1", itemKind: .file, visualVector: []),
      concepts: [concept], examples: try store.examples(conceptID: concept.id))
    #expect(result.confirmedConceptIDs == [concept.id])
  }

  @Test func deletingConceptDisablesReferencingRules() throws {
    let database = try AppDatabase.inMemory()
    let store = ConceptStore(database: database)
    let workspaceID = UUID()
    let concept = FileConcept(name: "发票")
    try store.save(concept)
    let move = OrganizationRule(
      workspaceID: workspaceID, originalText: "发票放 Finance",
      condition: RuleCondition(conceptID: concept.id), destinationID: UUID())
    let naming = NamingRule(
      workspaceID: workspaceID, originalText: "发票加前缀",
      condition: RuleCondition(conceptID: concept.id),
      operations: [.removeLiteralPrefix("x")])
    try database.saveRule(move)
    try database.saveNamingRule(naming)

    try store.delete(concept.id)

    #expect(try database.rules(workspaceID: workspaceID).first?.isEnabled == false)
    #expect(try database.namingRules(workspaceID: workspaceID).first?.isEnabled == false)
  }

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

  @Test func replacingLabelRejectsOldConceptAndConfirmsNewConcept() throws {
    let store = ConceptStore(database: try AppDatabase.inMemory())
    let oldConcept = FileConcept(name: "课程讲义")
    let newConcept = FileConcept(name: "课程作业")
    try store.save(oldConcept)
    try store.save(newConcept)
    let feature = ConceptFeatureSnapshot(
      modelVersion: "manual-only-v1", itemKind: .file, visualVector: [])
    try store.teach(ConceptExample(
      conceptID: oldConcept.id, itemIdentity: "resource:one",
      isPositive: true, features: feature))

    try store.replaceLabel(
      itemIdentity: "resource:one", features: feature,
      from: oldConcept.id, to: newConcept.id)

    #expect(try store.examples(conceptID: oldConcept.id).first?.isPositive == false)
    #expect(try store.examples(conceptID: newConcept.id).first?.isPositive == true)
    let allExamples = try [oldConcept, newConcept].flatMap {
      try store.examples(conceptID: $0.id)
    }
    let result = ConceptRecognizer().recognize(
      itemIdentity: "resource:one", features: feature,
      concepts: [oldConcept, newConcept], examples: allExamples)
    #expect(result.confirmedConceptIDs == [newConcept.id])
  }

  @Test func retractingExampleRemovesSavedEvidence() throws {
    let store = ConceptStore(database: try AppDatabase.inMemory())
    let concept = FileConcept(name: "银行账单")
    try store.save(concept)
    let example = ConceptExample(
      conceptID: concept.id, itemIdentity: "resource:one", isPositive: true,
      features: ConceptFeatureSnapshot(
        modelVersion: "manual-only-v1", itemKind: .file, visualVector: []))
    try store.teach(example)

    try store.retract(example.id)

    #expect(try store.examples(conceptID: concept.id).isEmpty)
  }

  @Test func conceptsAreGlobalWhileRoutesRemainWorkspaceScoped() throws {
    let database = try AppDatabase.inMemory()
    let store = ConceptStore(database: database)
    let concept = FileConcept(name: "论文")
    try store.save(concept)
    let firstWorkspaceID = UUID()
    let secondWorkspaceID = UUID()
    try database.saveRule(OrganizationRule(
      workspaceID: firstWorkspaceID, originalText: "论文放 Research",
      condition: RuleCondition(conceptID: concept.id), destinationID: UUID()))

    #expect(try store.concepts() == [concept])
    #expect(try database.rules(workspaceID: firstWorkspaceID).count == 1)
    #expect(try database.rules(workspaceID: secondWorkspaceID).isEmpty)
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
