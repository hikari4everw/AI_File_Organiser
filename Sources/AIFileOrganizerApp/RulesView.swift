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
          Text("AI 只负责把自然语言转换成草稿；保存前你可以检查条件和目标。")
            .foregroundStyle(.secondary)
          HStack {
            TextField("例如：PDF 乐谱放到 音乐/乐谱", text: $input)
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
                Text("→ \(model.destinationName(rule.destinationID)) · \(conditionSummary(rule.condition))")
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
      }
      .padding(28).frame(maxWidth: 900)
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
      Picker("目标目录", selection: $draft.destinationID) {
        Text("请选择…").tag(UUID?.none)
        ForEach(model.destinations.filter { $0.kind == .category }) { destination in
          Text(destination.relativePath).tag(Optional(destination.id))
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

private func conditionSummary(_ condition: RuleCondition) -> String {
  var parts: [String] = []
  if !condition.itemKinds.isEmpty { parts.append(condition.itemKinds.map(\.rawValue).sorted().joined(separator: ",")) }
  if !condition.fileExtensions.isEmpty { parts.append(condition.fileExtensions.sorted().map { ".\($0)" }.joined(separator: ",")) }
  if !condition.filenameKeywords.isEmpty { parts.append("名称含：" + condition.filenameKeywords.sorted().joined(separator: ",")) }
  if !condition.contentKeywords.isEmpty { parts.append("内容含：" + condition.contentKeywords.sorted().joined(separator: ",")) }
  if condition.semanticDescription != nil { parts.append("需要本地 AI 判断") }
  return parts.joined(separator: " · ")
}
