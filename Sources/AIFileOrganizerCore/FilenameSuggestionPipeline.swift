import Foundation

public struct FilenameSuggestionPipeline: Sendable {
  private let extractor: any ContentExtractor
  private let provider: any FilenameSuggestionProvider
  private let detector: FilenameQualityDetector
  private let directoryAnalyzer: DirectoryAnalyzer

  public init(
    extractor: any ContentExtractor = NativeContentExtractor(),
    provider: any FilenameSuggestionProvider = AppleFilenameSuggestionProvider(),
    detector: FilenameQualityDetector = .init(),
    directoryAnalyzer: DirectoryAnalyzer = .init()
  ) {
    self.extractor = extractor
    self.provider = provider
    self.detector = detector
    self.directoryAnalyzer = directoryAnalyzer
  }

  public func run(
    sessionID: UUID,
    items: [ItemSnapshot],
    contextsByItem initialContexts: [UUID: ItemContext] = [:],
    namingRules: [NamingRule] = [],
    requestedItemIDs: Set<UUID> = [],
    styleExamplesByDestination: [UUID: [String]] = [:],
    destinationByItem: [UUID: UUID] = [:],
    progress: @escaping OrganizationProgressHandler = { _ in }
  ) async -> FilenameSuggestionPipelineResult {
    var contexts = initialContexts
    let eligible = items.filter { $0.kind != .applicationBundle }
    let automaticIDs = Set(eligible.filter { detector.requiresSuggestion(name: $0.name) }.map(\.id))
    let ruleCandidateIDs = Set(eligible.filter { item in
      namingRules.contains { $0.isEnabled && coarseMatch($0.condition, item: item) }
    }.map(\.id))
    let candidateIDs = automaticIDs.union(requestedItemIDs).union(ruleCandidateIDs)

    if !candidateIDs.isEmpty {
      await progress(.init(phase: .analyzing, total: candidateIDs.count, isCancellable: true))
    }
    var completed = 0
    for item in eligible where candidateIDs.contains(item.id) {
      if Task.isCancelled { break }
      var context = contexts[item.id] ?? DeterministicClassifier().context(for: item)
      if context.extracted.status == .notNeeded, !item.isCloudPlaceholder {
        context.extracted = await extractor.extractContext(for: item)
      }
      if item.kind == .directory, context.directorySummary == nil {
        context.directorySummary = await directoryAnalyzer.analyze(
          URL(fileURLWithPath: item.path, isDirectory: true))
      }
      contexts[item.id] = context
      completed += 1
      await progress(.init(
        phase: .analyzing, completed: completed, total: candidateIDs.count,
        isCancellable: true))
    }

    let candidateContexts = eligible.filter { candidateIDs.contains($0.id) }.compactMap { contexts[$0.id] }
    var byItem = Dictionary(uniqueKeysWithValues: NamingRuleEngine().proposals(
      sessionID: sessionID, contexts: candidateContexts, rules: namingRules
    ).map { ($0.itemID, $0) })

    var requests: [FilenameSuggestionRequest] = []
    for context in candidateContexts where !context.snapshot.isCloudPlaceholder {
      let existing = byItem[context.id]
      let needsModel = automaticIDs.contains(context.id) || requestedItemIDs.contains(context.id)
        || existing?.disposition == .blocked
      guard needsModel else { continue }
      let rule = existing?.ruleID.flatMap { id in namingRules.first { $0.id == id } }
      let destinationID = destinationByItem[context.id]
      requests.append(FilenameSuggestionRequest(
        context: context,
        template: rule?.template,
        styleExamples: destinationID.flatMap { styleExamplesByDestination[$0] } ?? [],
        ruleID: rule?.id
      ))
    }

    var modelStatus = provider.availabilityDescription
    if provider.isAvailable, !requests.isEmpty, !Task.isCancelled {
      await progress(.init(
        phase: .aiClassifying, total: requests.count, isIndeterminate: true,
        isCancellable: true))
      do {
        let allowed = Dictionary(uniqueKeysWithValues: requests.map { ($0.context.id, $0) })
        let outputs = try await provider.suggestNames(requests: requests)
        for output in outputs {
          guard let request = allowed[output.itemID] else { continue }
          let item = request.context.snapshot
          let baseName: String
          var missing: [FilenameField] = []
          if let template = request.template {
            let fields = verifiedFields(output.fields, context: request.context)
              .merging(deterministicFields(request.context), uniquingKeysWith: { model, _ in model })
            guard let rendered = try? FilenameTemplateEngine().render(
              template: template, fields: fields)
            else { continue }
            baseName = rendered.missingFields.isEmpty ? rendered.value : originalBaseName(item)
            missing = rendered.missingFields
          } else {
            baseName = output.suggestedBaseName
          }
          guard missing.isEmpty,
            let fullName = try? FilenameValidator().validatedFullName(baseName: baseName, item: item),
            normalizedKey(fullName) != normalizedKey(item.name)
          else { continue }
          byItem[item.id] = RenameProposal(
            sessionID: sessionID,
            itemID: item.id,
            originalName: item.name,
            suggestedBaseName: baseName,
            source: request.ruleID == nil ? .foundationModel : .namingRule,
            disposition: request.ruleID == nil ? .pending : .selectedByRule,
            ruleID: request.ruleID,
            reason: String(output.reason.prefix(240))
          )
        }
        await progress(.init(
          phase: .aiClassifying, completed: requests.count, total: requests.count,
          isCancellable: true))
      } catch {
        modelStatus = "AI 命名已降级：\(error.localizedDescription)"
      }
    }

    let ordered = items.compactMap { byItem[$0.id] }
    return FilenameSuggestionPipelineResult(
      proposals: ordered, contextsByItem: contexts, modelStatus: modelStatus)
  }

  private func coarseMatch(_ condition: RuleCondition, item: ItemSnapshot) -> Bool {
    if !condition.itemKinds.isEmpty, !condition.itemKinds.contains(item.kind) { return false }
    if !condition.fileExtensions.isEmpty,
      !condition.fileExtensions.contains(item.fileExtension.lowercased()) { return false }
    if !condition.filenameKeywords.isEmpty {
      let name = RuleCondition.normalize(item.name)
      guard condition.filenameKeywords.contains(where: name.contains) else { return false }
    }
    return condition.hasDeterministicConditions || condition.semanticDescription != nil
  }

  private func deterministicFields(_ context: ItemContext) -> [FilenameField: String] {
    var values: [FilenameField: String] = [.originalTitle: originalBaseName(context.snapshot)]
    if let title = context.spotlightTitle, !title.isEmpty { values[.title] = title }
    if let author = context.spotlightAuthors.first, !author.isEmpty { values[.author] = author }
    if let date = context.snapshot.creationDate {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy-MM-dd"
      values[.date] = formatter.string(from: date)
    }
    return values
  }

  private func verifiedFields(
    _ fields: [FilenameField: String], context: ItemContext
  ) -> [FilenameField: String] {
    let evidence = RuleCondition.normalize([
      context.snapshot.name, context.spotlightTitle ?? "",
      context.spotlightAuthors.joined(separator: " "), context.extracted.text,
    ].joined(separator: " "))
    return fields.filter { field, value in
      field == .date || field == .originalTitle
        || evidence.contains(RuleCondition.normalize(value))
    }
  }

  private func originalBaseName(_ item: ItemSnapshot) -> String {
    item.kind == .file && !item.fileExtension.isEmpty
      ? URL(fileURLWithPath: item.name).deletingPathExtension().lastPathComponent
      : item.name
  }

  private func normalizedKey(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }
}
