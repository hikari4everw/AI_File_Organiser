import Foundation

#if canImport(FoundationModels)
  import FoundationModels

  @Generable(description: "A safe file organization suggestion")
  struct GeneratedFileProposal {
    @Guide(description: "One of move, keep, suggestFolder")
    var action: String

    @Guide(description: "An exact destination ID from the prompt, or an empty string")
    var destinationID: String

    @Guide(
      description:
        "A short first-level folder name only when action is suggestFolder, otherwise empty")
    var suggestedFolderName: String

    @Guide(description: "A short user-facing reason in the user's language")
    var reason: String
  }

  public struct AppleFoundationModelProvider: ClassificationProvider {
    private let model: SystemLanguageModel

    public init() {
      model = SystemLanguageModel(useCase: .contentTagging)
    }

    public var isAvailable: Bool { model.isAvailable && model.supportsLocale(.current) }

    public var availabilityDescription: String {
      guard model.supportsLocale(.current) else { return "当前语言暂不受系统模型支持" }
      switch model.availability {
      case .available: return "Apple 本地模型可用"
      case .unavailable(.deviceNotEligible): return "此 Mac 不支持 Apple 本地模型"
      case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence 尚未启用"
      case .unavailable(.modelNotReady): return "Apple 本地模型尚未准备好"
      @unknown default: return "Apple 本地模型当前不可用"
      }
    }

    public func classify(items: [ItemContext], destinations: [DestinationProfile]) async throws
      -> [ModelProposal]
    {
      guard isAvailable else { throw OrganizerError.modelUnavailable(availabilityDescription) }
      let destinationText = destinations.map {
        "id=\($0.id.uuidString) name=\($0.displayName) keywords=\($0.keywords.joined(separator: ",")) types=\($0.sampleContentTypes.joined(separator: ","))"
      }.joined(separator: "\n")
      var output: [ModelProposal] = []
      let allowedIDs = Set(destinations.map(\.id))

      for item in items {
        try Task.checkCancellation()
        let session = LanguageModelSession(
          model: model,
          instructions: """
            You classify a local file into a user-approved destination catalog.
            Never invent an ID or path. Prefer an existing destination.
            Use keep when moving would not be useful. Use suggestFolder only when no destination is suitable.
            A suggested folder must be one short first-level directory name without slashes, colons, or dots at the start.
            """
        )
        let prompt = """
          Destinations:
          \(destinationText.isEmpty ? "No existing destination is available; keep or suggest one folder." : destinationText)

          File:
          id=\(item.id.uuidString)
          name=\(item.snapshot.name)
          type=\(item.snapshot.contentType ?? "unknown")
          extension=\(item.snapshot.fileExtension)
          keywords=\(item.normalizedKeywords.joined(separator: ","))
          spotlightTitle=\(item.spotlightTitle ?? "")
          spotlightAuthors=\(item.spotlightAuthors.joined(separator: ","))
          spotlightContentType=\(item.spotlightContentType ?? "")
          sourceDirectory=\(URL(fileURLWithPath: item.snapshot.path).deletingLastPathComponent().lastPathComponent)
          itemKind=\(item.snapshot.kind.rawValue)
          shallowTypes=\(item.snapshot.shallowExtensions.joined(separator: ","))
          extractedSource=\(item.extracted.source)
          extractedText=\(item.extracted.text.prefix(3000))
          """
        let response = try await session.respond(
          to: prompt,
          generating: GeneratedFileProposal.self,
          options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 220)
        ).content
        if let proposal = try validate(response, itemID: item.id, allowedIDs: allowedIDs) {
          output.append(proposal)
        }
      }
      return output
    }

    private func validate(_ raw: GeneratedFileProposal, itemID: UUID, allowedIDs: Set<UUID>) throws
      -> ModelProposal?
    {
      let reason = String(raw.reason.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
      switch raw.action {
      case "move":
        guard let id = UUID(uuidString: raw.destinationID), allowedIDs.contains(id) else {
          return nil
        }
        return ModelProposal(itemID: itemID, action: .move, destinationID: id, reason: reason)
      case "keep":
        return ModelProposal(itemID: itemID, action: .keep, reason: reason)
      case "suggestFolder":
        let name = try PathSafety.validateFolderName(raw.suggestedFolderName)
        return ModelProposal(
          itemID: itemID, action: .suggestFolder, suggestedFolderName: name, reason: reason)
      default:
        return nil
      }
    }
  }
#else
  public struct AppleFoundationModelProvider: ClassificationProvider {
    public init() {}
    public var isAvailable: Bool { false }
    public var availabilityDescription: String { "当前 SDK 不包含 Foundation Models" }
    public func classify(items: [ItemContext], destinations: [DestinationProfile]) async throws
      -> [ModelProposal]
    {
      throw OrganizerError.modelUnavailable(availabilityDescription)
    }
  }
#endif
