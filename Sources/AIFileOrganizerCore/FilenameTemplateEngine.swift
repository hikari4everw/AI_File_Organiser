import Foundation

public struct FilenameTemplateEngine: Sendable {
  public init() {}

  public func validate(_ template: FilenameTemplate) throws {
    let pattern = template.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pattern.isEmpty else { throw OrganizerError.invalidFilename("命名模板不能为空") }
    let tokens = try placeholders(in: pattern)
    for token in tokens where FilenameField(placeholder: token) == nil {
      throw OrganizerError.invalidFilename("不支持命名字段：{\(token)}")
    }
  }

  public func render(
    template: FilenameTemplate,
    fields: [FilenameField: String]
  ) throws -> TemplateRenderResult {
    try validate(template)
    var rendered = template.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    var missing: [FilenameField] = []
    for field in FilenameField.allCases {
      let placeholder = "{\(field.placeholder)}"
      guard rendered.contains(placeholder) else { continue }
      let value = fields[field]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if value.isEmpty {
        missing.append(field)
      } else {
        rendered = rendered.replacingOccurrences(of: placeholder, with: value)
      }
    }
    return TemplateRenderResult(value: rendered, missingFields: missing)
  }

  private func placeholders(in pattern: String) throws -> [String] {
    var tokens: [String] = []
    var index = pattern.startIndex
    while index < pattern.endIndex {
      if pattern[index] == "}" { throw OrganizerError.invalidFilename("命名模板括号不匹配") }
      guard pattern[index] == "{" else {
        index = pattern.index(after: index)
        continue
      }
      guard let end = pattern[index...].firstIndex(of: "}") else {
        throw OrganizerError.invalidFilename("命名模板括号不匹配")
      }
      let start = pattern.index(after: index)
      let token = String(pattern[start..<end])
      guard !token.isEmpty, !token.contains("{") else {
        throw OrganizerError.invalidFilename("命名模板字段不合法")
      }
      tokens.append(token)
      index = pattern.index(after: end)
    }
    return tokens
  }
}
