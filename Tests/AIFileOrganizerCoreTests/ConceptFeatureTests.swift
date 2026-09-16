import AppKit
import Foundation
import PDFKit
import Testing

@testable import AIFileOrganizerCore

private struct ConstantImageEmbedder: ImageEmbeddingProvider {
  let modelVersion = "test-image-v1"
  func embedding(for image: CGImage) throws -> [Float] { [1, 0] }
}

@Suite struct ConceptFeatureTests {
  @Test func localMobileCLIPPackageProducesFeaturesWhenSupplied() throws {
    guard let path = ProcessInfo.processInfo.environment["AI_FILE_ORGANIZER_TEST_MODEL"] else {
      return
    }
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let image = try #require(bitmap.cgImage)
    let provider = try MobileCLIPImageEmbeddingProvider(modelURL: URL(fileURLWithPath: path))
    let vector = try provider.embedding(for: image)
    #expect(vector.count == 512)
    #expect(vector.allSatisfy { $0.isFinite })
  }

  @Test func modelFileMustMatchPinnedSizeAndDigest() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("abc".utf8).write(to: url)
    #expect(try ConceptModelManager.matches(
      url, byteCount: 3,
      sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
    #expect(try !ConceptModelManager.matches(url, byteCount: 4, sha256: ""))
    #expect(try !ConceptModelManager.matches(url, byteCount: 3, sha256: "bad"))
  }

  @Test func representativePositionsNeverExceedFive() {
    #expect(ConceptFeatureExtractor.representativePositions(count: 0).isEmpty)
    #expect(ConceptFeatureExtractor.representativePositions(count: 1) == [0])
    #expect(ConceptFeatureExtractor.representativePositions(count: 20) == [0, 5, 10, 14, 19])
  }

  @Test func oversizedDecodedImagesAreRejectedBeforeEmbedding() {
    #expect(ConceptFeatureExtractor.safeDimensions(width: 1600, height: 2400))
    #expect(!ConceptFeatureExtractor.safeDimensions(width: 20000, height: 20000))
    #expect(!ConceptFeatureExtractor.safeDimensions(width: 0, height: 100))
  }

  @Test func imageExampleIsVersionedAndNormalized() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let imageURL = directory.appendingPathComponent("page.png")
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)
    let item = ItemSnapshot(
      sessionID: UUID(), path: imageURL.path, name: imageURL.lastPathComponent,
      kind: .file, fileExtension: "png")

    let result = try await ConceptFeatureExtractor(provider: ConstantImageEmbedder())
      .extract(item: item)
    #expect(result?.modelVersion == "test-image-v1")
    #expect(result?.visualVector == [1, 0])
  }

  @Test func pdfPagesAndEpubImagesCanBeTaught() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let image = NSImage(size: NSSize(width: 16, height: 16))
    image.addRepresentation(bitmap)
    let pdf = PDFDocument()
    pdf.insert(try #require(PDFPage(image: image)), at: 0)
    let pdfURL = directory.appendingPathComponent("score.pdf")
    #expect(pdf.write(to: pdfURL))
    let imageURL = directory.appendingPathComponent("page.png")
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)
    let epubURL = directory.appendingPathComponent("book.epub")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.arguments = ["-j", epubURL.path, imageURL.path]
    zip.standardOutput = FileHandle.nullDevice
    zip.standardError = FileHandle.nullDevice
    try zip.run()
    zip.waitUntilExit()
    #expect(zip.terminationStatus == 0)

    let extractor = ConceptFeatureExtractor(provider: ConstantImageEmbedder())
    for file in [pdfURL, epubURL] {
      let item = ItemSnapshot(
        sessionID: UUID(), path: file.path, name: file.lastPathComponent,
        kind: .file, fileExtension: file.pathExtension)
      #expect(try await extractor.extract(item: item)?.visualVector == [1, 0])
    }
  }

  @Test func symlinkAndCloudPlaceholderAreNeverRead() async throws {
    let item = ItemSnapshot(
      sessionID: UUID(), path: "/tmp/missing.png", name: "missing.png",
      kind: .file, fileExtension: "png", isSymbolicLink: true)
    let extractor = ConceptFeatureExtractor(provider: ConstantImageEmbedder())
    #expect(try await extractor.extract(item: item) == nil)
    var cloud = item
    cloud.isSymbolicLink = false
    cloud.isCloudPlaceholder = true
    #expect(try await extractor.extract(item: cloud) == nil)
  }
}
