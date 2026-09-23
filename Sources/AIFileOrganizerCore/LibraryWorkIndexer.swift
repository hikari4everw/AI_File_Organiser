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
        // “分类/作者/作品”和“分类/分类/作品”结构上无法区分，不能一律当成作者容器，
        // 否则深层分类目录会从目标列表消失。只有名字确实能在子作品名里作为社团或
        // 作者出现时，才认定它是作者容器；否则按分类处理，用户仍可手动纠正。
        role = Self.looksLikeCreatorContainer(
          name: directory.lastPathComponent,
          childWorkNames: directories.map { $0.0.lastPathComponent })
          ? .creator : .category
      } else if depth > 1, directories.isEmpty,
        files.allSatisfy({ ["pdf", "cbz", "zip", "rar", "7z", "epub"].contains(
          $0.0.pathExtension.lowercased()) })
      {
        // 同一类歧义：只放压缩包/PDF 的层，既可能是作者容器，也可能是子分类。
        role = Self.looksLikeCreatorContainer(
          name: directory.lastPathComponent,
          childWorkNames: files.map { $0.0.lastPathComponent })
          ? .creator : .category
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

  /// 判定一个中间层是不是作者（社团）容器。结构上无法区分“分类/作者/作品”和
  /// “分类/分类/作品”，所以必须要有额外证据，满足任一条即可：
  /// 1. 该层名字本身是 `[社团] 作者` / `[社团 (作者)]` 这种作者目录写法；
  /// 2. 该层名字能在子作品名里作为社团或作者出现。
  /// 第 1 条不可省：作者目录里的作品通常只写标题（如“旧作”），此时第 2 条不成立。
  /// 两条都不成立时按分类处理，避免深层分类目录从目标列表整体消失。
  static func looksLikeCreatorContainer(name: String, childWorkNames: [String]) -> Bool {
    let key = CreatorCatalog.key(name)
    guard !key.isEmpty else { return false }
    if WorkNameParser().parse(name).circleName != nil { return true }
    for childName in childWorkNames {
      let parsed = WorkNameParser().parse(childName)
      let fields = [parsed.circleName].compactMap { $0 } + parsed.authorNames
      if fields.contains(where: { CreatorCatalog.key($0) == key }) { return true }
    }
    return false
  }
}
