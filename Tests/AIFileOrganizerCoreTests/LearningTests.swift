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
}
