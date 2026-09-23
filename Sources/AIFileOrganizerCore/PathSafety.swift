import Foundation

public enum PathSafety {
  public static func normalized(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }

  public static func contains(_ parent: URL, _ child: URL) -> Bool {
    let parentParts = normalized(parent).pathComponents
    let childParts = normalized(child).pathComponents
    return childParts.count > parentParts.count && childParts.starts(with: parentParts)
  }

  public static func validateWorkspace(inbox: URL, library: URL) throws -> (String, String) {
    let fileManager = FileManager.default
    var inboxIsDirectory: ObjCBool = false
    var libraryIsDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: inbox.path, isDirectory: &inboxIsDirectory),
      inboxIsDirectory.boolValue
    else {
      throw OrganizerError.invalidWorkspace("收件箱不存在或不是目录")
    }
    guard fileManager.fileExists(atPath: library.path, isDirectory: &libraryIsDirectory),
      libraryIsDirectory.boolValue
    else {
      throw OrganizerError.invalidWorkspace("资料库不存在或不是目录")
    }
    let a = normalized(inbox)
    let b = normalized(library)
    guard a != b, !contains(a, b), !contains(b, a) else {
      throw OrganizerError.invalidWorkspace("收件箱与资料库不能相同或互相包含")
    }
    let inboxVolume = try volumeIdentifier(for: a)
    let libraryVolume = try volumeIdentifier(for: b)
    guard inboxVolume == libraryVolume else {
      throw OrganizerError.invalidWorkspace("V2.0 只支持同卷整理")
    }
    return (inboxVolume, libraryVolume)
  }

  public static func volumeIdentifier(for url: URL) throws -> String {
    let values = try url.resourceValues(forKeys: [.volumeIdentifierKey])
    guard let value = values.volumeIdentifier else {
      throw OrganizerError.invalidWorkspace("无法识别目录所在卷")
    }
    return String(describing: value)
  }

  public static func isDirectChild(_ child: URL, of parent: URL) -> Bool {
    normalized(child).deletingLastPathComponent() == normalized(parent)
  }

  public static func safeDestination(library: URL, relativePath: String) throws -> URL {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("..") else {
      throw OrganizerError.invalidWorkspace("目标目录不合法")
    }
    var componentURL = normalized(library)
    for component in relativePath.split(separator: "/") {
      componentURL.appendPathComponent(String(component), isDirectory: true)
      if (try? componentURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
        throw OrganizerError.invalidWorkspace("目标目录不能经过符号链接")
      }
    }
    let result = normalized(library.appendingPathComponent(relativePath, isDirectory: true))
    guard contains(library, result) else {
      throw OrganizerError.invalidWorkspace("目标目录超出资料库范围")
    }
    return result
  }

  public static func validateFolderName(_ raw: String) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard !value.isEmpty else { throw OrganizerError.invalidFolderName("目录名称不能为空") }
    guard !value.hasPrefix(".") else { throw OrganizerError.invalidFolderName("不能创建隐藏目录") }
    guard value.count <= 80 else { throw OrganizerError.invalidFolderName("目录名称不能超过 80 个字符") }
    guard !value.contains("/"), !value.contains(":"), value != ".", value != ".." else {
      throw OrganizerError.invalidFolderName("目录名称包含非法字符")
    }
    return value
  }

  public static func normalizedFolderKey(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  public static func normalizedCollisionKey(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  public static func normalizedCollisionKey(_ url: URL) -> String {
    normalizedCollisionKey(normalized(url).path)
  }
}
