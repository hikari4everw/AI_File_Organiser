import AIFileOrganizerCore
import SwiftUI

struct RulesView: View {
  @ObservedObject var model: AppModel
  @State private var input = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 8) {
          Text("用一句话描述你的整理习惯").font(.title2.bold())
          Text("AI 只负责把自然语言转换成整理和命名草稿；保存前你可以检查条件、目标和模板。")
            .foregroundStyle(.secondary)
          HStack {
            TextField("例如：PDF 乐谱放到 音乐/乐谱，并命名为 {作者} - {标题}", text: $input)
              .textFieldStyle(.roundedBorder)
              .onSubmit { model.interpretRule(input) }
            Button(model.isInterpretingRule ? "正在理解…" : "生成规则草稿") {
              model.interpretRule(input)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isInterpretingRule || input.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }

        ForEach(model.ruleInterpretationWarnings, id: \.self) { warning in
          Label(warning, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
        }
        ForEach($model.ruleDrafts) { $draft in
          RuleDraftCard(model: model, draft: $draft)
        }
        ForEach($model.namingRuleDrafts) { $draft in
          NamingRuleDraftCard(model: model, draft: $draft)
        }

        if !model.namingRuleSuggestions.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            Label("从已确认改名中发现", systemImage: "lightbulb.fill").font(.headline)
            Text("这些只是待批准草稿，不会自动启用。")
              .font(.caption).foregroundStyle(.secondary)
            ForEach(model.namingRuleSuggestions) { suggestion in
              HStack {
                VStack(alignment: .leading, spacing: 3) {
                  Text(suggestion.template.pattern).fontWeight(.medium)
                  Text("来自 \(suggestion.supportingSampleIDs.count) 个已确认项目")
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("忽略") { model.rejectNamingRuleSuggestion(suggestion) }
                Button("批准规则") { model.approveNamingRuleSuggestion(suggestion) }
                  .buttonStyle(.borderedProminent)
              }
            }
          }
          .padding(16).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        }

        Divider()
        HStack {
          Text("已保存规则").font(.headline)
          Text("\(model.rules.count)").foregroundStyle(.secondary)
        }
        if model.rules.isEmpty {
          ContentUnavailableView("还没有规则", systemImage: "text.badge.plus",
            description: Text("规则会优先于普通分类；冲突时始终交给你确认。"))
        } else {
          ForEach(model.rules) { rule in
            HStack(spacing: 14) {
              Toggle("", isOn: Binding(
                get: { rule.isEnabled }, set: { _ in model.toggleRule(rule) }))
                .labelsHidden()
              VStack(alignment: .leading, spacing: 4) {
                Text(rule.originalText).fontWeight(.medium)
                Text("\(actionSummary(rule, model: model)) · \(conditionSummary(rule.condition, concepts: model.concepts))")
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button(role: .destructive) { model.deleteRule(rule) } label: {
                Image(systemName: "trash")
              }.buttonStyle(.borderless)
            }
            .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 12))
          }
        }

        Divider()
        HStack {
          Text("命名规则").font(.headline)
          Text("\(model.namingRules.count)").foregroundStyle(.secondary)
        }
        if model.namingRules.isEmpty {
          ContentUnavailableView(
            "还没有命名规则", systemImage: "character.cursor.ibeam",
            description: Text("命名规则只在字段齐全且名称合法时默认采用。"))
        } else {
          ForEach(model.namingRules) { rule in
            HStack(spacing: 14) {
              Toggle("", isOn: Binding(
                get: { rule.isEnabled }, set: { _ in model.toggleNamingRule(rule) }))
                .labelsHidden()
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(rule.originalText).fontWeight(.medium)
                  if rule.isDerived {
                    Text("学习建议").font(.caption2).foregroundStyle(.secondary)
                  }
                }
                Text("\(conditionSummary(rule.condition, concepts: model.concepts)) → \(rule.template.pattern)")
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button(role: .destructive) { model.deleteNamingRule(rule) } label: {
                Image(systemName: "trash")
              }.buttonStyle(.borderless)
            }
            .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 12))
          }
        }
      }
      .padding(28).frame(maxWidth: 900)
    }
  }
}

