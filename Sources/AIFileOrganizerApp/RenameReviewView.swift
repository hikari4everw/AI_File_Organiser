import AIFileOrganizerCore
import SwiftUI

struct RenameReviewView: View {
  @ObservedObject var model: AppModel
  let item: ItemSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("文件名建议").font(.headline)
        Spacer()
        if let proposal {
          RenameSourceBadge(proposal: proposal)
        }
      }

      if item.kind == .applicationBundle {
        Label("应用包不提供改名建议", systemImage: "app.badge.checkmark")
          .font(.callout).foregroundStyle(.secondary)
      } else if let proposal {
        RenameProposalEditor(model: model, item: item, proposal: proposal)
          .id(proposal.id.uuidString + proposal.disposition.rawValue)
      } else {
        Text("保留原名称。你也可以为这个项目单独请求本地 AI 建议。")
          .font(.callout).foregroundStyle(.secondary)
        Button("请求 AI 命名建议") { model.requestFilenameSuggestion(for: item.id) }
          .disabled(model.isWorking)
          .accessibilityIdentifier("rename-request-suggestion")
      }
    }
  }

  private var proposal: RenameProposal? { model.renameProposal(for: item.id) }
}

private struct RenameProposalEditor: View {
  @ObservedObject var model: AppModel
  let item: ItemSnapshot
  let proposal: RenameProposal
  @State private var editedName: String

  init(model: AppModel, item: ItemSnapshot, proposal: RenameProposal) {
    self.model = model
    self.item = item
    self.proposal = proposal
    _editedName = State(initialValue: proposal.editedBaseName ?? proposal.suggestedBaseName)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text(proposal.originalName).foregroundStyle(.secondary)
        HStack(spacing: 6) {
          Image(systemName: "arrow.down").foregroundStyle(.tertiary)
          Text(previewName).fontWeight(.semibold)
            .accessibilityIdentifier("rename-preview")
        }
      }

      HStack(spacing: 6) {
        TextField(item.kind == .file ? "新主文件名" : "新目录名", text: $editedName)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("rename-editor")
        if item.kind == .file, !item.fileExtension.isEmpty {
          Text(".\(item.fileExtension)")
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("扩展名已锁定为 \(item.fileExtension)")
        }
        Button("应用") { model.updateRename(proposal.id, baseName: editedName) }
          .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }

      if !proposal.missingFields.isEmpty {
        Label(
          "缺少字段：" + proposal.missingFields.map(\.placeholder).joined(separator: "、"),
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption).foregroundStyle(.orange)
        .accessibilityIdentifier("rename-missing-fields")
      }

      if proposal.disposition == .blocked {
        Label(proposal.reason, systemImage: "xmark.octagon.fill")
          .font(.caption).foregroundStyle(.red)
          .accessibilityIdentifier("rename-conflict")
      } else {
        Text(proposal.reason).font(.caption).foregroundStyle(.secondary)
      }

      HStack {
        if proposal.disposition == .pending {
          Button("采用建议") { model.acceptRename(proposal.id) }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("rename-accept")
        }
        if proposal.disposition != .rejected {
          Button("恢复原名") { model.rejectRename(proposal.id) }
            .accessibilityIdentifier("rename-restore-original")
        }
        Spacer()
        if proposal.disposition == .pending {
          Text("执行前必须确认").font(.caption).foregroundStyle(.orange)
        }
      }
    }
  }

  private var previewName: String {
    guard item.kind == .file, !item.fileExtension.isEmpty else { return editedName }
    return editedName + "." + item.fileExtension
  }
}

private struct RenameSourceBadge: View {
  let proposal: RenameProposal

  var body: some View {
    Text(label)
      .font(.caption.weight(.medium))
      .padding(.horizontal, 7).padding(.vertical, 3)
      .background(tint.opacity(0.12), in: Capsule())
      .foregroundStyle(tint)
  }

  private var label: String {
    switch proposal.source {
    case .namingRule: "命名规则"
    case .foundationModel: "本地 AI"
    case .user: "手动编辑"
    }
  }

  private var tint: Color {
    switch proposal.disposition {
    case .blocked: .red
    case .pending: .orange
    case .selectedByRule, .approved, .edited: .green
    case .rejected: .secondary
    }
  }
}
