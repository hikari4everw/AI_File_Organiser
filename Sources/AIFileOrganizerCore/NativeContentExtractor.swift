import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

public actor NativeContentExtractor: ContentExtractor {
  public let maximumCharacters: Int
  public let maximumBytes: Int
  public let maximumPDFPages: Int

  public init(
    maximumCharacters: Int = 4_000, maximumBytes: Int = 1_048_576,
    maximumPDFPages: Int = 3
  ) {
    self.maximumCharacters = maximumCharacters
    self.maximumBytes = maximumBytes
    self.maximumPDFPages = max(1, maximumPDFPages)
  }

  public func extractContext(for item: ItemSnapshot) async -> ExtractedContext {
    guard !Task.isCancelled else { return .init(source: "cancelled", status: .cancelled) }
    guard item.kind == .file else { return .init(source: "not-file", status: .notNeeded) }
    guard !item.isCloudPlaceholder else {
      return .init(source: "cloud-placeholder", status: .cloudPlaceholder)
    }
    let url = URL(fileURLWithPath: item.path)
    if item.fileExtension == "pdf" { return extractPDF(url) }
    if isImage(item) { return extractImageText(url) }
    if isText(item) { return extractText(url) }
    return .init(source: "unsupported", status: .unsupported)
  }

  private func extractText(_ url: URL) -> ExtractedContext {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      return .init(source: "unreadable", status: .unreadable)
    }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: maximumBytes) else {
      return .init(source: "unreadable", status: .unreadable)
    }
    let decoded =
      String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .utf16)
      ?? String(decoding: data, as: UTF8.self)
    return clipped(decoded, source: "text", inputWasLimited: data.count == maximumBytes)
  }

  private func extractPDF(_ url: URL) -> ExtractedContext {
    guard let document = PDFDocument(url: url), document.pageCount > 0 else {
      return .init(source: "unreadable-pdf", status: .unreadable)
    }
    let pageIndices = maximumPDFPages >= 5
      ? ConceptFeatureExtractor.representativePositions(count: document.pageCount)
      : Array(0..<min(document.pageCount, maximumPDFPages))
    let text = pageIndices.compactMap { document.page(at: $0)?.string }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty {
      return clipped(
        text,
        source: maximumPDFPages >= 5 ? "pdf-dispersed-pages" : "pdf-first-pages",
        inputWasLimited: document.pageCount > pageIndices.count
      )
    }
    var recognized: [String] = []
    for index in pageIndices {
      guard let page = document.page(at: index) else { continue }
      let image = page.thumbnail(of: NSSize(width: 1600, height: 1600), for: .mediaBox)
      var rectangle = NSRect(origin: .zero, size: image.size)
      guard let cgImage = image.cgImage(forProposedRect: &rectangle, context: nil, hints: nil)
      else { continue }
      let result = recognize(cgImage, source: "pdf-ocr")
      if result.status == .success { recognized.append(result.text) }
    }
    return recognized.isEmpty
      ? .init(source: "pdf-no-text", status: .noText)
      : clipped(recognized.joined(separator: "\n"), source: "pdf-sampled-ocr",
        inputWasLimited: document.pageCount > pageIndices.count)
  }

  private func extractImageText(_ url: URL) -> ExtractedContext {
    guard let image = NSImage(contentsOf: url) else {
      return .init(source: "unreadable-image", status: .unreadable)
    }
    var proposedRect = NSRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    else {
      return .init(source: "unreadable-image", status: .unreadable)
    }
    return recognize(cgImage, source: "vision-ocr")
  }

  private func recognize(_ cgImage: CGImage, source: String) -> ExtractedContext {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let preferred = ["ja-JP", "zh-Hans", "zh-Hant", "en-US"]
    // 用请求自身的 supportedRecognitionLanguages（macOS 12+）查询，替代已废弃的
    // 类方法 supportedRecognitionLanguages(for:revision:)。必须在设定
    // recognitionLevel 之后调用，返回值才对应准确模式。
    let supported = (try? request.supportedRecognitionLanguages()) ?? []
    request.recognitionLanguages = preferred.filter(supported.contains)
    do {
      try VNImageRequestHandler(cgImage: cgImage).perform([request])
      let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
        separator: "\n")
      guard !text.isEmpty else { return .init(source: source, status: .noText) }
      return clipped(text, source: source, inputWasLimited: false)
    } catch {
      return .init(source: "ocr-failed", status: .unreadable)
    }
  }

  private func clipped(_ text: String, source: String, inputWasLimited: Bool) -> ExtractedContext {
    let clean = text.replacingOccurrences(of: "\0", with: " ")
    let clipped = String(clean.prefix(maximumCharacters))
    return ExtractedContext(
      text: clipped,
      source: source,
      wasTruncated: inputWasLimited || clean.count > clipped.count,
      status: clean.isEmpty ? .noText : .success
    )
  }

  private func isImage(_ item: ItemSnapshot) -> Bool {
    if let raw = item.contentType, let type = UTType(raw), type.conforms(to: .image) { return true }
    return ["jpg", "jpeg", "png", "heic", "gif", "webp", "tiff"].contains(item.fileExtension)
  }

  private func isText(_ item: ItemSnapshot) -> Bool {
    if let raw = item.contentType, let type = UTType(raw), type.conforms(to: .text) { return true }
    return ["txt", "md", "rtf", "csv", "json", "xml", "yaml", "yml"].contains(item.fileExtension)
  }
}