private struct NamingRuleDraftCard: View {
  @ObservedObject var model: AppModel
  @Binding var draft: NamingRuleDraft
  @State private var originalExample = ""
  @State private var expectedExample = ""

  private var exampleEvaluation: NamingRuleExampleEvaluation {
    NamingRuleExampleEvaluator().evaluate(
      operations: draft.operations,
      condition: draft.condition,
      originalName: originalExample,
      expectedName: expectedExample)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("请确认命名规则草稿", systemImage: "character.cursor.ibeam").font(.headline)
      TextField("原始描述", text: $draft.originalText).textFieldStyle(.roundedBorder)
      VStack(alignment: .leading, spacing: 7) {
        Text("操作（按顺序执行）").font(.subheadline.weight(.medium))
        ForEach(Array(draft.operations.indices), id: \.self) { index in
          operationEditor(at: index)
        }
      }
      TextField("扩展名（逗号分隔）", text: Binding(
        get: { draft.condition.fileExtensions.sorted().joined(separator: ", ") },
        set: { draft.condition.fileExtensions = commaSet($0) }))
        .textFieldStyle(.roundedBorder)
      TextField("文件名关键词（逗号分隔）", text: Binding(
        get: { draft.condition.filenameKeywords.sorted().joined(separator: ", ") },
        set: { draft.condition.filenameKeywords = commaSet($0) }))
        .textFieldStyle(.roundedBorder)
      TextField("内容关键词（逗号分隔）", text: Binding(
        get: { draft.condition.contentKeywords.sorted().joined(separator: ", ") },
        set: { draft.condition.contentKeywords = commaSet($0) }))
        .textFieldStyle(.roundedBorder)
      Picker("已学概念（可选）", selection: $draft.condition.conceptID) {
        Text("不使用概念").tag(UUID?.none)
        ForEach(model.concepts) { concept in
          Text(concept.name).tag(Optional(concept.id))
        }
      }
      TextField("需要 AI 判断的含义（可选）", text: Binding(
        get: { draft.condition.semanticDescription ?? "" },
        set: { draft.condition.semanticDescription = $0.isEmpty ? nil : $0 }))
        .textFieldStyle(.roundedBorder)
      ForEach(draft.warnings, id: \.self) { warning in
        Label(warning, systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      }
      VStack(alignment: .leading, spacing: 7) {
        Text("示例预览（可选）").font(.subheadline.weight(.medium))
        HStack {
          TextField("原名称，如 draft_report.pdf", text: $originalExample)
          TextField("预期名称（可选）", text: $expectedExample)
        }
        .textFieldStyle(.roundedBorder)
        if let preview = exampleEvaluation.preview {
          HStack(spacing: 7) {
            Text(preview.originalName).lineLimit(1)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Text(preview.suggestedName).lineLimit(1).fontWeight(.medium)
          }
          .font(.caption)
          if preview.isSemanticConditionUnverified {
            Label("此预览只执行文字操作，尚未验证语义条件", systemImage: "brain")
              .font(.caption).foregroundStyle(.orange)
          }
        }
        if let reason = exampleEvaluation.blockingReason {
          Label(reason, systemImage: "xmark.circle")
            .font(.caption).foregroundStyle(.red)
        }
      }
      HStack {
        Spacer()
        Button("放弃") { model.namingRuleDrafts.removeAll { $0.id == draft.id } }
        Button("保存命名规则") {
          model.saveNamingRuleDraft(
            draft,
            exampleOriginalName: originalExample,
            exampleExpectedName: expectedExample)
        }
          .buttonStyle(.borderedProminent)
          .disabled(!exampleEvaluation.canSave)
      }
    }
    .padding(16).background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
  }

