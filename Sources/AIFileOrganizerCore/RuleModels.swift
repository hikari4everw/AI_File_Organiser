import Foundation

public enum RuleAction: String, Codable, Hashable, Sendable {
  case move, keep
}

public struct RuleCondition: Codable, Hashable, Sendable {
  public var itemKinds: Set<ItemKind>
  public var fileExtensions: Set<String>
  public var filenameKeywords: Set<String>
  public var contentKeywords: Set<String>
  public var semanticDescription: String?

  public init(
    itemKinds: Set<ItemKind> = [],
    fileExtensions: Set<String> = [],
    filenameKeywords: Set<String> = [],
    contentKeywords: Set<String> = [],
    semanticDescription: String? = nil
  ) {
    self.itemKinds = itemKinds
    self.fileExtensions = Set(fileExtensions.map { $0.lowercased() })
    self.filenameKeywords = Set(filenameKeywords.map(Self.normalize))
    self.contentKeywords = Set(contentKeywords.map(Self.normalize))
    let semantic = semanticDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.semanticDescription = semantic?.isEmpty == false ? semantic : nil
  }

  public var hasDeterministicConditions: Bool {
    !itemKinds.isEmpty || !fileExtensions.isEmpty || !filenameKeywords.isEmpty
      || !contentKeywords.isEmpty
  }

  static func normalize(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }
}

public struct OrganizationRule: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var workspaceID: UUID
  public var originalText: String
  public var action: RuleAction
  public var condition: RuleCondition
  public var destinationID: UUID?
  public var isEnabled: Bool
  public var isDerived: Bool
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    workspaceID: UUID,
    originalText: String,
    action: RuleAction = .move,
    condition: RuleCondition,
    destinationID: UUID? = nil,
    isEnabled: Bool = true,
    isDerived: Bool = false,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.originalText = originalText
    self.action = action
    self.condition = condition
    self.destinationID = destinationID
    self.isEnabled = isEnabled
    self.isDerived = isDerived
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, workspaceID, originalText, action, condition, destinationID, isEnabled, isDerived,
      createdAt
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    workspaceID = try values.decode(UUID.self, forKey: .workspaceID)
    originalText = try values.decode(String.self, forKey: .originalText)
    action = try values.decodeIfPresent(RuleAction.self, forKey: .action) ?? .move
    condition = try values.decode(RuleCondition.self, forKey: .condition)
    destinationID = try values.decodeIfPresent(UUID.self, forKey: .destinationID)
    isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
    isDerived = try values.decode(Bool.self, forKey: .isDerived)
    createdAt = try values.decode(Date.self, forKey: .createdAt)
  }
}

public struct RuleDraft: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var originalText: String
  public var action: RuleAction
  public var condition: RuleCondition
  public var destinationID: UUID?
  public var warnings: [String]

  public init(
    id: UUID = UUID(),
    originalText: String,
    action: RuleAction = .move,
    condition: RuleCondition,
    destinationID: UUID? = nil,
    warnings: [String] = []
  ) {
    self.id = id
    self.originalText = originalText
    self.action = action
    self.condition = condition
    self.destinationID = destinationID
    self.warnings = warnings
  }
}

public enum RuleEvaluation: Hashable, Sendable {
  case none
  case matchedMove(ruleID: UUID, destinationID: UUID)
  case matchedKeep(ruleID: UUID)
  case semanticCandidates([UUID])
  case conflict(ruleIDs: [UUID])
}

public protocol RuleInterpreter: Sendable {
  func interpret(text: String, destinations: [DestinationProfile]) async throws -> [RuleDraft]
}
