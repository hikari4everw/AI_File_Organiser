import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct ContentAnalysisTests {
  @Test func catalogPDFModeReadsFiveDispersedPages() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appendingPathComponent("catalog.pdf")
    try makePDF(pages: (1...11).map { "PAGE \($0)" }, at: pdf)
    let item = ItemSnapshot(sessionID: UUID(), path: pdf.path,
      name: pdf.lastPathComponent, kind: .file,
      contentType: "com.adobe.pdf", fileExtension: "pdf")
    let result = await NativeContentExtractor(maximumPDFPages: 5).extractContext(for: item)
    #expect(result.text.contains("PAGE 1"))
    #expect(result.text.contains("PAGE 6"))
    #expect(result.text.contains("PAGE 11"))
    #expect(!result.text.contains("PAGE 2\n"))
  }
  @Test func extractsTextFromFirstThreePDFPagesOnly() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appendingPathComponent("score.pdf")
    try makePDF(pages: ["FIRST PAGE", "SECOND PAGE", "THIRD PAGE", "FOURTH PAGE"], at: pdf)
    let item = ItemSnapshot(
      sessionID: UUID(),
      path: pdf.path,
      name: pdf.lastPathComponent,
      kind: .file,
      contentType: "com.adobe.pdf",
      fileExtension: "pdf"
    )

    let result = await NativeContentExtractor(maximumCharacters: 6_000).extractContext(for: item)

    #expect(result.status == .success)
    #expect(result.text.contains("FIRST PAGE"))
    #expect(result.text.contains("THIRD PAGE"))
    #expect(!result.text.contains("FOURTH PAGE"))
    #expect(result.wasTruncated)
  }

  @Test func directoryAnalysisIsBoundedAndFindsSequentialImages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let comic = root.appendingPathComponent("Comic", isDirectory: true)
    let chapter = comic.appendingPathComponent("Chapter", isDirectory: true)
    try FileManager.default.createDirectory(at: chapter, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 1...220 {
      let name = String(format: "%03d.jpg", index)
      try Data([0]).write(to: chapter.appendingPathComponent(name))
    }

    let summary = await DirectoryAnalyzer(
      maximumDepth: 2,
      maximumEntries: 200,
      maximumRepresentativeFiles: 5
    ).analyze(comic)

    #expect(summary.inspectedCount == 200)
    #expect(summary.wasTruncated)
    #expect(summary.extensionCounts["jpg"] == 199)
    #expect(summary.representativeFiles.count <= 5)
    #expect(summary.hasSequentialNames)
  }

  @Test func imageOCRReadsJapaneseTitle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("title.png")
    let image = NSImage(size: NSSize(width: 1000, height: 220))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1000, height: 220).fill()
    NSString(string: "日本語テスト").draw(
      at: NSPoint(x: 50, y: 55),
      withAttributes: [.font: NSFont.systemFont(ofSize: 90), .foregroundColor: NSColor.black])
    image.unlockFocus()
    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: file)

    let item = ItemSnapshot(
      sessionID: UUID(), path: file.path, name: file.lastPathComponent,
      kind: .file, fileExtension: "png")
    let result = await NativeContentExtractor().extractContext(for: item)

    #expect(result.text.contains("日本語"))
  }

  private func makePDF(pages: [String], at url: URL) throws {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data) else { throw CocoaError(.fileWriteUnknown) }
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    for value in pages {
      context.beginPDFPage(nil)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      NSString(string: value).draw(
        at: CGPoint(x: 72, y: 650),
        withAttributes: [.font: NSFont.systemFont(ofSize: 18)]
      )
      NSGraphicsContext.restoreGraphicsState()
      context.endPDFPage()
    }
    context.closePDF()
    try (data as Data).write(to: url)
  }
}
