import Foundation

public struct DirectoryManifestEntry: Codable, Hashable, Sendable {
  public var relativePath: String
  public var kind: ItemKind
  public var resourceIdentifier: String?
  public var size: Int64
  public var modificationDate: Date?

  public init(
    relativePath: String,
    kind: ItemKind,
    resourceIdentifier: String?,
    size: Int64,
    modificationDate: Date?
  ) {
    self.relativePath = relativePath
    self.kind = kind
    self.resourceIdentifier = resourceIdentifier
    self.size = size
    self.modificationDate = modificationDate
  }
}

public struct DirectoryManifest: Codable, Hashable, Sendable {
  public var entries: [DirectoryManifestEntry]

  public init(entries: [DirectoryManifestEntry]) {
    self.entries = entries.sorted { $0.relativePath < $1.relativePath }
  }

  public static func capture(
    _ directory: URL,
    fileManager: FileManager = .default,
    maximumEntries: Int = 10_000
  ) throws -> DirectoryManifest {
    let keys: [URLResourceKey] = [
      .isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey,
      .fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey,
    ]
    var pending = (try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: keys,
      options: [.skipsSubdirectoryDescendants]
    )).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    var entries: [DirectoryManifestEntry] = []
    while !pending.isEmpty {
      let url = pending.removeFirst()
      guard entries.count < maximumEntries else {
        throw OrganizerError.scanFailed("目录内容超过安全检查上限：\(maximumEntries) 项")
      }
      let values = try url.resourceValues(forKeys: Set(keys))
      let kind: ItemKind
      if values.isDirectory == true {
        kind = values.isPackage == true ? .applicationBundle : .directory
      } else {
        kind = .file
      }
      let rootPath = PathSafety.normalized(directory).path + "/"
      let relative = String(PathSafety.normalized(url).path.dropFirst(rootPath.count))
      entries.append(
        DirectoryManifestEntry(
          relativePath: relative,
          kind: kind,
          resourceIdentifier: values.fileResourceIdentifier.map(String.init(describing:)),
          size: Int64(values.fileSize ?? 0),
          modificationDate: values.contentModificationDate
        ))
      if kind == .directory, values.isSymbolicLink != true {
        let children = try fileManager.contentsOfDirectory(
          at: url,
          includingPropertiesForKeys: keys,
          options: [.skipsSubdirectoryDescendants]
        ).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        pending.append(contentsOf: children)
      }
    }
    return DirectoryManifest(entries: entries)
  }

  public func matches(_ directory: URL, fileManager: FileManager = .default) -> Bool {
    guard let current = try? Self.capture(
      directory,
      fileManager: fileManager,
      maximumEntries: max(entries.count + 1, 1)
    ) else { return false }
    return current == self
  }
}
