import CryptoKit
import Foundation

public struct CatalogWorkAnalysis: Codable, Hashable, Sendable {
  public var relativePath: String
  public var fingerprint: String
  public var representativePaths: [String]
  public var extractedText: String
  public var contentStatus: ContentExtractionStatus
  public var visualVector: [Float]

  public init(
    relativePath: String, fingerprint: String, representativePaths: [String],
    extractedText: String, contentStatus: ContentExtractionStatus,
    visualVector: [Float] = []
  ) {
    self.relativePath = relativePath
    self.fingerprint = fingerprint
    self.representativePaths = representativePaths
    self.extractedText = extractedText
    self.contentStatus = contentStatus
    self.visualVector = visualVector
  }
}

public struct CatalogProfileOverride: Codable, Hashable, Sendable {
  public var purpose: String
  public var excludedWorkPaths: Set<String>
  public var referenceWorkPaths: Set<String>
  public var role: LibraryNodeRole?

  public init(
    purpose: String = "", excludedWorkPaths: Set<String> = [],
    referenceWorkPaths: Set<String> = [], role: LibraryNodeRole? = nil
  ) {
    self.purpose = purpose
    self.excludedWorkPaths = excludedWorkPaths
    self.referenceWorkPaths = referenceWorkPaths
    self.role = role
  }

  private enum CodingKeys: String, CodingKey {
    case purpose, excludedWorkPaths, referenceWorkPaths, role
  }

  public init(from decoder: Decoder) throws {
    let value = try decoder.container(keyedBy: CodingKeys.self)
    purpose = try value.decodeIfPresent(String.self, forKey: .purpose) ?? ""
    excludedWorkPaths = try value.decodeIfPresent(Set<String>.self,
      forKey: .excludedWorkPaths) ?? []
    referenceWorkPaths = try value.decodeIfPresent(Set<String>.self,
      forKey: .referenceWorkPaths) ?? []
    role = try value.decodeIfPresent(LibraryNodeRole.self, forKey: .role)
  }
}

public struct CatalogProfile: Codable, Hashable, Sendable {
  public var relativePath: String
  public var workNames: [String]
  public var nameFrequencies: [String: Int]
  public var totalWorks: Int
  public var contentAnalyzedWorks: Int
  public var userPurpose: String
  public var referenceWorkPaths: Set<String>
  public var excludedWorkPaths: Set<String>

  public init(
    relativePath: String, workNames: [String], nameFrequencies: [String: Int],
    totalWorks: Int, contentAnalyzedWorks: Int, userPurpose: String,
    referenceWorkPaths: Set<String>, excludedWorkPaths: Set<String> = []
  ) {
    self.relativePath = relativePath
    self.workNames = workNames
    self.nameFrequencies = nameFrequencies
    self.totalWorks = totalWorks
    self.contentAnalyzedWorks = contentAnalyzedWorks
    self.userPurpose = userPurpose
    self.referenceWorkPaths = referenceWorkPaths
    self.excludedWorkPaths = excludedWorkPaths
  }
}

public struct CatalogAnalysisResult: Codable, Hashable, Sendable {
  public var profiles: [CatalogProfile]
  public var workAnalyses: [CatalogWorkAnalysis]
  public var reusedWorkCount: Int
  public var revision: String

  public init(
    profiles: [CatalogProfile], workAnalyses: [CatalogWorkAnalysis],
    reusedWorkCount: Int, revision: String
  ) {
    self.profiles = profiles
    self.workAnalyses = workAnalyses
    self.reusedWorkCount = reusedWorkCount
    self.revision = revision
  }
}

