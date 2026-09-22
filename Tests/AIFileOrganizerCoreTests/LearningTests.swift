import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct LearningTests {
  @Test func successfulOperationCreatesOneSampleAndUndoRetractsIt() throws {
    let database = try AppDatabase.inMemory()
    let libraryID = UUID()
    let operationID = UUID()
    let destinationID = UUID()
    let service = LearningService(database: database)
    let features = DecisionFeatures(
      itemKind: .file,
      fileExtension: "pdf",
      keywords: ["piano", "score"]
    )

    try service.recordSuccessfulOperation(
      libraryID: libraryID,
      sessionID: UUID(),
      operationID: operationID,
      itemIdentity: "file-1",
      destinationID: destinationID,
      features: features,
      confirmation: .userApproved
    )
    try service.recordSuccessfulOperation(
      libraryID: libraryID,
      sessionID: UUID(),
      operationID: operationID,
      itemIdentity: "file-1",
      destinationID: destinationID,
      features: features,
      confirmation: .userApproved
    )

    #expect(try service.activeSamples(libraryID: libraryID).count == 1)
    try service.retract(operationID: operationID)
    #expect(try service.activeSamples(libraryID: libraryID).isEmpty)
  }

  @Test func genericFileTypeAloneDoesNotSuggestRule() throws {
    let database = try AppDatabase.inMemory()
    let libraryID = UUID()
    let destinationID = UUID()
    let service = LearningService(database: database)
    for index in 0..<4 {
      try service.recordSuccessfulOperation(
        libraryID: libraryID,
        sessionID: UUID(),
        operationID: UUID(),
        itemIdentity: "pdf-\(index)",
        destinationID: destinationID,
        features: DecisionFeatures(itemKind: .file, fileExtension: "pdf"),
        confirmation: .userApproved
      )
    }

    #expect(try service.suggestRules(libraryID: libraryID).isEmpty)
  }

  /// `LearningService.suggestRules` 此前**只被断言过 `.isEmpty`**（反例），
  /// 从没有测试证明"证据充分时确实会产出规则"。
  /// 阈值见 `LearningService.swift:105-108`：同一目标下 ≥3 个不同 itemIdentity，
  /// 且它们的 features.keywords 有交集。
  @Test func sufficientlySupportedMovesSuggestARuleAndRetractionRemovesIt() throws {
    let database = try AppDatabase.inMemory()
    let libraryID = UUID()
    let destinationID = UUID()
    let service = LearningService(database: database)

    // 3 个不同项目，共有 keyword "piano"。
    for index in 0..<3 {
      try service.recordSuccessfulOperation(
        libraryID: libraryID,
        sessionID: UUID(),
        operationID: UUID(),
        itemIdentity: "score-\(index)",
        destinationID: destinationID,
        features: DecisionFeatures(
          itemKind: .file, fileExtension: "pdf",
          keywords: ["piano", "score-\(index)"]),
        confirmation: .userApproved
      )
    }

    let suggestion = try #require(service.suggestRules(libraryID: libraryID).first)
    #expect(suggestion.destinationID == destinationID)
    #expect(suggestion.condition.filenameKeywords == ["piano"])
    #expect(suggestion.supportingSampleIDs.count == 3)

    // 只有 2 个不同项目时不应产出规则（阈值是 3）。
    let otherDestinationID = UUID()
    for index in 0..<2 {
      try service.recordSuccessfulOperation(
        libraryID: libraryID,
        sessionID: UUID(),
        operationID: UUID(),
        itemIdentity: "other-\(index)",
        destinationID: otherDestinationID,
        features: DecisionFeatures(
          itemKind: .file, fileExtension: "pdf", keywords: ["shared", "unique-\(index)"]),
        confirmation: .userApproved
      )
    }
    #expect(
      try !service.suggestRules(libraryID: libraryID)
        .contains { $0.destinationID == otherDestinationID })

    // 关键词不相交时同一目标也不该产出规则。
    let disjointDestinationID = UUID()
    for index in 0..<3 {
      try service.recordSuccessfulOperation(
        libraryID: libraryID,
        sessionID: UUID(),
        operationID: UUID(),
        itemIdentity: "disjoint-\(index)",
        destinationID: disjointDestinationID,
        features: DecisionFeatures(
          itemKind: .file, fileExtension: "pdf",
          keywords: ["alpha-\(index)", "beta-\(index)"]),
        confirmation: .userApproved
      )
    }
    #expect(
      try !service.suggestRules(libraryID: libraryID)
        .contains { $0.destinationID == disjointDestinationID })

    // 撤回一个样本后回落到阈值以下，建议消失。
    let samples = try service.activeSamples(libraryID: libraryID)
      .filter { $0.destinationID == destinationID }
    // LearningSample.operationID 本身是可选值，需要显式解包。
    let retractedSample = try #require(samples.first)
    try service.retract(operationID: try #require(retractedSample.operationID))
    #expect(
      try !service.suggestRules(libraryID: libraryID)
        .contains { $0.destinationID == destinationID })
  }

  @Test func existingLibraryFilesRefreshWithoutDuplicatesAndEnrichDestination() throws {
    let database = try AppDatabase.inMemory()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let scores = root.appendingPathComponent("Music/Scores")
    try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
    try Data("notes".utf8).write(to: scores.appendingPathComponent("moonlight-piano-score.pdf"))
    try Data("notes".utf8).write(to: scores.appendingPathComponent("bach-fugue.pdf"))
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = DestinationProfile(
      relativePath: "Music/Scores", displayName: "Scores", sampleContentTypes: [])
    let service = LearningService(database: database)
    let libraryID = UUID()

    try service.refreshExistingLibrarySamples(
      libraryID: libraryID, root: root, destinations: [destination])
    try service.refreshExistingLibrarySamples(
      libraryID: libraryID, root: root, destinations: [destination])

    let samples = try service.activeSamples(libraryID: libraryID)
    #expect(samples.count == 2)
    #expect(samples.allSatisfy { $0.confirmation == .existingLibrary })
    let enriched = try service.enrich(destinations: [destination], libraryID: libraryID)
    #expect(enriched.first?.keywords.contains("piano") == true)
    #expect(enriched.first?.sampleContentTypes.contains("com.adobe.pdf") == true)

    let boundedLibraryID = UUID()
    try service.refreshExistingLibrarySamples(
      libraryID: boundedLibraryID,
      root: root,
      destinations: [destination],
      maximumTotal: 1
    )
    #expect(try service.activeSamples(libraryID: boundedLibraryID).count == 1)
  }

  @Test func namingLearningIsIdempotentRetractableAndNeedsFiveItemsAcrossTwoSessions() throws {
    let database = try AppDatabase.inMemory()
    let workspaceID = UUID()
    let service = NamingLearningService(database: database)
    let sessions = [UUID(), UUID()]
    var operationIDs: [UUID] = []
    for index in 0..<5 {
      let operationID = UUID()
      operationIDs.append(operationID)
      let sample = NamingSample(
        workspaceID: workspaceID,
        sessionID: sessions[index % 2],
        operationID: operationID,
        itemIdentity: "item-\(index)",
        destinationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
        source: .userApproved,
        features: NamingDecisionFeatures(
          itemKind: .file,
          fileExtension: "pdf",
          originalBaseName: "source-\(index)",
          finalBaseName: "Author - Title \(index)",
          templatePattern: "{作者} - {标题}"),
        createdAt: Date().addingTimeInterval(Double(index - 10))
      )
      try service.record(sample)
      try service.record(sample)
      if index == 3 {
        #expect(try service.suggestRules(workspaceID: workspaceID).isEmpty)
      }
    }

    #expect(try service.activeSamples(workspaceID: workspaceID).count == 5)
    let suggestion = try #require(service.suggestRules(workspaceID: workspaceID).first)
    #expect(suggestion.template.pattern == "{作者} - {标题}")
    #expect(suggestion.supportingSampleIDs.count == 5)

    try service.retract(operationID: operationIDs[0])
    #expect(try service.activeSamples(workspaceID: workspaceID).count == 4)
    #expect(try service.suggestRules(workspaceID: workspaceID).isEmpty)
  }

  @Test func namingStyleSamplesOnlyReadDirectChildrenAndStayBounded() throws {
    let database = try AppDatabase.inMemory()
    let service = NamingLearningService(database: database)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let scores = root.appendingPathComponent("Music/Scores")
    let nested = scores.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<35 {
      try Data().write(to: scores.appendingPathComponent("Composer - Work \(index).pdf"))
    }
    try Data().write(to: nested.appendingPathComponent("Hidden Depth.pdf"))
    let destination = DestinationProfile(relativePath: "Music/Scores", displayName: "Scores")

    try service.refreshExistingLibrarySamples(
      workspaceID: UUID(), root: root, destinations: [destination])

    let examples = try service.styleExamples(destinationID: destination.id)
    #expect(examples.count == 30)
    #expect(!examples.contains("Hidden Depth"))
  }
}
