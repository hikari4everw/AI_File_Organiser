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
                Text("\(actionSummary(rule, model: model)) · \(conditionSummary(rule.condition))")
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
                Text("\(conditionSummary(rule.condition)) → \(rule.template.pattern)")
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

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("请确认命名规则草稿", systemImage: "character.cursor.ibeam").font(.headline)
      TextField("原始描述", text: $draft.originalText).textFieldStyle(.roundedBorder)
      TextField("命名模板", text: Binding(
        get: { draft.template.pattern },
        set: { draft.template.pattern = $0 }))
        .textFieldStyle(.roundedBorder)
      Text("支持 {原标题}、{标题}、{作者}、{日期}。缺失字段时不会改名。")
        .font(.caption).foregroundStyle(.secondary)
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
        Button("放弃") { model.namingRuleDrafts.removeAll { $0.id == draft.id } }
        Button("保存命名规则") { model.saveNamingRuleDraft(draft) }
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(16).background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
  }

  private func commaSet(_ text: String) -> Set<String> {
    Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      .filter { !$0.isEmpty })
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

private func conditionSummary(_ condition: RuleCondition) -> String {
  var parts: [String] = []
  if !condition.itemKinds.isEmpty { parts.append(condition.itemKinds.map(\.rawValue).sorted().joined(separator: ",")) }
  if !condition.fileExtensions.isEmpty { parts.append(condition.fileExtensions.sorted().map { ".\($0)" }.joined(separator: ",")) }
  if !condition.filenameKeywords.isEmpty { parts.append("名称含：" + condition.filenameKeywords.sorted().joined(separator: ",")) }
  if !condition.contentKeywords.isEmpty { parts.append("内容含：" + condition.contentKeywords.sorted().joined(separator: ",")) }
  if condition.semanticDescription != nil { parts.append("需要本地 AI 判断") }
  return parts.joined(separator: " · ")
}
