import Foundation
import UniformTypeIdentifiers

public struct LearningService: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) { self.database = database }

  public func recordSuccessfulOperation(
    libraryID: UUID,
    sessionID: UUID,
    operationID: UUID,
    itemIdentity: String,
    destinationID: UUID,
    features: DecisionFeatures,
    confirmation: LearningConfirmation
  ) throws {
    try database.saveLearningSample(
      LearningSample(
        libraryID: libraryID,
        sessionID: sessionID,
        operationID: operationID,
        itemIdentity: itemIdentity,
        destinationID: destinationID,
        features: features,
        confirmation: confirmation
      ))
  }

  public func retract(operationID: UUID) throws {
    try database.retractLearningSample(operationID: operationID)
  }

  public func activeSamples(libraryID: UUID) throws -> [LearningSample] {
    try database.learningSamples(libraryID: libraryID, activeOnly: true)
  }

  public func refreshExistingLibrarySamples(
    libraryID: UUID,
    root: URL,
    destinations: [DestinationProfile],
    maximumPerDestination: Int = 12,
    maximumTotal: Int = 60
  ) throws {
    var samples: [LearningSample] = []
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    for destination in destinations where destination.kind == .category {
      if samples.count >= maximumTotal { break }
      let directory = root.appendingPathComponent(destination.relativePath, isDirectory: true)
      guard let children = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      ).sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
      else { continue }
      for child in children.prefix(max(1, maximumPerDestination)) {
        if samples.count >= maximumTotal { break }
        guard let values = try? child.resourceValues(forKeys: [
          .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        ]), values.isHidden != true, values.isSymbolicLink != true else { continue }
        let kind: ItemKind = values.isDirectory == true
          ? (values.isPackage == true ? .applicationBundle : .directory) : .file
        samples.append(LearningSample(
          libraryID: libraryID,
          sessionID: sessionID,
          itemIdentity: destination.relativePath + "/" + child.lastPathComponent,
          destinationID: destination.id,
          features: DecisionFeatures(
            itemKind: kind,
            fileExtension: child.pathExtension,
            keywords: KeywordTokenizer.tokens(from: child.deletingPathExtension().lastPathComponent)
          ),
          confirmation: .existingLibrary
        ))
      }
    }
    try database.replaceExistingLibrarySamples(libraryID: libraryID, samples: samples)
  }

  public func enrich(destinations: [DestinationProfile], libraryID: UUID) throws
    -> [DestinationProfile]
  {
    let grouped = Dictionary(grouping: try activeSamples(libraryID: libraryID), by: \.destinationID)
    return destinations.map { destination in
      guard let samples = grouped[destination.id], !samples.isEmpty else { return destination }
      var result = destination
      result.keywords = Array(Set(result.keywords + samples.flatMap { $0.features.keywords })).sorted()
      let inferredTypes = samples.compactMap {
        let fileExtension = $0.features.fileExtension.lowercased()
        if fileExtension == "pdf" { return UTType.pdf.identifier }
        return UTType(filenameExtension: fileExtension)?.identifier
      }
      result.sampleContentTypes = Array(Set(result.sampleContentTypes + inferredTypes)).sorted()
      return result
    }
  }

  public func suggestRules(libraryID: UUID) throws -> [RuleSuggestion] {
    let samples = try activeSamples(libraryID: libraryID).filter {
      $0.confirmation == .userApproved
    }
    let groups = Dictionary(grouping: samples, by: \.destinationID)
    return groups.compactMap { destinationID, values in
      let uniqueItems = Dictionary(grouping: values, by: \.itemIdentity).compactMap(\.value.first)
      guard uniqueItems.count >= 3 else { return nil }
      let commonKeywords = uniqueItems.dropFirst().reduce(Set(uniqueItems[0].features.keywords)) {
        $0.intersection($1.features.keywords)
      }
      guard let keyword = commonKeywords.sorted().first else { return nil }
      return RuleSuggestion(
        libraryID: libraryID,
        destinationID: destinationID,
        condition: RuleCondition(filenameKeywords: [keyword]),
        supportingSampleIDs: uniqueItems.map(\.id)
      )
    }
  }
}
