import Foundation

public struct CreatorIdentity: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var workspaceID: UUID
  public var japaneseName: String?
  public var englishName: String?
  public var circleName: String?
  public var aliasSources: [String: String]
  public var preferredDestinations: [String: String]

  public init(
    id: UUID = UUID(), workspaceID: UUID, japaneseName: String?,
    englishName: String?, circleName: String?,
    aliasSources: [String: String] = [:], preferredDestinations: [String: String] = [:]
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.japaneseName = japaneseName
    self.englishName = englishName
    self.circleName = circleName
    self.aliasSources = aliasSources
    self.preferredDestinations = preferredDestinations
  }

  public var proposedDirectoryName: String {
    let base: String
    switch (japaneseName, englishName) {
    case (let japanese?, let english?) where CreatorCatalog.key(japanese) != CreatorCatalog.key(english):
      base = "\(japanese) (\(english))"
    case (let japanese?, _): base = japanese
    case (_, let english?): base = english
    default: base = ""
    }
    guard let circleName, !circleName.isEmpty else { return base }
    return "[\(circleName)] \(base)"
  }
}

public enum CreatorResolution: Hashable, Sendable {
  case confirmed(CreatorIdentity)
  case candidates([CreatorIdentity])
  case unknown
  case ambiguous
}

public struct CreatorCatalog: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) { self.database = database }

  public func create(
    workspaceID: UUID, japaneseName: String?, englishName: String?, circleName: String?
  ) throws -> CreatorIdentity {
    let creator = CreatorIdentity(
      workspaceID: workspaceID,
      japaneseName: japaneseName?.trimmingCharacters(in: .whitespacesAndNewlines),
      englishName: englishName?.trimmingCharacters(in: .whitespacesAndNewlines),
      circleName: circleName?.trimmingCharacters(in: .whitespacesAndNewlines))
    try database.saveCreatorIdentity(creator)
    return creator
  }

  public func confirmAlias(_ alias: String, for creatorID: UUID, sourceURL: String) throws {
    guard var creator = try database.creatorIdentity(id: creatorID) else {
      throw OrganizerError.persistenceFailed("作者不存在")
    }
    let name = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw OrganizerError.invalidFolderName("作者别名不能为空") }
    creator.aliasSources[name] = sourceURL
    if creator.englishName == nil,
      name.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }),
      name.unicodeScalars.allSatisfy({ $0.value < 0x0250 }) {
      creator.englishName = name
    }
    try database.saveCreatorIdentity(creator)
  }

  public func bindDestination(
    _ relativePath: String, for creatorID: UUID, categoryPath: String
  ) throws {
    guard var creator = try database.creatorIdentity(id: creatorID) else {
      throw OrganizerError.persistenceFailed("作者不存在")
    }
    guard relativePath.hasPrefix(categoryPath + "/"),
      !relativePath.dropFirst(categoryPath.count + 1).contains("/")
    else { throw OrganizerError.invalidFolderName("作者目录必须位于分类目录下") }
    creator.preferredDestinations[categoryPath] = relativePath
    try database.saveCreatorIdentity(creator)
  }

  public func resolve(_ parsed: ParsedWorkName, workspaceID: UUID) throws -> CreatorResolution {
    if parsed.hasMultipleAuthors { return .ambiguous }
    guard !parsed.authorNames.isEmpty else { return .unknown }
    let names = Set(parsed.authorNames.map(Self.key))
    let creators = try database.creatorIdentities(workspaceID: workspaceID)
    let exact = creators.filter { creator in
      let aliases = [creator.japaneseName, creator.englishName].compactMap { $0 }
        + Array(creator.aliasSources.keys)
      return aliases.contains { names.contains(Self.key($0)) }
    }
    if exact.count == 1 { return .confirmed(exact[0]) }
    if exact.count > 1 { return .candidates(exact) }
    let circles = creators.filter { creator in
      guard let parsedCircle = parsed.circleName, let circle = creator.circleName else { return false }
      return Self.key(parsedCircle) == Self.key(circle)
    }
    return circles.isEmpty ? .unknown : .candidates(circles)
  }

  public static func key(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
      .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
