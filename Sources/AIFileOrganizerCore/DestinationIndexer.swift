import Foundation
import UniformTypeIdentifiers

public struct DestinationIndexer: Sendable {
  public init() {}

  public func index(workspace: Workspace) throws -> [DestinationProfile] {
    try index(workspace: workspace, maxDepth: 1)
  }

  public func index(
    workspace: Workspace,
    maxDepth: Int,
    kindsByRelativePath: [String: DestinationKind] = [:]
  ) throws -> [DestinationProfile] {
    let library = URL(fileURLWithPath: workspace.libraryPath, isDirectory: true)
    let rolesByPath = Dictionary(uniqueKeysWithValues: try LibraryWorkIndexer()
      .index(root: library).nodes.map { ($0.relativePath, $0.role) })
    let boundedDepth = max(1, maxDepth)
    var discovered: [(URL, String, Int, DestinationKind)] = []
    try discover(
      parent: library,
      root: library,
      depth: 1,
      maxDepth: boundedDepth,
      kinds: kindsByRelativePath,
      roles: rolesByPath,
      output: &discovered
    )
    return discovered.map { url, relative, depth, kind in
      let samples = sampleTypes(in: url)
      return DestinationProfile(
        id: identifier(for: relative),
        relativePath: relative,
        displayName: url.lastPathComponent,
        keywords: KeywordTokenizer.tokens(from: relative),
        sampleContentTypes: samples,
        isPinned: workspace.pinnedDestinationPaths.contains(url.path),
        kind: kind,
        depth: depth
      )
    }
  }

  private func discover(
    parent: URL,
    root: URL,
    depth: Int,
    maxDepth: Int,
    kinds: [String: DestinationKind],
    roles: [String: LibraryNodeRole],
    output: inout [(URL, String, Int, DestinationKind)]
  ) throws {
    guard depth <= maxDepth else { return }
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey, .isPackageKey,
    ]
    let children = try FileManager.default.contentsOfDirectory(
      at: parent,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    ).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    for child in children {
      guard let values = try? child.resourceValues(forKeys: keys),
        values.isDirectory == true,
        values.isHidden != true,
        values.isSymbolicLink != true,
        values.isPackage != true
      else { continue }
      let relative = relativePath(of: child, inside: root)
      let inferred = roles[relative]
      let kind = kinds[relative] ?? (inferred == .work ? .collection : .category)
      if inferred != .work && inferred != .creator || kinds[relative] != nil {
        output.append((child, relative, depth, kind))
      }
      if kind != .excluded && (kind != .collection || inferred == .creator) {
        try discover(
          parent: child,
          root: root,
          depth: depth + 1,
          maxDepth: maxDepth,
          kinds: kinds,
          roles: roles,
          output: &output
        )
      }
    }
  }

  private func relativePath(of url: URL, inside root: URL) -> String {
    let rootPath = PathSafety.normalized(root).path
    let path = PathSafety.normalized(url).path
    return String(path.dropFirst(rootPath.count)).trimmingCharacters(
      in: CharacterSet(charactersIn: "/"))
  }

  private func sampleTypes(in directory: URL) -> [String] {
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentTypeKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      )
    else { return [] }
    var counts: [String: Int] = [:]
    for url in urls.prefix(50) {
      guard
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier)
          ?? UTType(filenameExtension: url.pathExtension)?.identifier
      else { continue }
      counts[type, default: 0] += 1
    }
    return counts.sorted { $0.value > $1.value }.prefix(8).map(\.key)
  }

  public func identifier(for value: String) -> UUID {
    var hash1: UInt64 = 0xcbf2_9ce4_8422_2325
    var hash2: UInt64 = 0x8422_2325_cbf2_9ce4
    for byte in value.utf8 {
      hash1 = (hash1 ^ UInt64(byte)) &* 0x100_0000_01b3
      hash2 = (hash2 ^ UInt64(byte &+ 31)) &* 0x100_0000_01b3
    }
    var bytes =
      withUnsafeBytes(of: hash1.bigEndian, Array.init)
      + withUnsafeBytes(of: hash2.bigEndian, Array.init)
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}

public enum KeywordTokenizer {
  public static func tokens(from text: String) -> [String] {
    let folded = text.precomposedStringWithCanonicalMapping
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    let pieces = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count >= 2 }
    return Array(Set(pieces)).sorted()
  }
}
