import Foundation

public struct FilenameSuggestionPipeline: Sendable {
  private let extractor: any ContentExtractor
  private let provider: any FilenameSuggestionProvider
  private let semanticEvaluator: any SemanticNamingConditionEvaluator
  private let detector: FilenameQualityDetector
  private let directoryAnalyzer: DirectoryAnalyzer

  public init(
    extractor: any ContentExtractor = NativeContentExtractor(),
    provider: any FilenameSuggestionProvider = AppleFilenameSuggestionProvider(),
    semanticEvaluator: any SemanticNamingConditionEvaluator =
      AppleSemanticNamingConditionEvaluator(),
    detector: FilenameQualityDetector = .init(),
    directoryAnalyzer: DirectoryAnalyzer = .init()
  ) {
    self.extractor = extractor
    self.provider = provider
    self.semanticEvaluator = semanticEvaluator
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

    let candidateContexts = eligible.filter { candidateIDs.contains($0.id) }
      .compactMap { contexts[$0.id] }
    let ruleEngine = NamingRuleEngine()
    var semanticEvaluationsByItem: [UUID: [UUID: SemanticNamingConditionEvaluation]] = [:]
    for context in candidateContexts {
      for rule in ruleEngine.semanticCandidateRules(context: context, rules: namingRules) {
        let evaluation: SemanticNamingConditionEvaluation
        if semanticEvaluator.isAvailable {
          do {
            evaluation = try await semanticEvaluator.evaluate(
              request: FilenameSuggestionRequest(
                context: context,
                template: rule.template,
                semanticCondition: rule.condition.semanticDescription,
                operations: rule.operations,
                ruleID: rule.id))
          } catch {
            let detail = String(error.localizedDescription.prefix(180))
            evaluation = .uncertain(reason: "语义判断失败：\(detail)")
          }
        } else {
          evaluation = .uncertain(reason: semanticEvaluator.availabilityDescription)
        }
        semanticEvaluationsByItem[context.id, default: [:]][rule.id] = evaluation
      }
    }
    var byItem = Dictionary(uniqueKeysWithValues: ruleEngine.proposals(
      sessionID: sessionID, contexts: candidateContexts, rules: namingRules,
      semanticEvaluationsByItem: semanticEvaluationsByItem
    ).map { ($0.itemID, $0) })

    var requests: [FilenameSuggestionRequest] = []
    for context in candidateContexts where !context.snapshot.isCloudPlaceholder {
      let existing = byItem[context.id]
      let hasConflictingRules = existing?.source == .namingRule
        && existing?.disposition == .blocked && existing?.ruleID == nil
      let hasUnresolvedSemanticRule = semanticEvaluationsByItem[context.id]?.values.contains {
        if case .uncertain = $0 { return true }
        return false
      } == true
      guard !hasConflictingRules, !hasUnresolvedSemanticRule else { continue }
      let needsModel = existing == nil
        ? automaticIDs.contains(context.id) || requestedItemIDs.contains(context.id)
        : existing?.disposition == .blocked
      guard needsModel else { continue }
      let rule = existing?.ruleID.flatMap { id in namingRules.first { $0.id == id } }
      let destinationID = destinationByItem[context.id]
      requests.append(FilenameSuggestionRequest(
        context: context,
        template: rule?.template,
        semanticCondition: rule?.condition.semanticDescription,
        operations: rule?.operations ?? [],
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
          let fields = deterministicFields(request.context)
            .merging(
              verifiedFields(output.fields, context: request.context),
              uniquingKeysWith: { _, verified in verified })
          var missing: [FilenameField] = []
          let templatePattern: String?
          if !request.operations.isEmpty {
            guard let rendered = try? NamingOperationEngine().render(
              operations: request.operations,
              baseName: originalBaseName(item),
              fields: fields)
            else { continue }
            baseName = rendered.missingFields.isEmpty ? rendered.value : originalBaseName(item)
            missing = rendered.missingFields
            templatePattern = request.template?.pattern
          } else {
            baseName = output.suggestedBaseName
            templatePattern = inferredTemplatePattern(baseName: baseName, fields: fields)
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
            templatePattern: templatePattern,
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
      field != .date && field != .originalTitle
        && evidence.contains(RuleCondition.normalize(value))
    }
  }

  private func originalBaseName(_ item: ItemSnapshot) -> String {
    item.kind == .file && !item.fileExtension.isEmpty
      ? URL(fileURLWithPath: item.name).deletingPathExtension().lastPathComponent
      : item.name
  }

  private func inferredTemplatePattern(
    baseName: String, fields: [FilenameField: String]
  ) -> String? {
    let learnableFields: Set<FilenameField> = [.title, .author, .date]
    let replacements = fields.filter { learnableFields.contains($0.key) && !$0.value.isEmpty }
      .sorted { $0.value.count > $1.value.count }
    var pattern = baseName
    for (field, value) in replacements where pattern.contains(value) {
      pattern = pattern.replacingOccurrences(of: value, with: "{\(field.placeholder)}")
    }
    guard pattern != baseName else { return nil }
    let template = FilenameTemplate(pattern: pattern)
    guard let rendered = try? FilenameTemplateEngine().render(template: template, fields: fields),
      rendered.missingFields.isEmpty, rendered.value == baseName
    else { return nil }
    return pattern
  }

  private func normalizedKey(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }
}
