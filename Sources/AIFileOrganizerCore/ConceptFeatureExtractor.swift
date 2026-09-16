import AppKit
import Foundation
import ImageIO
import PDFKit

public protocol ImageEmbeddingProvider: Sendable {
  var modelVersion: String { get }
  func embedding(for image: CGImage) throws -> [Float]
}

public struct ConceptFeatureExtractor: Sendable {
  private let provider: any ImageEmbeddingProvider
  private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic"]

  public init(provider: any ImageEmbeddingProvider) { self.provider = provider }

  public func extract(item: ItemSnapshot) async throws -> ConceptFeatureSnapshot? {
    guard !item.isSymbolicLink, !item.isCloudPlaceholder,
      item.kind != .applicationBundle else { return nil }
    let url = URL(fileURLWithPath: item.path, isDirectory: item.kind == .directory)
    guard let values = try? url.resourceValues(forKeys: [
      .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .isPackageKey,
    ]), values.isSymbolicLink != true, values.isPackage != true
    else { return nil }
    let files: [URL]
    if values.isDirectory == true {
      files = candidateFiles(in: url)
    } else if values.isRegularFile == true {
      files = [url]
    } else {
      return nil
    }
    var vectors: [[Float]] = []
    for index in Self.representativePositions(count: files.count) {
      try Task.checkCancellation()
      let file = files[index]
      for image in images(in: file, limit: 5 - vectors.count) {
        try Task.checkCancellation()
        let vector = try provider.embedding(for: image)
        if !vector.isEmpty, vector.allSatisfy(\.isFinite) { vectors.append(vector) }
        if vectors.count == 5 { break }
      }
      if vectors.count == 5 { break }
    }
    guard let first = vectors.first, vectors.allSatisfy({ $0.count == first.count }) else {
      return nil
    }
    var mean = [Float](repeating: 0, count: first.count)
    for vector in vectors {
      for index in mean.indices { mean[index] += vector[index] / Float(vectors.count) }
    }
    let length = sqrt(mean.reduce(Float(0)) { $0 + $1 * $1 })
    guard length > 0, length.isFinite else { return nil }
    return ConceptFeatureSnapshot(
      modelVersion: provider.modelVersion, itemKind: item.kind,
      visualVector: mean.map { $0 / length })
  }

  public static func representativePositions(count: Int) -> [Int] {
    guard count > 0 else { return [] }
    let samples = min(5, count)
    guard samples > 1 else { return [0] }
    return Array(Set((0..<samples).map {
      Int((Double($0) * Double(count - 1) / Double(samples - 1)).rounded())
    })).sorted()
  }

  private func candidateFiles(in root: URL) -> [URL] {
    var pending: [(URL, Int)] = [(root, 0)]
    var inspected = 0
    var files: [URL] = []
    while !pending.isEmpty, inspected < 200 {
      let (parent, depth) = pending.removeFirst()
      if depth >= 2 { continue }
      guard let children = try? FileManager.default.contentsOfDirectory(
        at: parent, includingPropertiesForKeys: [
          .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .isPackageKey, .isHiddenKey,
        ], options: [.skipsHiddenFiles]) else { continue }
      for child in children.sorted(by: {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }) {
        if inspected >= 200 { break }
        guard let values = try? child.resourceValues(forKeys: [
          .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .isPackageKey, .isHiddenKey,
        ]), values.isSymbolicLink != true, values.isPackage != true,
          values.isHidden != true else { continue }
        inspected += 1
        if values.isDirectory == true {
          pending.append((child, depth + 1))
        } else if values.isRegularFile == true,
          imageExtensions.contains(child.pathExtension.lowercased())
            || ["pdf", "epub"].contains(child.pathExtension.lowercased())
        {
          files.append(child)
        }
      }
    }
    return files.sorted {
      $0.path.localizedStandardCompare($1.path) == .orderedAscending
    }
  }

  private func images(in url: URL, limit: Int) -> [CGImage] {
    guard limit > 0 else { return [] }
    let ext = url.pathExtension.lowercased()
    if ext == "pdf" {
      guard let document = PDFDocument(url: url) else { return [] }
      return Self.representativePositions(count: document.pageCount).prefix(limit).compactMap {
        guard let page = document.page(at: $0) else { return nil }
        let image = page.thumbnail(of: NSSize(width: 512, height: 512), for: .mediaBox)
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
      }
    }
    if ext == "epub" {
      guard let listing = Self.unzip(["-Z1", url.path], maximumBytes: 2_000_000),
        let names = String(data: listing, encoding: .utf8) else { return [] }
      let members = names.split(separator: "\n").map(String.init).filter {
        imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
          && !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..")
      }
      return Self.representativePositions(count: members.count).prefix(limit).compactMap {
        guard let data = Self.unzip(["-p", url.path, members[$0]], maximumBytes: 30_000_000),
          let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return Self.safeThumbnail(from: source)
      }
    }
    guard imageExtensions.contains(ext),
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = Self.safeThumbnail(from: source)
    else { return [] }
    return [image]
  }

  static func safeDimensions(width: Int, height: Int) -> Bool {
    width > 0 && height > 0 && width <= 8192 && height <= 8192
      && Int64(width) * Int64(height) <= 40_000_000
  }

  private static func safeThumbnail(from source: CGImageSource) -> CGImage? {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
      safeDimensions(width: width.intValue, height: height.intValue)
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 512,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private static func unzip(_ arguments: [String], maximumBytes: Int) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    var data = Data()
    while let chunk = try? output.fileHandleForReading.read(upToCount: 65_536),
      !chunk.isEmpty
    {
      if Task<Never, Never>.isCancelled {
        process.terminate()
        process.waitUntilExit()
        return nil
      }
      data.append(chunk)
      if data.count > maximumBytes {
        process.terminate()
        process.waitUntilExit()
        return nil
      }
    }
    process.waitUntilExit()
    return process.terminationStatus == 0 ? data : nil
  }
}
