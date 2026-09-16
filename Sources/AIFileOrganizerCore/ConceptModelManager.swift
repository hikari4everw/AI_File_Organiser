import CoreML
import CryptoKit
import Foundation
import Vision

public struct ConceptModelManager: Sendable {
  public static let modelVersion = "mobileclip-blt-3e0a7bfb"
  private static let revision = "3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947"
  private static let repositoryPath = "mobileclip_blt_image.mlpackage"
  private let root: URL

  public init(root: URL? = nil) {
    self.root = root ?? FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("AI File Organizer/Concept Models", isDirectory: true)
  }

  public var compiledModelURL: URL {
    root.appendingPathComponent("MobileCLIP-BLT.mlmodelc", isDirectory: true)
  }

  public var isInstalled: Bool {
    FileManager.default.fileExists(atPath: compiledModelURL.path)
  }

  public func provider() throws -> MobileCLIPImageEmbeddingProvider? {
    guard isInstalled else { return nil }
    return try MobileCLIPImageEmbeddingProvider(modelURL: compiledModelURL)
  }

  public func install() async throws {
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    let staging = root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
    defer { try? manager.removeItem(at: staging) }
    let package = staging.appendingPathComponent(Self.repositoryPath, isDirectory: true)
    try manager.createDirectory(
      at: package.appendingPathComponent("Data/com.apple.CoreML/weights", isDirectory: true),
      withIntermediateDirectories: true)
    let files: [(String, Int64, String)] = [
      ("Manifest.json", 617,
        "112a034d18e8c76b21e491a94ee8236e6989021c13dfe9ea8ecd3ac6dc2bdabe"),
      ("Data/com.apple.CoreML/model.mlmodel", 136_798,
        "3acaec5c9eca2f27b7dc6d3bffb19cbb94d34e97cdd8aec70987e4ae7de09fae"),
      ("Data/com.apple.CoreML/weights/weight.bin", 172_707_392,
        "c12ec418eadf5d536f11e2e575b26c0d0bbc1270a7080d97f218a0a11595c289"),
    ]
    for (relativePath, size, digest) in files {
      try Task.checkCancellation()
      let url = URL(string: "https://huggingface.co/apple/coreml-mobileclip/resolve/\(Self.revision)/\(Self.repositoryPath)/\(relativePath)")!
      let (temporary, response) = try await URLSession.shared.download(from: url)
      defer { try? manager.removeItem(at: temporary) }
      guard let response = response as? HTTPURLResponse, response.statusCode == 200,
        try Self.matches(temporary, byteCount: size, sha256: digest)
      else { throw OrganizerError.invalidModelOutput("概念模型下载或校验失败") }
      let target = package.appendingPathComponent(relativePath)
      try manager.moveItem(at: temporary, to: target)
    }
    try Task.checkCancellation()
    let compiled = try await MLModel.compileModel(at: package)
    _ = try MLModel(contentsOf: compiled)
    let backup = root.appendingPathComponent("previous-\(UUID().uuidString).mlmodelc")
    if manager.fileExists(atPath: compiledModelURL.path) {
      try manager.moveItem(at: compiledModelURL, to: backup)
    }
    do {
      try manager.moveItem(at: compiled, to: compiledModelURL)
      if manager.fileExists(atPath: backup.path) { try? manager.removeItem(at: backup) }
    } catch {
      if manager.fileExists(atPath: backup.path),
        !manager.fileExists(atPath: compiledModelURL.path)
      {
        try? manager.moveItem(at: backup, to: compiledModelURL)
      }
      throw error
    }
  }

  static func matches(_ url: URL, byteCount: Int64, sha256: String) throws -> Bool {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard (attributes[.size] as? NSNumber)?.int64Value == byteCount else { return false }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined() == sha256
  }
}

public final class MobileCLIPImageEmbeddingProvider: ImageEmbeddingProvider, @unchecked Sendable {
  public let modelVersion = ConceptModelManager.modelVersion
  private let model: VNCoreMLModel
  private let lock = NSLock()

  public init(modelURL: URL) throws {
    model = try VNCoreMLModel(for: MLModel(contentsOf: modelURL))
  }

  public func embedding(for image: CGImage) throws -> [Float] {
    lock.lock()
    defer { lock.unlock() }
    let request = VNCoreMLRequest(model: model)
    request.imageCropAndScaleOption = .centerCrop
    try VNImageRequestHandler(cgImage: image).perform([request])
    guard let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
      let values = observation.featureValue.multiArrayValue else {
      throw OrganizerError.invalidModelOutput("概念模型未返回图像特征")
    }
    return (0..<values.count).map { values[$0].floatValue }
  }
}
