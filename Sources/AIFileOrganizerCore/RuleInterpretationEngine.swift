import Foundation

public protocol NamingRuleInterpreting: Sendable {
  func interpretNaming(text: String) async throws -> [NamingRuleDraft]
}

public struct RuleInterpretationResult: Hashable, Sendable {
  public var organizationDrafts: [RuleDraft]
  public var namingDrafts: [NamingRuleDraft]
  public var warnings: [String]

  public init(
    organizationDrafts: [RuleDraft],
    namingDrafts: [NamingRuleDraft],
    warnings: [String] = []
  ) {
    self.organizationDrafts = organizationDrafts
    self.namingDrafts = namingDrafts
    self.warnings = warnings
  }
}

public struct RuleInterpretationEngine: Sendable {
  public init() {}

  public func interpret<Interpreter>(
    text: String,
    destinations: [DestinationProfile],
    interpreter: Interpreter
  ) async throws -> RuleInterpretationResult
  where Interpreter: RuleInterpreter, Interpreter: NamingRuleInterpreting {
    async let organization = capture {
      try await interpreter.interpret(text: text, destinations: destinations)
    }
    async let naming = capture {
      try await interpreter.interpretNaming(text: text)
    }
    let (organizationResult, namingResult) = await (organization, naming)
    let organizationDrafts = organizationResult.values
    let namingDrafts = namingResult.values

    guard !organizationDrafts.isEmpty || !namingDrafts.isEmpty else {
      let details = [
        organizationResult.failureDescription.map { "整理规则：\($0)" },
        namingResult.failureDescription.map { "命名规则：\($0)" },
      ].compactMap { $0 }
      let suffix = details.isEmpty ? "" : "（\(details.joined(separator: "；"))）"
      throw OrganizerError.invalidModelOutput("未能从描述中生成规则草稿\(suffix)")
    }

    var warnings: [String] = []
    if organizationDrafts.isEmpty {
      warnings.append(organizationResult.warning(route: "整理规则"))
    }
    if namingDrafts.isEmpty {
      warnings.append(namingResult.warning(route: "命名规则"))
    }
    return RuleInterpretationResult(
      organizationDrafts: organizationDrafts,
      namingDrafts: namingDrafts,
      warnings: warnings)
  }

  private func capture<Value: Sendable>(
    _ operation: @Sendable () async throws -> [Value]
  ) async -> InterpretationPath<Value> {
    do {
      return .success(try await operation())
    } catch {
      return .failure(error.localizedDescription)
    }
  }
}

private enum InterpretationPath<Value: Sendable>: Sendable {
  case success([Value])
  case failure(String)

  var values: [Value] {
    switch self {
    case .success(let values): values
    case .failure: []
    }
  }

  var failureDescription: String? {
    guard case .failure(let message) = self else { return nil }
    return message
  }

  func warning(route: String) -> String {
    switch self {
    case .success:
      "未生成\(route)草稿"
    case .failure(let message):
      "\(route)解析失败：\(message)"
    }
  }
}
