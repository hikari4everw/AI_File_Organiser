import Foundation

public struct FilenameValidator: Sendable {
  public init() {}

  public func validatedFullName(baseName raw: String, item: ItemSnapshot) throws -> String {
    guard item.kind != .applicationBundle else {
      throw OrganizerError.invalidFilename("应用包不支持改名")
    }
    let baseName = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard !baseName.isEmpty else { throw OrganizerError.invalidFilename("文件名不能为空") }
    guard baseName != ".", baseName != "..", !baseName.hasPrefix(".") else {
      throw OrganizerError.invalidFilename("不能使用隐藏或保留名称")
    }
    guard !baseName.contains("/"), !baseName.contains(":"),
      !baseName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw OrganizerError.invalidFilename("文件名包含非法字符")
    }
    if item.kind == .file, !item.fileExtension.isEmpty,
      baseName.lowercased().hasSuffix("." + item.fileExtension.lowercased())
    {
      throw OrganizerError.invalidFilename("请勿在主文件名中输入扩展名")
    }
    let fullName: String
    if item.kind == .file, !item.fileExtension.isEmpty {
      fullName = baseName + "." + item.fileExtension
    } else {
      fullName = baseName
    }
    guard fullName.utf8.count <= 240 else {
      throw OrganizerError.invalidFilename("文件名过长")
    }
    return fullName
  }
}
