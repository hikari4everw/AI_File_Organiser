import Foundation

public enum LibraryNodeRole: String, Codable, Hashable, Sendable {
  case category, creator, work, uncertain
}

public struct LibraryWorkNode: Codable, Hashable, Sendable {
  public var relativePath: String
  public var role: LibraryNodeRole
  public var kind: ItemKind

  public init(relativePath: String, role: LibraryNodeRole, kind: ItemKind) {
    self.relativePath = relativePath
    self.role = role
    self.kind = kind
  }
}

public struct LibraryWorkIndex: Codable, Hashable, Sendable {
  public var nodes: [LibraryWorkNode]

  public init(nodes: [LibraryWorkNode]) { self.nodes = nodes }

  public var destinations: [LibraryWorkNode] { nodes.filter { $0.role == .category } }
}

public struct LibraryWorkIndexer: Sendable {
  private let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "webp", "heic", "gif", "tiff", "bmp",
  ]

  public init() {}

  public func index(
    root: URL, roleOverrides: [String: LibraryNodeRole] = [:]
  ) throws -> LibraryWorkIndex {
    var nodes: [LibraryWorkNode] = []
    try visit(root, relativePath: "", depth: 0, roleOverrides: roleOverrides, nodes: &nodes)
    return LibraryWorkIndex(nodes: nodes.sorted { $0.relativePath < $1.relativePath })
  }

  @discardableResult
  private func visit(
    _ directory: URL, relativePath: String, depth: Int,
    roleOverrides: [String: LibraryNodeRole], nodes: inout [LibraryWorkNode]
  ) throws -> LibraryNodeRole {
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isHiddenKey, .isSymbolicLinkKey, .isPackageKey,
    ]
    let children: [URL]
    do {
      children = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    } catch {
      guard depth > 0 else { throw error }
      nodes.append(LibraryWorkNode(relativePath: relativePath, role: .uncertain,
        kind: .directory))
      return .uncertain
    }
    var directories: [(URL, String)] = []
    var files: [(URL, String)] = []
    for child in children {
      guard let values = try? child.resourceValues(forKeys: keys),
        values.isHidden != true, values.isSymbolicLink != true, values.isPackage != true
      else { continue }
      let childPath = relativePath.isEmpty ? child.lastPathComponent
        : relativePath + "/" + child.lastPathComponent
      if values.isDirectory == true {
        directories.append((child, childPath))
      } else if values.isRegularFile == true {
        files.append((child, childPath))
      }
    }

    let pageCount = files.filter {
      imageExtensions.contains($0.0.pathExtension.lowercased())
    }.count
    let role: LibraryNodeRole
    let metadataExtensions: Set<String> = ["txt", "nfo", "json", "xml"]
    let nonPages = files.filter { !imageExtensions.contains($0.0.pathExtension.lowercased()) }
    if depth > 0, pageCount > 0, directories.isEmpty,
      nonPages.allSatisfy({ metadataExtensions.contains($0.0.pathExtension.lowercased()) })
    {
      role = .work
    } else {
      var childRoles: [LibraryNodeRole] = []
      for (child, path) in directories {
        childRoles.append(try visit(child, relativePath: path, depth: depth + 1,
          roleOverrides: roleOverrides, nodes: &nodes))
      }
      for (file, path) in files where depth > 0 {
        if !imageExtensions.contains(file.pathExtension.lowercased()) {
          nodes.append(LibraryWorkNode(relativePath: path, role: .work, kind: .file))
        }
      }
      if depth > 0 && directories.isEmpty && files.isEmpty {
        role = .uncertain
      } else if depth == 1 {
        role = .category
      } else if depth > 1, pageCount > 0, !directories.isEmpty {
        role = .uncertain
      } else if depth > 1, !childRoles.isEmpty,
        childRoles.allSatisfy({ $0 == .work }), files.isEmpty
      {
        role = .creator
      } else if depth > 1, directories.isEmpty,
        files.allSatisfy({ ["pdf", "cbz", "zip", "rar", "7z", "epub"].contains(
          $0.0.pathExtension.lowercased()) })
      {
        role = .creator
      } else {
        role = .category
      }
      if depth > 1, pageCount > 0, !directories.isEmpty {
        for index in nodes.indices
        where nodes[index].relativePath.hasPrefix(relativePath + "/")
          && roleOverrides[nodes[index].relativePath] == nil {
          nodes[index].role = .uncertain
        }
      }
    }
    if depth > 0 {
      nodes.append(LibraryWorkNode(relativePath: relativePath,
        role: roleOverrides[relativePath] ?? role, kind: .directory))
    }
    return roleOverrides[relativePath] ?? role
  }
}