public struct CatalogAnalysisService: Sendable {
  private let database: AppDatabase
  private let extractor: any ContentExtractor
  private let modelManager: ConceptModelManager
  private let version = "catalog-v2"
  private let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "webp", "heic", "gif", "tiff", "bmp",
  ]

  public init(
    database: AppDatabase, extractor: any ContentExtractor = NativeContentExtractor(
      maximumPDFPages: 5),
    modelManager: ConceptModelManager = ConceptModelManager()
  ) {
    self.database = database
    self.extractor = extractor
    self.modelManager = modelManager
  }

  public func setPurpose(_ purpose: String, for path: String, workspaceID: UUID) throws {
    var value = try database.catalogProfileOverride(workspaceID: workspaceID, path: path)
      ?? CatalogProfileOverride()
    value.purpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
    try database.saveCatalogProfileOverride(value, workspaceID: workspaceID, path: path)
  }

  public func setRole(_ role: LibraryNodeRole?, for path: String, workspaceID: UUID) throws {
    var value = try database.catalogProfileOverride(workspaceID: workspaceID, path: path)
      ?? CatalogProfileOverride()
    value.role = role
    try database.saveCatalogProfileOverride(value, workspaceID: workspaceID, path: path)
  }

  public func setExcluded(
    _ excluded: Bool, workPath: String, categoryPath: String, workspaceID: UUID
  ) throws {
    guard workPath.hasPrefix(categoryPath + "/") else {
      throw OrganizerError.invalidWorkspace("作品不属于所选分类")
    }
    var value = try database.catalogProfileOverride(workspaceID: workspaceID, path: categoryPath)
      ?? CatalogProfileOverride()
    if excluded { value.excludedWorkPaths.insert(workPath) }
    else { value.excludedWorkPaths.remove(workPath) }
    try database.saveCatalogProfileOverride(value, workspaceID: workspaceID, path: categoryPath)
  }

  public func setReference(
    _ reference: Bool, workPath: String, categoryPath: String, workspaceID: UUID
  ) throws {
    guard workPath.hasPrefix(categoryPath + "/") else {
      throw OrganizerError.invalidWorkspace("作品不属于所选分类")
    }
    var value = try database.catalogProfileOverride(workspaceID: workspaceID, path: categoryPath)
      ?? CatalogProfileOverride()
    if reference { value.referenceWorkPaths.insert(workPath) }
    else { value.referenceWorkPaths.remove(workPath) }
    try database.saveCatalogProfileOverride(value, workspaceID: workspaceID, path: categoryPath)
  }

  public func analyze(
    index: LibraryWorkIndex, workspaceID: UUID, root: URL,
    progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }
  ) async throws -> CatalogAnalysisResult {
    let categories = index.destinations.sorted { $0.relativePath < $1.relativePath }
    let works = index.nodes.filter { $0.role == .work }.sorted { $0.relativePath < $1.relativePath }
    var analyses: [CatalogWorkAnalysis] = []
    var reused = 0
    let featureExtractor: ConceptFeatureExtractor? = (try? modelManager.provider())
      .map(ConceptFeatureExtractor.init(provider:))
    let modelVariant = featureExtractor == nil ? "no-image-model" : ConceptModelManager.modelVersion
    await progress(0, works.count)
    for (workIndex, work) in works.enumerated() {
      try Task.checkCancellation()
      let url = root.appendingPathComponent(work.relativePath)
      let fingerprint: String
      do {
        let snapshot = try FileSnapshot.capture(url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        fingerprint = Self.digest(try encoder.encode(snapshot) + Data((version + modelVariant).utf8))
      } catch {
        analyses.append(CatalogWorkAnalysis(
          relativePath: work.relativePath, fingerprint: "unreadable",
          representativePaths: [], extractedText: "", contentStatus: .unreadable))
        await progress(workIndex + 1, works.count)
        continue
      }
      if let cached = try database.catalogWorkAnalysis(
        workspaceID: workspaceID, path: work.relativePath),
        cached.fingerprint == fingerprint
      {
        analyses.append(cached)
        reused += 1
        await progress(workIndex + 1, works.count)
        continue
      }
      let samples = representativeFiles(at: url, kind: work.kind)
      var texts: [String] = []
      var status: ContentExtractionStatus = samples.isEmpty ? .unsupported : .noText
      for sample in samples {
        try Task.checkCancellation()
        let item = ItemSnapshot(
          sessionID: UUID(), path: sample.path, name: sample.lastPathComponent,
          kind: .file, fileExtension: sample.pathExtension.lowercased())
        let result = await extractor.extractContext(for: item)
        if result.status == .success {
          texts.append(result.text)
          status = .success
        } else if result.status == .unreadable, status != .success {
          status = .unreadable
        }
      }
      var visual: [Float] = []
      if let featureExtractor {
        let item = ItemSnapshot(
          sessionID: UUID(), path: url.path, name: url.lastPathComponent,
          kind: work.kind, fileExtension: url.pathExtension.lowercased())
        visual = (try? await featureExtractor.extract(item: item))?.visualVector ?? []
      }
      let analysis = CatalogWorkAnalysis(
        relativePath: work.relativePath, fingerprint: fingerprint,
        representativePaths: samples.map(\.path),
        extractedText: String(texts.joined(separator: "\n").prefix(4_000)),
        contentStatus: status, visualVector: visual)
      try database.saveCatalogWorkAnalysis(analysis, workspaceID: workspaceID)
      analyses.append(analysis)
      await progress(workIndex + 1, works.count)
    }

    let profiles = try categories.map { category in
      let settings = try database.catalogProfileOverride(
        workspaceID: workspaceID, path: category.relativePath) ?? CatalogProfileOverride()
      let related = analyses.filter { analysis in
        let owner = categories.filter {
          analysis.relativePath.hasPrefix($0.relativePath + "/")
        }.max { $0.relativePath.count < $1.relativePath.count }
        return owner?.relativePath == category.relativePath
          && !settings.excludedWorkPaths.contains(analysis.relativePath)
      }
      let names = related.map { URL(fileURLWithPath: $0.relativePath).lastPathComponent }.sorted()
      var frequencies: [String: Int] = [:]
      for name in names {
        for token in KeywordTokenizer.tokens(from: name) {
          frequencies[token, default: 0] += 1
        }
      }
      return CatalogProfile(
        relativePath: category.relativePath, workNames: names,
        nameFrequencies: frequencies, totalWorks: related.count,
        contentAnalyzedWorks: related.filter {
          $0.contentStatus == .success || $0.contentStatus == .noText || !$0.visualVector.isEmpty
        }.count,
        userPurpose: settings.purpose,
        referenceWorkPaths: settings.referenceWorkPaths,
        excludedWorkPaths: settings.excludedWorkPaths)
    }
    let revisionText = analyses.map { $0.relativePath + ":" + $0.fingerprint }.joined(separator: "|")
      + index.nodes.map { $0.relativePath + ":" + $0.role.rawValue }.joined(separator: "|")
      + profiles.map {
        $0.relativePath + ":" + $0.userPurpose + ":"
          + $0.workNames.joined(separator: ",") + ":"
          + $0.referenceWorkPaths.sorted().joined(separator: ",") + ":"
          + $0.excludedWorkPaths.sorted().joined(separator: ",")
      }.joined(separator: "|")
    return CatalogAnalysisResult(
      profiles: profiles, workAnalyses: analyses, reusedWorkCount: reused,
      revision: Self.digest(Data(revisionText.utf8)))
  }

  private func representativeFiles(at url: URL, kind: ItemKind) -> [URL] {
    guard kind == .directory else { return [url] }
    guard let children = try? FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey],
      options: [.skipsHiddenFiles]) else { return [] }
    let pages = children.filter { file in
      guard let values = try? file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey,
      ]) else { return false }
      return values.isRegularFile == true && values.isSymbolicLink != true
        && values.isHidden != true && imageExtensions.contains(file.pathExtension.lowercased())
    }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    return ConceptFeatureExtractor.representativePositions(count: pages.count).map { pages[$0] }
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
