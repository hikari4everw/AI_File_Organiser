import Foundation

public struct NamingOperationEngine: Sendable {
  public init() {}

  public func validate(operations: [NamingOperation]) throws {
    guard !operations.isEmpty else {
      throw OrganizerError.invalidFilename("命名规则至少需要一个操作")
    }
    for operation in operations {
      if case .renderTemplate(let template) = operation {
        try FilenameTemplateEngine().validate(template)
      }
    }
  }

  public func render(
    operations: [NamingOperation],
    baseName: String,
    fields: [FilenameField: String]
  ) throws -> TemplateRenderResult {
    var value = baseName
    var missingFields: [FilenameField] = []

    for operation in operations {
      switch operation {
      case .renderTemplate(let template):
        var currentFields = fields
        currentFields[.originalTitle] = value
        let result = try FilenameTemplateEngine().render(template: template, fields: currentFields)
        value = result.value
        for field in result.missingFields where !missingFields.contains(field) {
          missingFields.append(field)
        }
      case .removeLiteralPrefix(let prefix):
        if !prefix.isEmpty, value.hasPrefix(prefix) {
          value.removeFirst(prefix.count)
        }
      case .removeLiteralSuffix(let suffix):
        if !suffix.isEmpty, value.hasSuffix(suffix) {
          value.removeLast(suffix.count)
        }
      case .removeNumericPrefix(let prefix, let suffix):
        value = removingNumericPrefix(from: value, prefix: prefix, suffix: suffix)
      case .removeNumericSuffix(let prefix, let suffix):
        value = removingNumericSuffix(from: value, prefix: prefix, suffix: suffix)
      case .replaceLiteral(let target, let replacement):
        if !target.isEmpty {
          value = value.replacingOccurrences(of: target, with: replacement)
        }
      }
    }

    return TemplateRenderResult(value: value, missingFields: missingFields)
  }

  private func removingNumericPrefix(from value: String, prefix: String, suffix: String) -> String {
    guard !prefix.isEmpty || !suffix.isEmpty, value.hasPrefix(prefix) else { return value }
    let digitsStart = value.index(value.startIndex, offsetBy: prefix.count)
    var digitsEnd = digitsStart
    while digitsEnd < value.endIndex, value[digitsEnd].isASCIIDigit {
      digitsEnd = value.index(after: digitsEnd)
    }
    guard digitsEnd > digitsStart, value[digitsEnd...].hasPrefix(suffix) else { return value }
    let end = value.index(digitsEnd, offsetBy: suffix.count)
    return String(value[end...])
  }

  private func removingNumericSuffix(from value: String, prefix: String, suffix: String) -> String {
    guard !prefix.isEmpty || !suffix.isEmpty, value.hasSuffix(suffix) else { return value }
    let suffixStart = value.index(value.endIndex, offsetBy: -suffix.count)
    var digitsStart = suffixStart
    while digitsStart > value.startIndex {
      let previous = value.index(before: digitsStart)
      guard value[previous].isASCIIDigit else { break }
      digitsStart = previous
    }
    guard digitsStart < suffixStart else { return value }
    let beforeDigits = value[..<digitsStart]
    guard beforeDigits.hasSuffix(prefix) else { return value }
    let removalStart = value.index(digitsStart, offsetBy: -prefix.count)
    return String(value[..<removalStart])
  }
}

private extension Character {
  var isASCIIDigit: Bool {
    unicodeScalars.count == 1 && unicodeScalars.first.map { (48...57).contains($0.value) } == true
  }
}