  private func commaSet(_ text: String) -> Set<String> {
    Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      .filter { !$0.isEmpty })
  }

  @ViewBuilder private func operationEditor(at index: Int) -> some View {
    if draft.operations.indices.contains(index) {
      HStack(spacing: 8) {
        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          .frame(width: 16, alignment: .trailing)
        operationFields(at: index)
        Button {
          draft.operations.swapAt(index, index - 1)
        } label: {
          Image(systemName: "arrow.up")
        }
        .buttonStyle(.borderless).disabled(index == 0)
        .help("上移")
        Button {
          draft.operations.swapAt(index, index + 1)
        } label: {
          Image(systemName: "arrow.down")
        }
        .buttonStyle(.borderless).disabled(index == draft.operations.count - 1)
        .help("下移")
        Button(role: .destructive) {
          draft.operations.remove(at: index)
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless).help("删除操作")
      }
    }
  }

  @ViewBuilder private func operationFields(at index: Int) -> some View {
    switch draft.operations[index] {
    case .renderTemplate:
      operationLabel("模板")
      TextField("{作者} - {标题}", text: operationTextBinding(at: index, part: 0))
        .textFieldStyle(.roundedBorder)
    case .removeLiteralPrefix:
      operationLabel("删除前缀")
      TextField("字面前缀", text: operationTextBinding(at: index, part: 0))
        .textFieldStyle(.roundedBorder)
    case .removeLiteralSuffix:
      operationLabel("删除后缀")
      TextField("字面后缀", text: operationTextBinding(at: index, part: 0))
        .textFieldStyle(.roundedBorder)
    case .removeNumericPrefix:
      operationLabel("数字前缀")
      TextField("数字前文字", text: operationTextBinding(at: index, part: 0))
        .textFieldStyle(.roundedBorder)
      TextField("数字后文字", text: operationTextBinding(at: index, part: 1))
        .textFieldStyle(.roundedBorder)
    case .removeNumericSuffix:
      operationLabel("数字后缀")
      TextField("数字前文字", text: operationTextBinding(at: index, part: 0))
        .textFieldStyle(.roundedBorder)
      TextField("数字后文字", text: operationTextBinding(at: index, part: 1))
        .textFieldStyle(.roundedBorder)
    case .replaceLiteral:
      operationLabel("字面替换")
      TextField("查找", text: operationTextBinding(at: index, part: 0))
        .textFieldStyle(.roundedBorder)
      TextField("替换为", text: operationTextBinding(at: index, part: 1))
        .textFieldStyle(.roundedBorder)
    }
  }

  private func operationLabel(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
      .frame(width: 70, alignment: .leading)
  }

  private func operationTextBinding(at index: Int, part: Int) -> Binding<String> {
    Binding(
      get: {
        guard draft.operations.indices.contains(index) else { return "" }
        return operationText(draft.operations[index], part: part)
      },
      set: { value in
        guard draft.operations.indices.contains(index) else { return }
        draft.operations[index] = replacingOperationText(
          draft.operations[index], part: part, value: value)
        if draft.operations.count == 1,
          case .renderTemplate(let template) = draft.operations[index]
        {
          draft.template = template
        }
      })
  }

  private func operationText(_ operation: NamingOperation, part: Int) -> String {
    switch operation {
    case .renderTemplate(let template): template.pattern
    case .removeLiteralPrefix(let value), .removeLiteralSuffix(let value): value
    case .removeNumericPrefix(let prefix, let suffix),
      .removeNumericSuffix(let prefix, let suffix): part == 0 ? prefix : suffix
    case .replaceLiteral(let target, let replacement): part == 0 ? target : replacement
    }
  }

  private func replacingOperationText(
    _ operation: NamingOperation, part: Int, value: String
  ) -> NamingOperation {
    switch operation {
    case .renderTemplate:
      .renderTemplate(FilenameTemplate(pattern: value))
    case .removeLiteralPrefix:
      .removeLiteralPrefix(value)
    case .removeLiteralSuffix:
      .removeLiteralSuffix(value)
    case .removeNumericPrefix(let prefix, let suffix):
      .removeNumericPrefix(
        prefix: part == 0 ? value : prefix,
        suffix: part == 1 ? value : suffix)
    case .removeNumericSuffix(let prefix, let suffix):
      .removeNumericSuffix(
        prefix: part == 0 ? value : prefix,
        suffix: part == 1 ? value : suffix)
    case .replaceLiteral(let target, let replacement):
      .replaceLiteral(
        target: part == 0 ? value : target,
        replacement: part == 1 ? value : replacement)
    }
  }
}

