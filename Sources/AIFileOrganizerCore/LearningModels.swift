import Foundation

public enum LearningConfirmation: String, Codable, Hashable, Sendable {
  case userApproved, acceptedSuggestion, existingLibrary
}

public struct DecisionFeatures: Codable, Hashable, Sendable {
  public var itemKind: ItemKind
  public var fileExtension: String
  public var keywords: [String]

  public init(itemKind: ItemKind, fileExtension: String = "", keywords: [String] = []) {
    self.itemKind = itemKind
    self.fileExtension = fileExtension.lowercased()
    self.keywords = Array(Set(keywords.map(RuleCondition.normalize))).sorted()
  }
}

public struct LearningSample: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var libraryID: UUID
  public var sessionID: UUID
  public var operationID: UUID?
  public var itemIdentity: String
  public var destinationID: UUID
  public var features: DecisionFeatures
  public var confirmation: LearningConfirmation
  public var isActive: Bool
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    libraryID: UUID,
    sessionID: UUID,
    operationID: UUID? = nil,
    itemIdentity: String,
    destinationID: UUID,
    features: DecisionFeatures,
    confirmation: LearningConfirmation,
    isActive: Bool = true,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.libraryID = libraryID
    self.sessionID = sessionID
    self.operationID = operationID
    self.itemIdentity = itemIdentity
    self.destinationID = destinationID
    self.features = features
    self.confirmation = confirmation
    self.isActive = isActive
    self.createdAt = createdAt
  }
}

public struct RuleSuggestion: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var libraryID: UUID
  public var destinationID: UUID
  public var condition: RuleCondition
  public var supportingSampleIDs: [UUID]

  public init(
    id: UUID = UUID(),
    libraryID: UUID,
    destinationID: UUID,
    condition: RuleCondition,
    supportingSampleIDs: [UUID]
  ) {
    self.id = id
    self.libraryID = libraryID
    self.destinationID = destinationID
    self.condition = condition
    self.supportingSampleIDs = supportingSampleIDs
  }
}
