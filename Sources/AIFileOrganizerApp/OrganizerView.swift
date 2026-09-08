import AIFileOrganizerCore
import SwiftUI

struct OrganizerView: View {
  @ObservedObject var model: AppModel
  @State private var showExecutionConfirmation = false
  @State private var showNewFolder = false
  @State private var newFolderName = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if model.proposals.isEmpty {
        emptyState
      } else {
        HSplitView {
          proposalList.frame(minWidth: 620)
          detailPanel.frame(minWidth: 280, idealWidth: 330, maxWidth: 420)
        }
        Divider()
        executionBar
      }
    }
    .toolbar {
      ToolbarItemGroup {
        Button {
          model.startOrganizing()
        } label: {
          Label("开始整理", systemImage: "sparkles")
        }
        .disabled(model.isWorking)
        if model.isWorking {
          Button("停止", role: .cancel) { model.cancel() }
        }
        Menu {
          Button("重新选择目录…") { model.forgetWorkspace() }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .confirmationDialog("确认执行本次整理？", isPresented: $showExecutionConfirmation) {
      Button("移动 \(preparedMoveCount) 个项目") { model.executePreparedPlan() }
      Button("取消", role: .cancel) { model.discardPreparedPlan() }
    } message: {
      Text("不会覆盖、删除或自动重命名文件。执行前会再次检查所有项目。")
    }
    .alert("创建资料库一级目录", isPresented: $showNewFolder) {
      TextField("目录名称", text: $newFolderName)
      Button("取消", role: .cancel) { newFolderName = "" }
      Button("加入方案") {
        model.createFolder(named: newFolderName, for: model.selectedItemIDs)
        newFolderName = ""
      }
    } message: {
      Text("目录只会在你执行整理时创建。")
    }
  }

  private var header: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("收件箱整理").font(.title2.bold())
        if let workspace = model.workspace {
          Text(
            URL(fileURLWithPath: workspace.inboxPath).lastPathComponent + " → "
              + URL(fileURLWithPath: workspace.libraryPath).lastPathComponent
          )
          .font(.subheadline).foregroundStyle(.secondary)
        }
      }
      Spacer()
      Label(model.modelStatus, systemImage: "apple.intelligence")
        .font(.caption)
        .foregroundStyle(.secondary)
      if model.isWorking { ProgressView().controlSize(.small) }
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 14)
  }

  @ViewBuilder private var emptyState: some View {
    VStack(spacing: 18) {
      Spacer()
      Image(systemName: model.receipt == nil ? "tray" : "checkmark.circle.fill")
        .font(.system(size: 48)).foregroundStyle(
          model.receipt == nil ? Color.secondary : Color.green)
      Text(model.statusMessage.isEmpty ? "准备好后，开始一次整理" : model.statusMessage)
        .font(.title3.bold())
      if model.isWorking {
        Text("已发现 \(model.discoveredCount) 项，跳过 \(model.skippedCount) 项")
          .foregroundStyle(.secondary)
      } else if model.receipt == nil {
        Button("开始整理") { model.startOrganizing() }
          .buttonStyle(.borderedProminent).controlSize(.large)
      }
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var proposalList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        if !model.folderProposals.isEmpty { folderProposalArea }
        if !model.reviewProposals.isEmpty {
          ProposalSection(
            title: "需要处理",
            subtitle: "目标模糊、状态异常或需要你的决定",
            icon: "exclamationmark.triangle.fill",
            tint: .orange,
            proposals: model.reviewProposals,
            model: model
          )
        }
        ForEach(destinationGroups, id: \.destination.id) { group in
          ProposalSection(
            title: group.destination.displayName,
            subtitle: "可以整理 · \(group.proposals.count) 项",
            icon: "folder.fill",
            tint: .accentColor,
            proposals: group.proposals,
            model: model,
            dropDestinationID: group.destination.id
          )
        }
        if !model.keptProposals.isEmpty {
          ProposalSection(
            title: "保留原处",
            subtitle: "本次不会移动",
            icon: "tray",
            tint: .secondary,
            proposals: model.keptProposals,
            model: model
          )
        }
      }
      .padding(20)
    }
    .safeAreaInset(edge: .top) {
      if !model.selectedItemIDs.isEmpty { batchBar }
    }
  }

  private var folderProposalArea: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("新目录建议", systemImage: "folder.badge.plus").font(.headline)
      ForEach(model.folderProposals) { proposal in
        HStack {
          VStack(alignment: .leading) {
            Text(proposal.displayName).fontWeight(.medium)
            Text("包含 \(proposal.relatedItemIDs.count) 个项目 · 资料库第一级")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          switch proposal.status {
          case .pending:
            Button("拒绝") { model.setFolderProposal(proposal.id, approved: false) }
            Button("批准") { model.setFolderProposal(proposal.id, approved: true) }
              .buttonStyle(.borderedProminent)
          case .approved: Label("已批准", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          case .rejected: Text("已拒绝").foregroundStyle(.secondary)
          }
        }
        .padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
      }
    }
  }

  private var batchBar: some View {
    HStack {
      Text("已选择 \(model.selectedItemIDs.count) 项").fontWeight(.medium)
      Spacer()
      Menu("移动到…") {
        ForEach(model.destinations) { destination in
          Button(destination.displayName) {
            model.setDestination(destination.id, for: model.selectedItemIDs)
          }
        }
      }
      Button("新建目录…") { showNewFolder = true }
      Button("保留原处") { model.keep(model.selectedItemIDs) }
      Button("取消选择") { model.selectedItemIDs.removeAll() }
    }
    .padding(.horizontal, 18).padding(.vertical, 10)
    .background(.bar)
  }

  private var detailPanel: some View {
    Group {
      if let id = model.selectedItemID,
        let item = model.items.first(where: { $0.id == id }),
        let proposal = model.proposals.first(where: { $0.itemID == id })
      {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            FileThumbnail(path: item.path).frame(height: 190)
            Text(item.name).font(.title3.bold()).textSelection(.enabled)
            LabeledContent("类型", value: item.contentType ?? item.fileExtension.uppercased())
            LabeledContent(
              "大小", value: ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
            LabeledContent("目标", value: model.destinationName(proposal.destinationID))
            Divider()
            Text("为什么这样建议").font(.headline)
            Text(proposal.reason).foregroundStyle(.secondary)
            Menu("更改目标") {
              ForEach(model.destinations) { destination in
                Button(destination.displayName) {
                  model.setDestination(destination.id, for: [item.id])
                }
              }
            }
            Button("保留在收件箱") { model.keep([item.id]) }
          }.padding(20)
        }
      } else {
        ContentUnavailableView(
          "选择一个项目", systemImage: "doc.text.magnifyingglass", description: Text("查看预览、建议理由和目标"))
      }
    }
    .background(.background.secondary)
  }

  private var executionBar: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 3) {
        Text(model.statusMessage).fontWeight(.medium)
        Text(
          "将移动 \(moveCount) 项 · 创建 \(approvedFolderCount) 个目录 · 保留 \(model.keptProposals.count) 项 · \(model.reviewProposals.count + model.pendingFolderCount) 个问题"
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if model.receipt != nil {
        Button("撤销本次整理") { model.undo() }.disabled(model.isWorking)
      }
      Button("执行整理") {
        Task {
          if await model.prepareExecution() { showExecutionConfirmation = true }
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!model.canExecute)
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
    .background(.bar)
  }

  private var destinationGroups:
    [(destination: DestinationProfile, proposals: [ClassificationProposal])]
  {
    model.destinations.compactMap { destination in
      let proposals = model.readyProposals.filter { $0.destinationID == destination.id }
      return proposals.isEmpty ? nil : (destination, proposals)
    }
  }

  private var moveCount: Int {
    let folderItems = Set(
      model.folderProposals.filter { $0.status == .approved }.flatMap(\.relatedItemIDs))
    return model.readyProposals.filter { !folderItems.contains($0.itemID) }.count
      + folderItems.count
  }

  private var approvedFolderCount: Int {
    model.folderProposals.filter { $0.status == .approved }.count
  }

  private var preparedMoveCount: Int {
    model.currentPlan?.operations.filter { $0.kind == .move }.count ?? moveCount
  }
}

private struct ProposalSection: View {
  let title: String
  let subtitle: String
  let icon: String
  let tint: Color
  let proposals: [ClassificationProposal]
  @ObservedObject var model: AppModel
  var dropDestinationID: UUID?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(title, systemImage: icon).font(.headline).foregroundStyle(tint)
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
      VStack(spacing: 0) {
        ForEach(proposals) { proposal in
          if let item = model.item(for: proposal) {
            ProposalRow(item: item, proposal: proposal, model: model)
            if proposal.id != proposals.last?.id { Divider().padding(.leading, 42) }
          }
        }
      }
      .background(.background, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.35)))
    }
    .dropDestination(for: String.self) { values, _ in
      guard let destinationID = dropDestinationID else { return false }
      let ids = Set(values.compactMap(UUID.init(uuidString:)))
      guard !ids.isEmpty else { return false }
      model.setDestination(destinationID, for: ids)
      return true
    }
  }
}

private struct ProposalRow: View {
  let item: ItemSnapshot
  let proposal: ClassificationProposal
  @ObservedObject var model: AppModel

  var body: some View {
    HStack(spacing: 10) {
      Button {
        if model.selectedItemIDs.contains(item.id) {
          model.selectedItemIDs.remove(item.id)
        } else {
          model.selectedItemIDs.insert(item.id)
        }
      } label: {
        Image(
          systemName: model.selectedItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
      }.buttonStyle(.plain).accessibilityLabel("选择 \(item.name)")
      Image(systemName: item.kind == .file ? "doc" : "folder")
        .foregroundStyle(proposal.reviewDecision == .needsReview ? .orange : .secondary)
      VStack(alignment: .leading, spacing: 3) {
        Text(item.name).lineLimit(1)
        Text(proposal.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      Text(model.destinationName(proposal.destinationID)).font(.caption).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12).padding(.vertical, 9)
    .contentShape(Rectangle())
    .onTapGesture { model.selectedItemID = item.id }
    .draggable(item.id.uuidString)
  }
}
