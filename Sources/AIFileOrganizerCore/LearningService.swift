import Foundation

public struct LearningService: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) { self.database = database }

  public func recordSuccessfulOperation(
    libraryID: UUID,
    sessionID: UUID,
    operationID: UUID,
    itemIdentity: String,
    destinationID: UUID,
    features: DecisionFeatures,
    confirmation: LearningConfirmation
  ) throws {
    try database.saveLearningSample(
      LearningSample(
        libraryID: libraryID,
        sessionID: sessionID,
        operationID: operationID,
        itemIdentity: itemIdentity,
        destinationID: destinationID,
        features: features,
        confirmation: confirmation
      ))
  }

  public func retract(operationID: UUID) throws {
    try database.retractLearningSample(operationID: operationID)
  }

  public func activeSamples(libraryID: UUID) throws -> [LearningSample] {
    try database.learningSamples(libraryID: libraryID, activeOnly: true)
  }

  public func suggestRules(libraryID: UUID) throws -> [RuleSuggestion] {
    let samples = try activeSamples(libraryID: libraryID).filter {
      $0.confirmation == .userApproved
    }
    let groups = Dictionary(grouping: samples, by: \.destinationID)
    return groups.compactMap { destinationID, values in
      let uniqueItems = Dictionary(grouping: values, by: \.itemIdentity).compactMap(\.value.first)
      guard uniqueItems.count >= 3 else { return nil }
      let commonKeywords = uniqueItems.dropFirst().reduce(Set(uniqueItems[0].features.keywords)) {
        $0.intersection($1.features.keywords)
      }
      guard let keyword = commonKeywords.sorted().first else { return nil }
      return RuleSuggestion(
        libraryID: libraryID,
        destinationID: destinationID,
        condition: RuleCondition(filenameKeywords: [keyword]),
        supportingSampleIDs: uniqueItems.map(\.id)
      )
    }
  }
}
