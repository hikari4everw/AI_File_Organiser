import AIFileOrganizerCore
import SwiftUI

struct HistoryView: View {
  @ObservedObject var model: AppModel
  let showPlan: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("历史与撤销").font(.title2.bold())
        Text("历史保存在本机。重新启动应用后，仍可对状态未变化的项目执行安全撤销。")
          .foregroundStyle(.secondary)
        if model.historyEntries.isEmpty {
          ContentUnavailableView("暂无整理历史", systemImage: "clock",
            description: Text("执行过的确认计划会出现在这里。"))
        }
        ForEach(model.historyEntries, id: \.plan.id) { entry in
          let completed = entry.receipt?.results.filter { $0.state == .completed }.count ?? 0
          let moveCount = entry.plan.operations.filter { $0.kind == .move }.count
          let renameCount = entry.plan.operations.filter { $0.namingDecisionFeatures != nil }.count
          let retryableBlocked = entry.receipt?.isUndoReceipt == true
            ? entry.receipt?.results.filter { $0.state == .blocked }.count ?? 0 : 0
          let canUndo = completed + retryableBlocked > 0
          let issues = entry.receipt?.results.filter { $0.state == .failed || $0.state == .blocked }.count ?? 0
          HStack(spacing: 16) {
            Image(systemName: issues == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
              .font(.title2).foregroundStyle(issues == 0 ? .green : .orange)
            VStack(alignment: .leading, spacing: 5) {
              Text(entry.plan.confirmedAt.formatted(date: .abbreviated, time: .shortened))
                .fontWeight(.semibold)
              Text("完成 \(completed) 项 · 问题 \(issues) 项 · 共 \(entry.plan.operations.count) 个操作")
                .font(.caption).foregroundStyle(.secondary)
              Text("移动 \(moveCount) 项 · 改名 \(renameCount) 项")
                .font(.caption).foregroundStyle(.secondary)
              ForEach(entry.plan.operations.filter { $0.kind == .move || $0.kind == .rename }) {
                operation in
                Text(historyOperationSummary(operation))
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
              }
            }
            Spacer()
            if canUndo {
              Button("查看并撤销") {
                model.useHistoryEntry(entry)
                showPlan()
              }
            } else if entry.receipt != nil {
              Label("已撤销", systemImage: "arrow.uturn.backward.circle")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.35)))
        }
      }.padding(28).frame(maxWidth: 900)
    }
  }
}

private func historyOperationSummary(_ operation: PlannedOperation) -> String {
  guard let sourcePath = operation.sourcePath else {
    return URL(fileURLWithPath: operation.destinationPath).lastPathComponent
  }
  let sourceName = URL(fileURLWithPath: sourcePath).lastPathComponent
  let destinationName = URL(fileURLWithPath: operation.destinationPath).lastPathComponent
  return "\(sourceName)  →  \(destinationName)"
}
