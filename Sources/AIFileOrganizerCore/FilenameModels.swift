import Foundation

public enum FilenameField: String, Codable, Hashable, CaseIterable, Sendable {
  case originalTitle
  case title
  case author
  case date

  public var placeholder: String {
    switch self {
    case .originalTitle: "原标题"
    case .title: "标题"
    case .author: "作者"
    case .date: "日期"
    }
  }

  public init?(placeholder: String) {
    guard let field = Self.allCases.first(where: { $0.placeholder == placeholder }) else {
      return nil
    }
    self = field
  }
}

public struct FilenameTemplate: Codable, Hashable, Sendable {
  public var pattern: String

  public init(pattern: String) { self.pattern = pattern }
}

public struct TemplateRenderResult: Codable, Hashable, Sendable {
  public var value: String
  public var missingFields: [FilenameField]

  public init(value: String, missingFields: [FilenameField] = []) {
    self.value = value
    self.missingFields = missingFields
  }
}

public struct NamingRule: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var workspaceID: UUID
  public var originalText: String
  public var condition: RuleCondition
  public var template: FilenameTemplate
  public var isEnabled: Bool
  public var isDerived: Bool
  public var createdAt: Date

  public init(
    id: UUID = UUID(), workspaceID: UUID, originalText: String, condition: RuleCondition,
    template: FilenameTemplate, isEnabled: Bool = true, isDerived: Bool = false,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.originalText = originalText
    self.condition = condition
    self.template = template
    self.isEnabled = isEnabled
    self.isDerived = isDerived
    self.createdAt = createdAt
  }
}

public struct NamingRuleDraft: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var originalText: String
  public var condition: RuleCondition
  public var template: FilenameTemplate
  public var warnings: [String]

  public init(
    id: UUID = UUID(), originalText: String, condition: RuleCondition,
    template: FilenameTemplate, warnings: [String] = []
  ) {
    self.id = id
    self.originalText = originalText
    self.condition = condition
    self.template = template
    self.warnings = warnings
  }
}

public enum RenameProposalSource: String, Codable, Hashable, Sendable {
  case namingRule
  case foundationModel
  case user
}

public enum RenameDisposition: String, Codable, Hashable, Sendable {
  case pending
  case selectedByRule
  case approved
  case edited
  case rejected
  case blocked
}

public struct RenameProposal: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var sessionID: UUID
  public var itemID: UUID
  public var originalName: String
  public var suggestedBaseName: String
  public var editedBaseName: String?
  public var source: RenameProposalSource
  public var disposition: RenameDisposition
  public var ruleID: UUID?
  public var templatePattern: String?
  public var missingFields: [FilenameField]
  public var reason: String

  public init(
    id: UUID = UUID(), sessionID: UUID, itemID: UUID, originalName: String,
    suggestedBaseName: String, editedBaseName: String? = nil, source: RenameProposalSource,
    disposition: RenameDisposition = .pending, ruleID: UUID? = nil,
    templatePattern: String? = nil, missingFields: [FilenameField] = [], reason: String
  ) {
    self.id = id
    self.sessionID = sessionID
    self.itemID = itemID
    self.originalName = originalName
    self.suggestedBaseName = suggestedBaseName
    self.editedBaseName = editedBaseName
    self.source = source
    self.disposition = disposition
    self.ruleID = ruleID
    self.templatePattern = templatePattern
    self.missingFields = missingFields
    self.reason = reason
  }

  public var selectedBaseName: String? {
    switch disposition {
    case .selectedByRule, .approved, .edited:
      editedBaseName ?? suggestedBaseName
    case .pending, .rejected, .blocked:
      nil
    }
  }
}

public struct FilenameSuggestionRequest: Codable, Hashable, Sendable {
  public var context: ItemContext
  public var template: FilenameTemplate?
  public var styleExamples: [String]
  public var ruleID: UUID?

  public init(
    context: ItemContext, template: FilenameTemplate? = nil, styleExamples: [String] = [],
    ruleID: UUID? = nil
  ) {
    self.context = context
    self.template = template
    self.styleExamples = Array(styleExamples.prefix(8))
    self.ruleID = ruleID
  }
}

public struct ModelFilenameSuggestion: Codable, Hashable, Sendable {
  public var itemID: UUID
  public var suggestedBaseName: String
  public var fields: [FilenameField: String]
  public var reason: String

  public init(
    itemID: UUID, suggestedBaseName: String, fields: [FilenameField: String] = [:],
    reason: String
  ) {
    self.itemID = itemID
    self.suggestedBaseName = suggestedBaseName
    self.fields = fields
    self.reason = reason
  }
}

public struct FilenameSuggestionPipelineResult: Sendable {
  public var proposals: [RenameProposal]
  public var contextsByItem: [UUID: ItemContext]
  public var modelStatus: String

  public init(
    proposals: [RenameProposal], contextsByItem: [UUID: ItemContext], modelStatus: String
  ) {
    self.proposals = proposals
    self.contextsByItem = contextsByItem
    self.modelStatus = modelStatus
  }
}
