import Foundation

public struct FileConcept: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var description: String
  public var aliases: [String]
  public var parentID: UUID?
  public var createdAt: Date

  public init(
    id: UUID = UUID(), name: String, description: String = "", aliases: [String] = [],
    parentID: UUID? = nil, createdAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.aliases = aliases
    self.parentID = parentID
    self.createdAt = createdAt
  }
}

public struct ConceptFeatureSnapshot: Codable, Hashable, Sendable {
  public var modelVersion: String
  public var itemKind: ItemKind
  public var visualVector: [Float]

  public init(modelVersion: String, itemKind: ItemKind, visualVector: [Float]) {
    self.modelVersion = modelVersion
    self.itemKind = itemKind
    self.visualVector = visualVector
  }
}

public struct ConceptExample: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var conceptID: UUID
  public var itemIdentity: String
  public var isPositive: Bool
  public var features: ConceptFeatureSnapshot
  public var createdAt: Date

  public init(
    id: UUID = UUID(), conceptID: UUID, itemIdentity: String, isPositive: Bool,
    features: ConceptFeatureSnapshot, createdAt: Date = Date()
  ) {
    self.id = id
    self.conceptID = conceptID
    self.itemIdentity = itemIdentity
    self.isPositive = isPositive
    self.features = features
    self.createdAt = createdAt
  }
}
