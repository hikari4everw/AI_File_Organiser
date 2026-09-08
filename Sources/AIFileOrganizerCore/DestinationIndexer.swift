import Foundation
import UniformTypeIdentifiers

public struct DestinationIndexer: Sendable {
  public init() {}

  public func index(workspace: Workspace) throws -> [DestinationProfile] {
    let library = URL(fileURLWithPath: workspace.libraryPath, isDirectory: true)
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]
    let direct = try FileManager.default.contentsOfDirectory(
      at: library,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    ).filter { url in
      let values = try? url.resourceValues(forKeys: keys)
      return values?.isDirectory == true && values?.isHidden != true
    }
    let pinned = workspace.pinnedDestinationPaths.map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    .filter { PathSafety.contains(library, $0) }
    let unique = Dictionary(grouping: direct + pinned, by: { PathSafety.normalized($0).path })

    return unique.keys.sorted().map { path in
      let url = URL(fileURLWithPath: path, isDirectory: true)
      let relative = relativePath(of: url, inside: library)
      let samples = sampleTypes(in: url)
      return DestinationProfile(
        id: stableUUID(for: relative),
        relativePath: relative,
        displayName: url.lastPathComponent,
        keywords: KeywordTokenizer.tokens(from: url.lastPathComponent),
        sampleContentTypes: samples,
        isPinned: pinned.contains(where: { PathSafety.normalized($0) == PathSafety.normalized(url) }
        )
      )
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

  private func stableUUID(for value: String) -> UUID {
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
