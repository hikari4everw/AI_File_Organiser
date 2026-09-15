import Foundation

#if canImport(FoundationModels)
  import FoundationModels

  @Generable(description: "A semantic filename-rule condition decision")
  private struct GeneratedSemanticNamingConditionEvaluation {
    @Guide(description: "Exactly one of match, noMatch, or uncertain")
    var decision: String
    @Guide(description: "A short reason grounded only in the supplied evidence")
    var reason: String
  }

  public struct AppleSemanticNamingConditionEvaluator: SemanticNamingConditionEvaluator {
    private let model = SystemLanguageModel(useCase: .contentTagging)

    public init() {}
    public var isAvailable: Bool { model.isAvailable && model.supportsLocale(.current) }
    public var availabilityDescription: String {
      guard model.supportsLocale(.current) else { return "当前语言暂不受系统模型支持" }
      switch model.availability {
      case .available: return "Apple 本地语义判断模型可用"
      case .unavailable(.deviceNotEligible): return "此 Mac 不支持 Apple 本地模型"
      case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence 尚未启用"
      case .unavailable(.modelNotReady): return "Apple 本地模型尚未准备好"
      @unknown default: return "Apple 本地模型当前不可用"
      }
    }

    public func evaluate(request: FilenameSuggestionRequest) async throws
      -> SemanticNamingConditionEvaluation
    {
      guard isAvailable else { throw OrganizerError.modelUnavailable(availabilityDescription) }
      guard let condition = request.semanticCondition else {
        return .uncertain(reason: "缺少语义条件")
      }
      try Task.checkCancellation()
      let context = request.context
      let session = LanguageModelSession(
        model: model,
        instructions: """
          Decide whether the supplied file evidence satisfies the semantic condition.
          Use match only when the evidence supports it, noMatch when the evidence contradicts it,
          and uncertain when the evidence is insufficient or ambiguous. Never infer from the rule's
          filename transformation. Give one short reason in the user's language.
          """)
      let response = try await session.respond(
        to: """
          semanticCondition=\(condition)
          name=\(context.snapshot.name)
          type=\(context.snapshot.contentType ?? "unknown")
          extension=\(context.snapshot.fileExtension)
          spotlightTitle=\(context.spotlightTitle ?? "")
          spotlightAuthors=\(context.spotlightAuthors.joined(separator: ", "))
          extractedSource=\(context.extracted.source)
          extractedText=\(context.extracted.text.prefix(4000))
          directorySummary=\(String(describing: context.directorySummary))
          """,
        generating: GeneratedSemanticNamingConditionEvaluation.self,
        options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 120)
      ).content
      let reason = String(response.reason.prefix(240))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      switch response.decision {
      case "match": return .match(reason: reason)
      case "noMatch": return .noMatch(reason: reason)
      case "uncertain": return .uncertain(reason: reason)
      default: return .uncertain(reason: reason.isEmpty ? "模型返回了未知判断" : reason)
      }
    }
  }
#else
  public struct AppleSemanticNamingConditionEvaluator: SemanticNamingConditionEvaluator {
    public init() {}
    public var isAvailable: Bool { false }
    public var availabilityDescription: String { "当前 SDK 不包含 Foundation Models" }
    public func evaluate(request: FilenameSuggestionRequest) async throws
      -> SemanticNamingConditionEvaluation
    {
      throw OrganizerError.modelUnavailable(availabilityDescription)
    }
  }
#endif
