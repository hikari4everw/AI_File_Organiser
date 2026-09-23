import Foundation

public struct ParsedWorkName: Codable, Hashable, Sendable {
  public var originalName: String
  public var circleName: String?
  public var authorNames: [String]
  public var title: String
  public var tags: [String]
  public var hasMultipleAuthors: Bool

  public init(
    originalName: String, circleName: String?, authorNames: [String],
    title: String, tags: [String], hasMultipleAuthors: Bool
  ) {
    self.originalName = originalName
    self.circleName = circleName
    self.authorNames = authorNames
    self.title = title
    self.tags = tags
    self.hasMultipleAuthors = hasMultipleAuthors
  }
}

public struct WorkNameParser: Sendable {
  public init() {}

  public func parse(_ name: String) -> ParsedWorkName {
    let normalized = String(name.map { character -> Character in
      switch character {
      case "［": "["
      case "］": "]"
      case "（": "("
      case "）": ")"
      default: character
      }
    })
    var remaining = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    var circle: String?
    var authors: [String] = []
    var hasMultipleAuthors = false
    if remaining.hasPrefix("["), let close = remaining.firstIndex(of: "]") {
      let header = String(remaining[remaining.index(after: remaining.startIndex)..<close])
      remaining = String(remaining[remaining.index(after: close)...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let open = header.lastIndex(of: "("), header.hasSuffix(")"), open > header.startIndex {
        circle = String(header[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        let author = String(header[header.index(after: open)..<header.index(before: header.endIndex)])
          .trimmingCharacters(in: .whitespacesAndNewlines)
        hasMultipleAuthors = author.contains(" & ") || author.contains("、")
          || author.contains(" / ") || author.contains("／") || author.contains("＋")
        if !hasMultipleAuthors, !author.isEmpty {
          authors = author.components(separatedBy: " / ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        }
      } else {
        circle = header.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    var tags: [String] = []
    var title = remaining
    if let firstTag = remaining.firstIndex(of: "[") {
      title = String(remaining[..<firstTag]).trimmingCharacters(in: .whitespacesAndNewlines)
      var suffix = remaining[firstTag...]
      while suffix.first == "[", let close = suffix.firstIndex(of: "]") {
        let tag = String(suffix[suffix.index(after: suffix.startIndex)..<close])
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !tag.isEmpty { tags.append(tag) }
        suffix = suffix[suffix.index(after: close)...]
          .drop(while: { $0.isWhitespace })
      }
    }
    return ParsedWorkName(
      originalName: name, circleName: circle?.isEmpty == true ? nil : circle,
      authorNames: authors, title: title, tags: tags,
      hasMultipleAuthors: hasMultipleAuthors)
  }
}
