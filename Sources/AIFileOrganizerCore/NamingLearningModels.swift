import Foundation

public enum NamingSampleSource: String, Codable, Hashable, Sendable {
  case userApproved
  case acceptedSuggestion
  case namingRule
  case existingLibrary
}

public struct NamingDecisionFeatures: Codable, Hashable, Sendable {
  public var itemKind: ItemKind
  public var fileExtension: String
  public var originalBaseName: String
  public var finalBaseName: String
  public var templatePattern: String?

  public init(
    itemKind: ItemKind, fileExtension: String = "", originalBaseName: String,
    finalBaseName: String, templatePattern: String? = nil
  ) {
    self.itemKind = itemKind
    self.fileExtension = fileExtension.lowercased()
    self.originalBaseName = originalBaseName
    self.finalBaseName = finalBaseName
    self.templatePattern = templatePattern
  }
}

public struct NamingSample: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var workspaceID: UUID
  public var sessionID: UUID
  public var operationID: UUID?
  public var itemIdentity: String
  public var destinationID: UUID?
  public var source: NamingSampleSource
  public var features: NamingDecisionFeatures
  public var isActive: Bool
  public var createdAt: Date

  public init(
    id: UUID = UUID(), workspaceID: UUID, sessionID: UUID, operationID: UUID? = nil,
    itemIdentity: String, destinationID: UUID? = nil, source: NamingSampleSource,
    features: NamingDecisionFeatures, isActive: Bool = true, createdAt: Date = Date()
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.sessionID = sessionID
    self.operationID = operationID
    self.itemIdentity = itemIdentity
    self.destinationID = destinationID
    self.source = source
    self.features = features
    self.isActive = isActive
    self.createdAt = createdAt
  }
}

public enum NamingRuleSuggestionState: String, Codable, Hashable, Sendable {
  case pending, approved, rejected
}

public struct NamingRuleSuggestion: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var workspaceID: UUID
  public var condition: RuleCondition
  public var template: FilenameTemplate
  public var supportingSampleIDs: [UUID]
  public var state: NamingRuleSuggestionState

  public init(
    id: UUID = UUID(), workspaceID: UUID, condition: RuleCondition,
    template: FilenameTemplate, supportingSampleIDs: [UUID],
    state: NamingRuleSuggestionState = .pending
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.condition = condition
    self.template = template
    self.supportingSampleIDs = supportingSampleIDs
    self.state = state
  }
}