private struct RuleDraftCard: View {
  @ObservedObject var model: AppModel
  @Binding var draft: RuleDraft

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("请确认规则草稿", systemImage: "wand.and.stars").font(.headline)
      TextField("原始描述", text: $draft.originalText).textFieldStyle(.roundedBorder)
      Picker("动作", selection: $draft.action) {
        Text("移动到目录").tag(RuleAction.move)
        Text("保留原处").tag(RuleAction.keep)
      }
      .pickerStyle(.segmented)
      if draft.action == .move {
        Picker("目标目录", selection: $draft.destinationID) {
          Text("请选择…").tag(UUID?.none)
          ForEach(model.destinations.filter { $0.kind == .category }) { destination in
            Text(destination.relativePath).tag(Optional(destination.id))
          }
        }
      }
      TextField("扩展名（逗号分隔）", text: Binding(
        get: { draft.condition.fileExtensions.sorted().joined(separator: ", ") },
        set: { draft.condition.fileExtensions = commaSet($0) }))
        .textFieldStyle(.roundedBorder)
      TextField("文件名关键词（逗号分隔）", text: Binding(
        get: { draft.condition.filenameKeywords.sorted().joined(separator: ", ") },
        set: { draft.condition.filenameKeywords = commaSet($0) }))
        .textFieldStyle(.roundedBorder)
      TextField("内容关键词（逗号分隔）", text: Binding(
        get: { draft.condition.contentKeywords.sorted().joined(separator: ", ") },
        set: { draft.condition.contentKeywords = commaSet($0) }))
        .textFieldStyle(.roundedBorder)
      Picker("已学概念（可选）", selection: $draft.condition.conceptID) {
        Text("不使用概念").tag(UUID?.none)
        ForEach(model.concepts) { concept in
          Text(concept.name).tag(Optional(concept.id))
        }
      }
      TextField("需要 AI 判断的含义（可选）", text: Binding(
        get: { draft.condition.semanticDescription ?? "" },
        set: { draft.condition.semanticDescription = $0.isEmpty ? nil : $0 }))
        .textFieldStyle(.roundedBorder)
      ForEach(draft.warnings, id: \.self) { warning in
        Label(warning, systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      }
      HStack {
        Spacer()
        Button("放弃") { model.ruleDrafts.removeAll { $0.id == draft.id } }
        Button("保存规则") { model.saveRuleDraft(draft) }.buttonStyle(.borderedProminent)
      }
    }
    .padding(16).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
  }

  private func commaSet(_ text: String) -> Set<String> {
    Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      .filter { !$0.isEmpty })
  }
}

@MainActor private func actionSummary(_ rule: OrganizationRule, model: AppModel) -> String {
  switch rule.action {
  case .move: "→ \(model.destinationName(rule.destinationID))"
  case .keep: "→ 保留原处"
  }
}

private func conditionSummary(_ condition: RuleCondition, concepts: [FileConcept]) -> String {
  var parts: [String] = []
  if let conceptID = condition.conceptID {
    parts.append("概念：" + (concepts.first(where: { $0.id == conceptID })?.name ?? "已删除"))
  }
  if !condition.itemKinds.isEmpty { parts.append(condition.itemKinds.map(\.rawValue).sorted().joined(separator: ",")) }
  if !condition.fileExtensions.isEmpty { parts.append(condition.fileExtensions.sorted().map { ".\($0)" }.joined(separator: ",")) }
  if !condition.filenameKeywords.isEmpty { parts.append("名称含：" + condition.filenameKeywords.sorted().joined(separator: ",")) }
  if !condition.contentKeywords.isEmpty { parts.append("内容含：" + condition.contentKeywords.sorted().joined(separator: ",")) }
  if condition.semanticDescription != nil { parts.append("需要本地 AI 判断") }
  return parts.joined(separator: " · ")
}
