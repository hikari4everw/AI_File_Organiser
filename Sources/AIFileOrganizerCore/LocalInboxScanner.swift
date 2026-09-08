import Foundation
import UniformTypeIdentifiers

public struct LocalInboxScanner: InboxScanner {
  public init() {}

  public func scan(_ workspace: Workspace, sessionID: UUID) -> AsyncThrowingStream<ScanEvent, Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .userInitiated) {
        continuation.yield(.started)
        let inbox = URL(fileURLWithPath: workspace.inboxPath, isDirectory: true)
        let keys: [URLResourceKey] = [
          .nameKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
          .isHiddenKey, .isPackageKey, .fileSizeKey, .creationDateKey,
          .contentModificationDateKey, .fileResourceIdentifierKey,
          .volumeIdentifierKey, .isUbiquitousItemKey,
        ]
        do {
          let urls = try FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
          )
          var found = 0
          var skipped = 0
          for url in urls.sorted(by: {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
          }) {
            try Task.checkCancellation()
            do {
              let values = try url.resourceValues(forKeys: Set(keys))
              if values.isHidden == true {
                skipped += 1
                continuation.yield(.skipped(path: url.path, reason: "隐藏项目"))
                continue
              }
              if values.isSymbolicLink == true {
                skipped += 1
                continuation.yield(.skipped(path: url.path, reason: "符号链接"))
                continue
              }
              let kind: ItemKind
              if values.isDirectory == true {
                kind = values.isPackage == true ? .applicationBundle : .directory
              } else if values.isRegularFile == true {
                kind = .file
              } else {
                skipped += 1
                continuation.yield(.skipped(path: url.path, reason: "特殊文件"))
                continue
              }
              let cloudStatus =
                values.isUbiquitousItem == true
                ? try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                  .ubiquitousItemDownloadingStatus
                : nil
              let cloudOnly = values.isUbiquitousItem == true && cloudStatus != .current
              let contentType =
                (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                ?? UTType(filenameExtension: url.pathExtension)
              let snapshot = ItemSnapshot(
                sessionID: sessionID,
                path: url.path,
                name: values.name ?? url.lastPathComponent,
                kind: kind,
                contentType: contentType?.identifier,
                fileExtension: url.pathExtension.lowercased(),
                size: Int64(values.fileSize ?? 0),
                creationDate: values.creationDate,
                modificationDate: values.contentModificationDate,
                resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
                volumeIdentifier: values.volumeIdentifier.map { String(describing: $0) },
                isHidden: values.isHidden ?? false,
                isSymbolicLink: values.isSymbolicLink ?? false,
                isCloudPlaceholder: cloudOnly,
                shallowExtensions: kind == .directory ? shallowExtensions(at: url) : []
              )
              found += 1
              continuation.yield(.discovered(snapshot))
            } catch {
              skipped += 1
              continuation.yield(.skipped(path: url.path, reason: error.localizedDescription))
            }
          }
          continuation.yield(.finished(discovered: found, skipped: skipped))
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch {
          continuation.finish(
            throwing: OrganizerError.scanFailed("扫描失败：\(error.localizedDescription)"))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

private func shallowExtensions(at directory: URL) -> [String] {
  guard
    let urls = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    )
  else { return [] }
  var counts: [String: Int] = [:]
  for url in urls.prefix(50) where !url.pathExtension.isEmpty {
    counts[url.pathExtension.lowercased(), default: 0] += 1
  }
  return counts.sorted { lhs, rhs in
    lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
  }.prefix(8).map(\.key)
}
