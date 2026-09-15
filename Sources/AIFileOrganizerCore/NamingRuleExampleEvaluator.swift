import Foundation

public struct NamingRulePreview: Hashable, Sendable {
  public var originalName: String
  public var suggestedName: String
  public var isSemanticConditionUnverified: Bool

  public init(
    originalName: String,
    suggestedName: String,
    isSemanticConditionUnverified: Bool
  ) {
    self.originalName = originalName
    self.suggestedName = suggestedName
    self.isSemanticConditionUnverified = isSemanticConditionUnverified
  }
}

public struct NamingRuleExampleEvaluation: Hashable, Sendable {
  public var preview: NamingRulePreview?
  public var blockingReason: String?

  public init(preview: NamingRulePreview? = nil, blockingReason: String? = nil) {
    self.preview = preview
    self.blockingReason = blockingReason
  }

  public var canSave: Bool { blockingReason == nil }
}

public struct NamingRuleExampleEvaluator: Sendable {
  public init() {}

  public func evaluate(
    operations: [NamingOperation],
    condition: RuleCondition,
    originalName: String,
    expectedName: String?
  ) -> NamingRuleExampleEvaluation {
    do {
      try NamingOperationEngine().validate(operations: operations)
    } catch {
      return NamingRuleExampleEvaluation(blockingReason: error.localizedDescription)
    }

    let hasOriginal = !originalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let expected = expectedName ?? ""
    let hasExpected = !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard hasOriginal else {
      return hasExpected
        ? NamingRuleExampleEvaluation(blockingReason: "请先填写示例原名称")
        : NamingRuleExampleEvaluation()
    }
    guard isPlainFilename(originalName) else {
      return NamingRuleExampleEvaluation(blockingReason: "示例原名称包含非法字符")
    }

    let kind: ItemKind = condition.itemKinds.contains(.directory)
      && !condition.itemKinds.contains(.file) ? .directory : .file
    let fileExtension = kind == .file
      ? URL(fileURLWithPath: originalName).pathExtension : ""
    let baseName = kind == .file && !fileExtension.isEmpty
      ? URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent
      : originalName
    let item = ItemSnapshot(
      sessionID: UUID(),
      path: "/preview/\(originalName)",
      name: originalName,
      kind: kind,
      fileExtension: fileExtension)

    do {
      let result = try NamingOperationEngine().render(
        operations: operations,
        baseName: baseName,
        fields: [.originalTitle: baseName])
      guard result.missingFields.isEmpty else {
        let fields = result.missingFields.map { "{\($0.placeholder)}" }.joined(separator: "、")
        return NamingRuleExampleEvaluation(blockingReason: "示例缺少模板字段：\(fields)")
      }
      let suggestedName = try FilenameValidator().validatedFullName(
        baseName: result.value,
        item: item)
      let preview = NamingRulePreview(
        originalName: originalName,
        suggestedName: suggestedName,
        isSemanticConditionUnverified: condition.semanticDescription != nil)
      guard suggestedName != originalName else {
        return NamingRuleExampleEvaluation(
          preview: preview,
          blockingReason: "示例执行后名称没有变化")
      }
      guard !hasExpected || suggestedName == expected else {
        return NamingRuleExampleEvaluation(
          preview: preview,
          blockingReason: "预览结果与预期名称不一致")
      }
      return NamingRuleExampleEvaluation(preview: preview)
    } catch {
      return NamingRuleExampleEvaluation(blockingReason: error.localizedDescription)
    }
  }

  private func isPlainFilename(_ value: String) -> Bool {
    value != "." && value != ".." && !value.contains("/") && !value.contains(":")
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}
