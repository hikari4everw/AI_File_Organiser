import Foundation

public enum ConceptLabelParser {
  public static func name(from statement: String) -> String {
    var value = statement.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["这些文件是", "这些是", "它们是"] where value.hasPrefix(prefix) {
      value.removeFirst(prefix.count)
      break
    }
    return value.trimmingCharacters(
      in: .whitespacesAndNewlines.union(.punctuationCharacters))
  }
}
