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
}

