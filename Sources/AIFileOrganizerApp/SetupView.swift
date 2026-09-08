import AppKit
import SwiftUI

struct SetupView: View {
  @ObservedObject var model: AppModel
  @State private var inbox: URL?
  @State private var library: URL?

  var body: some View {
    VStack(spacing: 28) {
      Spacer()
      Image(systemName: "sparkles.rectangle.stack")
        .font(.system(size: 54, weight: .medium))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      VStack(spacing: 8) {
        Text("整理收件箱，不打乱你的生活")
          .font(.largeTitle.bold())
        Text("所有分析都在这台 Mac 上完成。执行前，你会看到完整方案。")
          .font(.title3)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 18) {
        FolderCard(
          title: "收件箱",
          subtitle: "待整理文件所在目录",
          icon: "tray.full",
          url: inbox,
          suggestedURL: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first
        ) { inbox = chooseDirectory(title: "选择收件箱") }
        FolderCard(
          title: "资料库",
          subtitle: "文件最终归档的位置",
          icon: "folder.badge.gearshape",
          url: library,
          suggestedURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ) { library = chooseDirectory(title: "选择资料库") }
      }
      .frame(maxWidth: 760)
      VStack(spacing: 10) {
        Button("完成设置") {
          if let inbox, let library { model.configure(inbox: inbox, library: library) }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(inbox == nil || library == nil)
        Text("V2.0 要求两个目录位于同一个磁盘，且不能互相包含。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(40)
  }

  private func chooseDirectory(title: String) -> URL? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    return panel.runModal() == .OK ? panel.url : nil
  }
}

private struct FolderCard: View {
  let title: String
  let subtitle: String
  let icon: String
  let url: URL?
  let suggestedURL: URL?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 14) {
        Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.headline)
          Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
        Label(
          url?.path(percentEncoded: false) ?? suggestedText,
          systemImage: url == nil ? "plus" : "checkmark.circle.fill"
        )
        .font(.caption)
        .lineLimit(2)
        .foregroundStyle(url == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
      }
      .padding(20)
      .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
      .overlay(RoundedRectangle(cornerRadius: 18).stroke(.separator.opacity(0.4)))
    }
    .buttonStyle(.plain)
  }

  private var suggestedText: String {
    suggestedURL.map { "选择目录（建议：\($0.lastPathComponent)）" } ?? "选择目录"
  }
}
