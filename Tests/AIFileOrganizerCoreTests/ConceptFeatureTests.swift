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
  /// 本地已编译 MobileCLIP 包的可选路径。测试环境不提供时，
  /// 依赖它的用例会显示为 **skipped**，而不是零断言"绿过"。
  private static var localModelPath: String? {
    ProcessInfo.processInfo.environment["AI_FILE_ORGANIZER_TEST_MODEL"]
  }

  @Test(.enabled(if: ConceptFeatureTests.localModelPath != nil))
  func localMobileCLIPPackageProducesFeaturesWhenSupplied() throws {
    let path = try #require(Self.localModelPath)
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

  /// 固定版本模型是本项目唯一的网络下载物，其身份常量一旦被改坏，
  /// 已保存的概念特征就会与新特征不可比（识别会静默全部降级为待审核）。
  /// 这里断言恒等/形状，不需要下载 173 MB 权重。
  @Test func pinnedModelIdentityIsStableAndMissingModelFailsClosed() throws {
    #expect(!ConceptModelManager.modelVersion.isEmpty)
    #expect(ConceptModelManager.modelVersion == "mobileclip-blt-3e0a7bfb")

    let manager = ConceptModelManager()
    #expect(manager.compiledModelURL.lastPathComponent == "MobileCLIP-BLT.mlmodelc")
    #expect(
      manager.compiledModelURL.path.contains("AI File Organizer/Concept Models"),
      "模型目录变更会让已安装用户重新下载，需显式确认")

    // 未安装模型时必须返回 nil（降级为文本候选），而不是抛错或返回半成品。
    if !manager.isInstalled {
      #expect(try manager.provider() == nil)
    }

    // 指向不存在的包时必须抛错，而不是构造出一个会在推理时崩掉的 provider。
    var thrown: (any Error)?
    do {
      _ = try MobileCLIPImageEmbeddingProvider(
        modelURL: URL(fileURLWithPath: "/tmp/aifo-missing-\(UUID().uuidString).mlmodelc"))
    } catch {
      thrown = error
    }
    #expect(thrown != nil)
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

  @Test func unsupportedAndApplicationBundleContentIsIgnored() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let unreadable = directory.appendingPathComponent("broken.png")
    try Data("not an image".utf8).write(to: unreadable)
    let extractor = ConceptFeatureExtractor(provider: ConstantImageEmbedder())
    let brokenItem = ItemSnapshot(
      sessionID: UUID(), path: unreadable.path, name: unreadable.lastPathComponent,
      kind: .file, fileExtension: "png")
    let appItem = ItemSnapshot(
      sessionID: UUID(), path: directory.path, name: "Example.app",
      kind: .applicationBundle)

    #expect(try await extractor.extract(item: brokenItem) == nil)
    #expect(try await extractor.extract(item: appItem) == nil)
  }

  @Test func cancelledExtractionStopsBeforeEmbedding() async throws {
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
    let task = Task {
      try await ConceptFeatureExtractor(provider: ConstantImageEmbedder()).extract(item: item)
    }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
