import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

public actor NativeContentExtractor: ContentExtractor {
  public let maximumCharacters: Int
  public let maximumBytes: Int

  public init(maximumCharacters: Int = 4_000, maximumBytes: Int = 1_048_576) {
    self.maximumCharacters = maximumCharacters
    self.maximumBytes = maximumBytes
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
    let pageLimit = min(document.pageCount, 3)
    let text = (0..<pageLimit).compactMap { document.page(at: $0)?.string }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty {
      return clipped(
        text,
        source: "pdf-pages-1-\(pageLimit)",
        inputWasLimited: document.pageCount > pageLimit
      )
    }
    guard let page = document.page(at: 0) else {
      return .init(source: "pdf-no-text", status: .noText)
    }
    let image = page.thumbnail(of: NSSize(width: 1600, height: 1600), for: .mediaBox)
    var rectangle = NSRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(forProposedRect: &rectangle, context: nil, hints: nil) else {
      return .init(source: "pdf-no-text", status: .noText)
    }
    return recognize(cgImage, source: "pdf-first-page-ocr")
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
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["zh-Hans", "en-US"]
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
