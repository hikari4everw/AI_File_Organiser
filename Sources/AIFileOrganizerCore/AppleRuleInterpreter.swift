import Foundation

#if canImport(FoundationModels)
  import FoundationModels

  @Generable(description: "A reviewable file organization rule")
  private struct GeneratedRuleDraft {
    @Guide(description: "An exact destination UUID from the supplied catalog")
    var destinationID: String
    @Guide(description: "file, directory, applicationBundle, or empty")
    var itemKind: String
    @Guide(description: "Comma-separated lowercase file extensions without dots")
    var fileExtensions: String
    @Guide(description: "Comma-separated literal filename keywords")
    var filenameKeywords: String
    @Guide(description: "Comma-separated literal content keywords")
    var contentKeywords: String
    @Guide(description: "Semantic meaning that still needs model judgment, or empty")
    var semanticDescription: String
  }
#endif

public struct AppleRuleInterpreter: RuleInterpreter {
  public init() {}

  public func interpret(text: String, destinations: [DestinationProfile]) async throws
    -> [RuleDraft]
  {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return [] }
#if canImport(FoundationModels)
    let model = SystemLanguageModel(useCase: .contentTagging)
    if model.isAvailable, model.supportsLocale(.current) {
      let catalog = destinations.map { "\($0.id.uuidString) | \($0.relativePath)" }
        .joined(separator: "\n")
      let session = LanguageModelSession(
        model: model,
        instructions: """
          Convert one user sentence into one editable file-organization rule.
          Preserve every explicit condition. Never invent a destination ID.
          Use semanticDescription only for meaning that cannot be represented literally.
          """
      )
      let generated = try await session.respond(
        to: "Destinations:\n\(catalog)\n\nUser rule:\n\(cleaned)",
        generating: GeneratedRuleDraft.self,
        options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 240)
      ).content
      if let draft = validate(generated, originalText: cleaned, destinations: destinations) {
        return [draft]
      }
      throw OrganizerError.modelUnavailable("AI 返回的规则未通过目标与结构校验")
    }
#endif
    return [fallbackDraft(text: cleaned, destinations: destinations)]
  }

#if canImport(FoundationModels)
  private func validate(
    _ generated: GeneratedRuleDraft,
    originalText: String,
    destinations: [DestinationProfile]
  ) -> RuleDraft? {
    guard let destinationID = UUID(uuidString: generated.destinationID),
      destinations.contains(where: { $0.id == destinationID })
    else { return nil }
    let kinds: Set<ItemKind>
    switch generated.itemKind {
    case "": kinds = []
    case "file": kinds = [.file]
    case "directory": kinds = [.directory]
    case "applicationBundle": kinds = [.applicationBundle]
    default: return nil
    }
    return RuleDraft(
      originalText: originalText,
      condition: RuleCondition(
        itemKinds: kinds,
        fileExtensions: Set(split(generated.fileExtensions)),
        filenameKeywords: Set(split(generated.filenameKeywords)),
        contentKeywords: Set(split(generated.contentKeywords)),
        semanticDescription: generated.semanticDescription
      ),
      destinationID: destinationID
    )
  }
#endif

  private func fallbackDraft(text: String, destinations: [DestinationProfile]) -> RuleDraft {
    let destination = destinations
      .sorted { $0.relativePath.count > $1.relativePath.count }
      .first { text.localizedCaseInsensitiveContains($0.displayName)
        || text.localizedCaseInsensitiveContains($0.relativePath) }
    let knownExtensions = [
      "pdf", "jpg", "jpeg", "png", "heic", "gif", "txt", "md", "doc", "docx",
      "xlsx", "csv", "pptx", "mp3", "flac", "wav", "mp4", "mov", "zip", "dmg", "pkg",
    ]
    let extensions = knownExtensions.filter {
      text.range(of: "\\b\($0)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
    var kinds: Set<ItemKind> = []
    if text.contains("文件夹") || text.contains("目录") { kinds.insert(.directory) }
    let warnings = destination == nil ? ["请选择一个目标目录"] : ["本地模型不可用，已生成基础草稿，请核对条件"]
    return RuleDraft(
      originalText: text,
      condition: RuleCondition(
        itemKinds: kinds,
        fileExtensions: Set(extensions),
        semanticDescription: extensions.isEmpty ? text : nil
      ),
      destinationID: destination?.id,
      warnings: warnings
    )
  }

  private func split(_ value: String) -> [String] {
    value.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }.filter { !$0.isEmpty }
  }
}
