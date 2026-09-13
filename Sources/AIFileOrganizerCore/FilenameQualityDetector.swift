import Foundation

public struct FilenameQualityDetector: Sendable {
  public init() {}

  public func requiresSuggestion(name: String) -> Bool {
    let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    if stem.unicodeScalars.contains(where: {
      $0.value == 0xFFFD || CharacterSet.controlCharacters.contains($0)
    }) { return true }
    if UUID(uuidString: stem) != nil { return true }
    if stem.count >= 20, stem.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) {
      return true
    }
    let percentEscapes = stem.matches(of: /%[0-9A-Fa-f]{2}/).count
    if percentEscapes >= 2 { return true }
    if stem.count >= 28,
      stem.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0) }),
      stem.rangeOfCharacter(from: .decimalDigits) != nil,
      stem.rangeOfCharacter(from: .uppercaseLetters) != nil,
      stem.rangeOfCharacter(from: .lowercaseLetters) != nil,
      !stem.contains(" ")
    {
      return true
    }
    return false
  }
}
