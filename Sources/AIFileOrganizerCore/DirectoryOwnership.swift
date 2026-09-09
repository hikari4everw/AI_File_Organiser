import Foundation

enum DirectoryOwnership {
  static func markerURL(for operation: PlannedOperation, directory: URL? = nil) -> URL {
    let root = directory ?? URL(fileURLWithPath: operation.destinationPath, isDirectory: true)
    return root.appendingPathComponent(
      ".ai-file-organizer-\(operation.id.uuidString.lowercased()).owner",
      isDirectory: false)
  }

  static func stagingURL(for operation: PlannedOperation) -> URL {
    let destination = URL(fileURLWithPath: operation.destinationPath, isDirectory: true)
    return destination.deletingLastPathComponent().appendingPathComponent(
      ".ai-file-organizer-\(operation.id.uuidString.lowercased()).staging",
      isDirectory: true)
  }

  static func isOwned(
    _ directory: URL,
    by operation: PlannedOperation,
    fileManager: FileManager = .default
  ) -> Bool {
    guard operation.createdByApp,
      fileManager.fileExists(atPath: directory.path),
      let value = try? String(contentsOf: markerURL(for: operation, directory: directory), encoding: .utf8)
    else { return false }
    return value == operation.id.uuidString.lowercased()
  }

  static func install(_ operation: PlannedOperation, fileManager: FileManager = .default) throws {
    let destination = URL(fileURLWithPath: operation.destinationPath, isDirectory: true)
    if fileManager.fileExists(atPath: destination.path) {
      guard isOwned(destination, by: operation, fileManager: fileManager) else {
        throw OrganizerError.operationFailed("目录已经存在，未取得所有权")
      }
      return
    }
    let staging = stagingURL(for: operation)
    if fileManager.fileExists(atPath: staging.path) {
      guard isOwned(staging, by: operation, fileManager: fileManager) else {
        throw OrganizerError.operationFailed("目录暂存路径已被占用")
      }
    } else {
      try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
      do {
        try operation.id.uuidString.lowercased().write(
          to: markerURL(for: operation, directory: staging), atomically: true, encoding: .utf8)
      } catch {
        try? fileManager.removeItem(at: staging)
        throw error
      }
    }
    do {
      try fileManager.moveItem(at: staging, to: destination)
    } catch {
      if isOwned(staging, by: operation, fileManager: fileManager) {
        try? fileManager.removeItem(at: staging)
      }
      throw error
    }
  }

  static func removeIfOwned(
    _ directory: URL,
    by operation: PlannedOperation,
    fileManager: FileManager = .default
  ) throws {
    guard isOwned(directory, by: operation, fileManager: fileManager) else {
      throw OrganizerError.operationFailed("无法验证目录由本应用创建")
    }
    let children = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let markerPath = markerURL(for: operation, directory: directory).standardizedFileURL.path
    let unexpected = children.filter { $0.standardizedFileURL.path != markerPath }
    guard unexpected.isEmpty else {
      throw OrganizerError.operationFailed(
        "目录非空，未删除：\(unexpected.map(\.lastPathComponent).joined(separator: "、"))")
    }
    try fileManager.removeItem(at: directory)
  }
}
