import Foundation

public struct ConceptTextFeatureExtractor: Sendable {
  public static let version = "hashed-text-bigrams-v1"

  public init() {}

  public func extract(item: ItemSnapshot) async -> ConceptFeatureSnapshot {
    let text: String
    if item.kind == .file, !item.isSymbolicLink, !item.isCloudPlaceholder {
      text = await NativeContentExtractor().extractContext(for: item).text
    } else {
      text = ""
    }
    let name = item.kind == .file
      ? URL(fileURLWithPath: item.name).deletingPathExtension().lastPathComponent
      : item.name
    var vector = [Float](repeating: 0, count: 256)
    Self.add(name, weight: 2, to: &vector)
    Self.add(String(text.prefix(4_000)), weight: 1, to: &vector)
    let length = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
    if length > 0 { vector = vector.map { $0 / length } }
    return ConceptFeatureSnapshot(
      modelVersion: "manual-only-v1", itemKind: item.kind, visualVector: [],
      textModelVersion: Self.version, textVector: length > 0 ? vector : [])
  }

  private static func add(_ text: String, weight: Float, to vector: inout [Float]) {
    let normalized = RuleCondition.normalize(text)
    var run: [Unicode.Scalar] = []
    func flush() {
      guard run.count >= 2 else { run.removeAll(); return }
      for index in 0..<(run.count - 1) {
        let token = String(String.UnicodeScalarView(run[index...index + 1]))
        vector[bucket(token)] += weight
      }
      run.removeAll()
    }
    for scalar in normalized.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        run.append(scalar)
      } else {
        flush()
      }
    }
    flush()
  }

  private static func bucket(_ token: String) -> Int {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in token.utf8 {
      hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
    return Int(hash % 256)
  }
}
