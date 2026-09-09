import AIFileOrganizerCore
import SwiftUI

struct ContentView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      Group {
        if model.workspace == nil {
          SetupView(model: model)
        } else {
          OrganizerView(model: model)
        }
      }
      if let progress = model.progress {
        Divider()
        OrganizationProgressPanel(progress: progress) {
          model.cancel()
        }
      }
    }
    .alert(
      "无法完成操作",
      isPresented: Binding(
        get: { model.lastError != nil },
        set: { if !$0 { model.lastError = nil } }
      )
    ) {
      Button("好", role: .cancel) { model.lastError = nil }
    } message: {
      Text(model.lastError ?? "未知错误")
    }
  }
}

private struct OrganizationProgressPanel: View {
  let progress: OrganizationProgress
  let cancel: () -> Void

  var body: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 7) {
        HStack {
          Text(title)
            .fontWeight(.medium)
            .accessibilityIdentifier("organization-progress-title")
          Spacer()
          Text(valueDescription)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("organization-progress-value")
        }
        Group {
          if progress.isIndeterminate {
            ProgressView()
          } else {
            ProgressView(
              value: Double(progress.completed),
              total: Double(max(progress.total ?? 1, 1))
            )
          }
        }
        .progressViewStyle(.linear)
        .accessibilityIdentifier("organization-progress-bar")
        .accessibilityLabel(title)
        .accessibilityValue(valueDescription)
      }

      if progress.skipped > 0 {
        Label("跳过 \(progress.skipped)", systemImage: "forward.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if progress.failed > 0 {
        Label("失败 \(progress.failed)", systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      }
      if progress.isCancellable {
        Button("停止", role: .cancel, action: cancel)
          .accessibilityIdentifier("organization-progress-stop")
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("organization-progress-panel")
  }

  private var title: String {
    switch progress.phase {
    case .scanning: "正在扫描收件箱"
    case .analyzing: "正在分析内容"
    case .aiClassifying: "本地 AI 正在分类"
    case .preflighting: "正在执行安全检查"
    case .executing: "正在移动文件"
    case .undoing: "正在撤销本次整理"
    }
  }

  private var valueDescription: String {
    if progress.isIndeterminate {
      if let total = progress.total { return "正在分析 \(total) 项" }
      return "正在准备"
    }
    guard let total = progress.total else { return "已完成 \(progress.completed) 项" }
    return "\(progress.completed) / \(total)"
  }
}
