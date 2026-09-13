import Foundation

public struct NamingLearningService: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) { self.database = database }

  public func record(_ sample: NamingSample) throws {
    try database.saveNamingSample(sample)
  }

  public func retract(operationID: UUID) throws {
    try database.retractNamingSample(operationID: operationID)
  }

  public func activeSamples(workspaceID: UUID) throws -> [NamingSample] {
    try database.namingSamples(workspaceID: workspaceID, activeOnly: true)
  }

  public func refreshExistingLibrarySamples(
    workspaceID: UUID,
    root: URL,
    destinations: [DestinationProfile],
    maximumPerDestination: Int = 30
  ) throws {
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    var samples: [NamingSample] = []
    for destination in destinations where destination.kind == .category {
      let directory = root.appendingPathComponent(destination.relativePath, isDirectory: true)
      guard let children = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isHiddenKey, .isSymbolicLinkKey, .isPackageKey, .isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      ).sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
      else { continue }
      for child in children.prefix(max(0, maximumPerDestination)) {
        guard let values = try? child.resourceValues(forKeys: [
          .isHiddenKey, .isSymbolicLinkKey, .isPackageKey, .isDirectoryKey,
        ]), values.isHidden != true, values.isSymbolicLink != true, values.isPackage != true
        else { continue }
        let kind: ItemKind = values.isDirectory == true ? .directory : .file
        let baseName = kind == .file
          ? child.deletingPathExtension().lastPathComponent : child.lastPathComponent
        samples.append(NamingSample(
          workspaceID: workspaceID,
          sessionID: sessionID,
          itemIdentity: destination.relativePath + "/" + child.lastPathComponent,
          destinationID: destination.id,
          source: .existingLibrary,
          features: NamingDecisionFeatures(
            itemKind: kind,
            fileExtension: child.pathExtension,
            originalBaseName: baseName,
            finalBaseName: baseName)
        ))
      }
    }
    try database.replaceExistingNamingSamples(workspaceID: workspaceID, samples: samples)
  }

  public func styleExamples(destinationID: UUID) throws -> [String] {
    try database.namingSamples(destinationID: destinationID, activeOnly: true)
      .filter { $0.source == .existingLibrary }
      .prefix(30)
      .map { $0.features.finalBaseName }
  }

  public func suggestRules(
    workspaceID: UUID,
    now: Date = Date()
  ) throws -> [NamingRuleSuggestion] {
    let cutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
    let eligible = try activeSamples(workspaceID: workspaceID).filter {
      $0.source != .existingLibrary && $0.source != .namingRule
        && $0.createdAt >= cutoff && $0.features.templatePattern != nil
    }
    let grouped = Dictionary(grouping: eligible) { $0.features.templatePattern! }
    let suggestions = grouped.compactMap { pattern, values -> NamingRuleSuggestion? in
      let unique = Dictionary(grouping: values, by: \.itemIdentity).compactMap(\.value.first)
      guard unique.count >= 5, Set(unique.map(\.sessionID)).count >= 2 else { return nil }
      let extensions = Set(unique.map { $0.features.fileExtension }).filter { !$0.isEmpty }
      let condition = extensions.count == 1
        ? RuleCondition(fileExtensions: extensions)
        : RuleCondition(itemKinds: Set(unique.map { $0.features.itemKind }))
      return NamingRuleSuggestion(
        workspaceID: workspaceID,
        condition: condition,
        template: FilenameTemplate(pattern: pattern),
        supportingSampleIDs: unique.map(\.id))
    }
    try database.replaceNamingRuleSuggestions(workspaceID: workspaceID, suggestions: suggestions)
    return suggestions
  }
}
