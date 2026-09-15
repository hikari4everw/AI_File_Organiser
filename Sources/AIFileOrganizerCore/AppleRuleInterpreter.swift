import Foundation

#if canImport(FoundationModels)
  import FoundationModels

  @Generable(description: "A reviewable file organization rule")
  private struct GeneratedRuleDraft {
    @Guide(description: "move or keep")
    var action: String
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

  public func interpretNaming(text: String) async throws -> [NamingRuleDraft] {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return [] }
    let markers = ["命名为", "重命名为", "rename as"]
    if let marker = markers.compactMap({ value -> (String, Range<String.Index>)? in
      cleaned.range(of: value, options: .caseInsensitive).map { (value, $0) }
    }).min(by: { $0.1.lowerBound < $1.1.lowerBound }) {
      return try templateDraft(text: cleaned, marker: marker)
    }

    return transformationDraft(text: cleaned).map { [$0] } ?? []
  }

  private func templateDraft(
    text cleaned: String,
    marker: (String, Range<String.Index>)
  ) throws -> [NamingRuleDraft] {
    let pattern = String(cleaned[marker.1.upperBound...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let template = FilenameTemplate(pattern: pattern)
    try FilenameTemplateEngine().validate(template)
    let knownExtensions = [
      "pdf", "jpg", "jpeg", "png", "heic", "gif", "txt", "md", "doc", "docx",
      "xlsx", "csv", "pptx", "mp3", "flac", "wav", "mp4", "mov", "zip", "dmg", "pkg",
    ]
    let extensions = knownExtensions.filter {
      cleaned.range(of: "\\b\($0)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
    var kinds: Set<ItemKind> = []
    if cleaned.contains("文件夹") || cleaned.contains("目录") { kinds.insert(.directory) }
    let conditionText = String(cleaned[..<marker.1.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return [
      NamingRuleDraft(
        originalText: cleaned,
        condition: RuleCondition(
          itemKinds: kinds,
          fileExtensions: Set(extensions),
          semanticDescription: extensions.isEmpty && kinds.isEmpty && !conditionText.isEmpty
            ? conditionText : nil
        ),
        template: template
      )
    ]
  }

  private func transformationDraft(text: String) -> NamingRuleDraft? {
    let transformationMarkers = ["删除前缀", "删除后缀", "替换为", "替换成", "删除文件名"]
    guard transformationMarkers.contains(where: text.contains) else { return nil }

    if text.contains("删除前缀"),
      text.range(of: "nhentai-[0-9]+\\s*-\\s*", options: .regularExpression) != nil
    {
      guard text.contains("同人志") else {
        return NamingRuleDraft(
          originalText: text,
          condition: RuleCondition(filenameKeywords: ["nhentai-"]),
          operations: [],
          warnings: ["nhentai 前缀规则需要明确限定为同人志，未生成可执行操作"])
      }
      return NamingRuleDraft(
        originalText: text,
        condition: RuleCondition(
          filenameKeywords: ["nhentai-"],
          semanticDescription: "同人志"),
        operations: [.removeNumericPrefix(prefix: "nhentai-", suffix: " - ")])
    }

    let marker: String
    let operation: NamingOperation?
    if let range = text.range(of: "删除前缀") {
      marker = "删除前缀"
      operation = quotedOperand(in: String(text[range.upperBound...]))
        .map(NamingOperation.removeLiteralPrefix)
    } else if let range = text.range(of: "删除后缀") {
      marker = "删除后缀"
      operation = quotedOperand(in: String(text[range.upperBound...]))
        .map(NamingOperation.removeLiteralSuffix)
    } else if let replacementMarker = ["替换为", "替换成"].compactMap({ value in
      text.range(of: value).map { (value, $0) }
    }).min(by: { $0.1.lowerBound < $1.1.lowerBound }) {
      marker = replacementMarker.0
      let before = String(text[..<replacementMarker.1.lowerBound])
      let after = String(text[replacementMarker.1.upperBound...])
      if let target = replacementOperand(in: before),
        let replacement = replacementOperand(in: after)
      {
        operation = .replaceLiteral(target: target, replacement: replacement)
      } else {
        operation = nil
      }
    } else {
      marker = "删除文件名"
      operation = nil
    }

    let conditionText = String(text[..<(text.range(of: marker)?.lowerBound ?? text.endIndex)])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var condition = namingCondition(in: conditionText)
    if condition.semanticDescription == nil,
      !condition.hasDeterministicConditions,
      !conditionText.isEmpty
    {
      condition.semanticDescription = conditionText
    }
    guard let operation else {
      return NamingRuleDraft(
        originalText: text,
        condition: condition,
        operations: [],
        warnings: ["无法安全解析这项命名变换，请明确要删除或替换的字面文本"])
    }
    return NamingRuleDraft(
      originalText: text,
      condition: condition,
      operations: [operation])
  }

  private func namingCondition(in text: String) -> RuleCondition {
    let knownExtensions = [
      "pdf", "jpg", "jpeg", "png", "heic", "gif", "txt", "md", "doc", "docx",
      "xlsx", "csv", "pptx", "mp3", "flac", "wav", "mp4", "mov", "zip", "dmg", "pkg",
    ]
    let extensions = knownExtensions.filter {
      text.range(of: "\\b\($0)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
    var kinds: Set<ItemKind> = []
    if text.contains("文件夹") || text.contains("目录") { kinds.insert(.directory) }
    return RuleCondition(itemKinds: kinds, fileExtensions: Set(extensions))
  }

  private func quotedOperand(in text: String) -> String? {
    for pair in [("「", "」"), ("『", "』"), ("“", "”"), ("\"", "\"")] {
      guard let start = text.range(of: pair.0),
        let end = text.range(of: pair.1, range: start.upperBound..<text.endIndex)
      else { continue }
      let value = String(text[start.upperBound..<end.lowerBound])
      return value.isEmpty ? nil : value
    }
    return nil
  }

  private func replacementOperand(in text: String) -> String? {
    if let quoted = quotedOperand(in: text) { return quoted }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let token = trimmed.split(whereSeparator: \.isWhitespace).last else { return nil }
    let value = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "，,。；;"))
    guard value.unicodeScalars.count == 1,
      let scalar = value.unicodeScalars.first,
      !CharacterSet.alphanumerics.contains(scalar)
    else { return nil }
    return value
  }

  public func interpret(text: String, destinations: [DestinationProfile]) async throws
    -> [RuleDraft]
  {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return [] }
    if cleaned.contains("未解压文件"), cleaned.contains("不用移动") {
      return [
        RuleDraft(
          originalText: cleaned,
          action: .keep,
          condition: RuleCondition(
            itemKinds: [.file],
            fileExtensions: ["zip", "7z", "rar", "tar", "gz"]
          )
        )
      ]
    }
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
          Use keep with an empty destination ID when the user wants matching items left in place.
          Use move only when the user wants matching items moved to a supplied destination.
          Use semanticDescription only for meaning that cannot be represented literally.
          """
      )
      let generated: GeneratedRuleDraft
      do {
        generated = try await session.respond(
          to: "Destinations:\n\(catalog)\n\nUser rule:\n\(cleaned)",
          generating: GeneratedRuleDraft.self,
          options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 240)
        ).content
      } catch {
        if let localized = Self.localizedGenerationError(error) { throw localized }
        throw error
      }
      if let draft = validate(generated, originalText: cleaned, destinations: destinations) {
        return [draft]
      }
      throw OrganizerError.modelUnavailable("AI 返回的规则未通过目标与结构校验")
    }
#endif
    return [fallbackDraft(text: cleaned, destinations: destinations)]
  }

#if canImport(FoundationModels)
  static func localizedGenerationError(_ error: Error) -> OrganizerError? {
    guard let generationError = error as? LanguageModelSession.GenerationError,
      case .guardrailViolation = generationError
    else { return nil }
    return .modelUnavailable("本地 AI 无法处理这条规则描述，请改写后重试")
  }

  private func validate(
    _ generated: GeneratedRuleDraft,
    originalText: String,
    destinations: [DestinationProfile]
  ) -> RuleDraft? {
    let action: RuleAction
    let destinationID: UUID?
    switch generated.action {
    case "move":
      guard let id = UUID(uuidString: generated.destinationID),
        destinations.contains(where: { $0.id == id })
      else { return nil }
      action = .move
      destinationID = id
    case "keep":
      action = .keep
      destinationID = nil
    default:
      return nil
    }
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
      action: action,
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
    let action: RuleAction = text.contains("不用移动") || text.contains("不移动")
      || text.contains("保留原处") ? .keep : .move
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
    let warnings = action == .move && destination == nil
      ? ["请选择一个目标目录"] : ["本地模型不可用，已生成基础草稿，请核对条件"]
    return RuleDraft(
      originalText: text,
      action: action,
      condition: RuleCondition(
        itemKinds: kinds,
        fileExtensions: Set(extensions),
        semanticDescription: extensions.isEmpty ? text : nil
      ),
      destinationID: action == .move ? destination?.id : nil,
      warnings: warnings
    )
  }

  private func split(_ value: String) -> [String] {
    value.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }.filter { !$0.isEmpty }
  }
}
