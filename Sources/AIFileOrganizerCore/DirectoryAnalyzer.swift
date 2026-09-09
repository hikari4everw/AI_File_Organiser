import Foundation

public struct DirectoryAnalyzer: Sendable {
  public let maximumDepth: Int
  public let maximumEntries: Int
  public let maximumRepresentativeFiles: Int

  public init(
    maximumDepth: Int = 2,
    maximumEntries: Int = 200,
    maximumRepresentativeFiles: Int = 5
  ) {
    self.maximumDepth = max(1, maximumDepth)
    self.maximumEntries = max(1, maximumEntries)
    self.maximumRepresentativeFiles = max(0, maximumRepresentativeFiles)
  }

  public func analyze(_ directory: URL) async -> DirectorySummary {
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isHiddenKey, .isSymbolicLinkKey, .isPackageKey,
    ]
    var pending: [(URL, Int)] = [(directory, 0)]
    var inspected = 0
    var files = 0
    var directories = 0
    var extensions: [String: Int] = [:]
    var representatives: [String] = []
    var numericNames = 0
    var wasTruncated = false

    while !pending.isEmpty {
      if Task.isCancelled { break }
      let (parent, parentDepth) = pending.removeFirst()
      guard parentDepth < maximumDepth else { continue }
      guard let children = try? FileManager.default.contentsOfDirectory(
        at: parent,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      ).sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
      else { continue }
      for child in children {
        if inspected >= maximumEntries {
          wasTruncated = true
          break
        }
        if Task.isCancelled { break }
        guard let values = try? child.resourceValues(forKeys: keys),
          values.isHidden != true,
          values.isSymbolicLink != true
        else { continue }
        inspected += 1
        if values.isDirectory == true {
          directories += 1
          if values.isPackage != true { pending.append((child, parentDepth + 1)) }
        } else if values.isRegularFile == true {
          files += 1
          let ext = child.pathExtension.lowercased()
          if !ext.isEmpty { extensions[ext, default: 0] += 1 }
          if representatives.count < maximumRepresentativeFiles {
            representatives.append(child.lastPathComponent)
          }
          if Int(child.deletingPathExtension().lastPathComponent) != nil { numericNames += 1 }
        }
      }
      if wasTruncated { break }
    }
    return DirectorySummary(
      inspectedCount: inspected,
      fileCount: files,
      directoryCount: directories,
      extensionCounts: extensions,
      representativeFiles: representatives,
      hasSequentialNames: files >= 3 && Double(numericNames) / Double(files) >= 0.6,
      wasTruncated: wasTruncated
    )
  }
}
