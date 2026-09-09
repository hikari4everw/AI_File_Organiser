import Foundation

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
  public var condition: RuleCondition
  public var destinationID: UUID
  public var isEnabled: Bool
  public var isDerived: Bool
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    workspaceID: UUID,
    originalText: String,
    condition: RuleCondition,
    destinationID: UUID,
    isEnabled: Bool = true,
    isDerived: Bool = false,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.originalText = originalText
    self.condition = condition
    self.destinationID = destinationID
    self.isEnabled = isEnabled
    self.isDerived = isDerived
    self.createdAt = createdAt
  }
}

public struct RuleDraft: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var originalText: String
  public var condition: RuleCondition
  public var destinationID: UUID?
  public var warnings: [String]

  public init(
    id: UUID = UUID(),
    originalText: String,
    condition: RuleCondition,
    destinationID: UUID? = nil,
    warnings: [String] = []
  ) {
    self.id = id
    self.originalText = originalText
    self.condition = condition
    self.destinationID = destinationID
    self.warnings = warnings
  }
}

public enum RuleEvaluation: Hashable, Sendable {
  case none
  case matched(ruleID: UUID, destinationID: UUID)
  case semanticCandidates([UUID])
  case conflict(ruleIDs: [UUID])
}

public protocol RuleInterpreter: Sendable {
  func interpret(text: String, destinations: [DestinationProfile]) async throws -> [RuleDraft]
}
