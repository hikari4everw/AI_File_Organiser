import Foundation

#if canImport(FoundationModels)
  import FoundationModels

  @Generable(description: "A safe base filename suggestion without a file extension")
  private struct GeneratedFilenameSuggestion {
    @Guide(description: "A concise base filename without an extension or path separators")
    var baseName: String
    @Guide(description: "A title copied from the supplied evidence, or empty")
    var title: String
    @Guide(description: "An author copied from the supplied evidence, or empty")
    var author: String
    @Guide(description: "A YYYY-MM-DD date from supplied evidence, or empty")
    var date: String
    @Guide(description: "A short user-facing reason")
    var reason: String
  }

  public struct AppleFilenameSuggestionProvider: FilenameSuggestionProvider {
    private let model = SystemLanguageModel(useCase: .contentTagging)

    public init() {}
    public var isAvailable: Bool { model.isAvailable && model.supportsLocale(.current) }
    public var availabilityDescription: String {
      guard model.supportsLocale(.current) else { return "当前语言暂不受系统模型支持" }
      switch model.availability {
      case .available: return "Apple 本地命名模型可用"
      case .unavailable(.deviceNotEligible): return "此 Mac 不支持 Apple 本地模型"
      case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence 尚未启用"
      case .unavailable(.modelNotReady): return "Apple 本地模型尚未准备好"
      @unknown default: return "Apple 本地模型当前不可用"
      }
    }

    public func suggestNames(requests: [FilenameSuggestionRequest]) async throws
      -> [ModelFilenameSuggestion]
    {
      guard isAvailable else { throw OrganizerError.modelUnavailable(availabilityDescription) }
      var results: [ModelFilenameSuggestion] = []
      for request in requests {
        try Task.checkCancellation()
        let context = request.context
        let session = LanguageModelSession(
          model: model,
          instructions: """
            Suggest a clear filename using only supplied evidence. Return a base name only.
            Never add an extension, slash, colon, hidden-name prefix, or invented fact.
            Template fields must be copied from evidence; leave a field empty when unsupported.
            """)
        let response = try await session.respond(
          to: """
            name=\(context.snapshot.name)
            type=\(context.snapshot.contentType ?? "unknown")
            template=\(request.template?.pattern ?? "none")
            title=\(context.spotlightTitle ?? "")
            authors=\(context.spotlightAuthors.joined(separator: ", "))
            extractedText=\(context.extracted.text.prefix(4000))
            directorySummary=\(String(describing: context.directorySummary))
            styleExamples=\(request.styleExamples.joined(separator: " | "))
            """,
          generating: GeneratedFilenameSuggestion.self,
          options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 260)
        ).content
        var fields: [FilenameField: String] = [:]
        if !response.title.isEmpty { fields[.title] = response.title }
        if !response.author.isEmpty { fields[.author] = response.author }
        if !response.date.isEmpty { fields[.date] = response.date }
        results.append(ModelFilenameSuggestion(
          itemID: context.id,
          suggestedBaseName: response.baseName,
          fields: fields,
          reason: response.reason))
      }
      return results
    }
  }
#else
  public struct AppleFilenameSuggestionProvider: FilenameSuggestionProvider {
    public init() {}
    public var isAvailable: Bool { false }
    public var availabilityDescription: String { "当前 SDK 不包含 Foundation Models" }
    public func suggestNames(requests: [FilenameSuggestionRequest]) async throws
      -> [ModelFilenameSuggestion]
    {
      throw OrganizerError.modelUnavailable(availabilityDescription)
    }
  }
#endif
