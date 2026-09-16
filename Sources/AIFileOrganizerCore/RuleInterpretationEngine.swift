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
    concepts: [FileConcept] = [],
    interpreter: Interpreter
  ) async throws -> RuleInterpretationResult
  where Interpreter: RuleInterpreter, Interpreter: NamingRuleInterpreting {
    if let anchored = conceptRoute(text: text, destinations: destinations, concepts: concepts) {
      guard ["改名", "命名", "重命名"].contains(where: text.contains) else {
        return anchored
      }
      let naming = await capture { try await interpreter.interpretNaming(text: text) }
      var warnings = anchored.warnings
      if naming.values.isEmpty { warnings.append(naming.warning(route: "命名规则")) }
      return RuleInterpretationResult(
        organizationDrafts: anchored.organizationDrafts,
        namingDrafts: naming.values, warnings: warnings)
    }
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

  private func conceptRoute(
    text: String, destinations: [DestinationProfile], concepts: [FileConcept]
  ) -> RuleInterpretationResult? {
    let verbs = ["移动到", "归档到", "放到", "移到"]
    guard let verb = verbs.first(where: { text.contains($0) }),
      let range = text.range(of: verb)
    else { return nil }
    var subject = String(text[..<range.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var target = String(text[range.upperBound...])
      .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    target = String(target.split(separator: "，", maxSplits: 1).first ?? "")
    target = String(target.split(separator: ",", maxSplits: 1).first ?? "")
    for prefix in ["所有", "把", "将", "这些"] where subject.hasPrefix(prefix) {
      subject.removeFirst(prefix.count)
      break
    }
    if subject.hasSuffix("都") { subject.removeLast() }
    subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
    target = target.trimmingCharacters(in: .whitespacesAndNewlines)
    let subjectKey = RuleCondition.normalize(subject)
    let matchedConcepts = concepts.filter { concept in
      ([concept.name] + concept.aliases).contains {
        RuleCondition.normalize($0) == subjectKey
      }
    }
    guard !matchedConcepts.isEmpty else { return nil }
    let targetKey = RuleCondition.normalize(target)
    let matchedDestinations = destinations.filter { destination in
      destination.kind == .category
        && (RuleCondition.normalize(destination.relativePath) == targetKey
          || RuleCondition.normalize(destination.displayName) == targetKey)
    }
    var warnings: [String] = []
    if matchedConcepts.count > 1 { warnings.append("名称对应多个概念，请在草稿中选择") }
    if matchedDestinations.count != 1 { warnings.append("目标目录不明确，请在草稿中选择") }
    let draft = RuleDraft(
      originalText: text,
      condition: RuleCondition(
        conceptID: matchedConcepts.count == 1 ? matchedConcepts[0].id : nil),
      destinationID: matchedDestinations.count == 1 ? matchedDestinations[0].id : nil,
      warnings: warnings)
    return RuleInterpretationResult(
      organizationDrafts: [draft], namingDrafts: [], warnings: warnings)
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
