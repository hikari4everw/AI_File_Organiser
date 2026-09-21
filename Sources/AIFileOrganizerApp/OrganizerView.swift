import AIFileOrganizerCore
import SwiftUI

struct OrganizerView: View {
  @ObservedObject var model: AppModel
  @State private var page: OrganizerPage = .plan
  @State private var showExecutionConfirmation = false
  @State private var showNewFolder = false
  @State private var newFolderName = ""

  var body: some View {
    HSplitView {
      sidebar.frame(minWidth: 180, idealWidth: 200, maxWidth: 230)
      VStack(spacing: 0) {
        header
        Divider()
        switch page {
        case .plan:
          if model.proposals.isEmpty {
            emptyState
          } else {
            HSplitView {
              proposalList.frame(minWidth: 560)
              detailPanel.frame(minWidth: 280, idealWidth: 330, maxWidth: 420)
            }
            if !model.isWorking {
              Divider()
              executionBar
            }
          }
        case .rules:
          RulesView(model: model)
        case .concepts:
          ConceptsView(model: model)
        case .history:
          HistoryView(model: model) { page = .plan }
        }
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
        if model.canCancel {
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
      Button("移动 \(preparedMoveCount) 项，改名 \(preparedRenameCount) 项") {
        model.executePreparedPlan()
      }
      Button("取消", role: .cancel) { model.discardPreparedPlan() }
    } message: {
      Text("只执行当前已确认的移动和改名，不覆盖或删除文件。执行前会再次检查所有项目。")
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

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("AI File Organizer", systemImage: "sparkles.rectangle.stack.fill")
        .font(.headline).padding(.horizontal, 12).padding(.bottom, 10)
      ForEach(OrganizerPage.allCases) { value in
        Button {
          page = value
        } label: {
          HStack {
            Label(value.title, systemImage: value.icon)
            Spacer()
            if value == .history, !model.historyEntries.isEmpty {
              Text("\(model.historyEntries.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
          }
          .padding(.horizontal, 10).padding(.vertical, 8)
          .background(page == value ? Color.accentColor.opacity(0.14) : .clear,
            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
      }
      Spacer()
      VStack(alignment: .leading, spacing: 5) {
        Label("本地处理", systemImage: "lock.shield")
        Text("已积累 \(model.learningSampleCount) 条有效偏好")
      }
      .font(.caption).foregroundStyle(.secondary).padding(12)
    }
    .padding(10)
    .background(.regularMaterial)
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
      if !model.isWorking && model.receipt == nil {
        Button("开始整理") { model.startOrganizing() }
          .buttonStyle(.borderedProminent).controlSize(.large)
      } else if model.receipt != nil {
        Button("撤销已载入的整理") { model.undo() }
          .buttonStyle(.borderedProminent)
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
            title: group.destination.relativePath,
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
          Button(destination.relativePath) {
            model.setDestination(destination.id, for: model.selectedItemIDs)
          }
        }
      }
      Button("新建目录…") { showNewFolder = true }
      Button("保留原处") { model.keep(model.selectedItemIDs) }
      Button("这些项目保留原名") { model.rejectRenames(for: model.selectedItemIDs) }
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
            if let recognition = model.recognitionByItem[item.id] {
              Divider()
              Text("文件概念").font(.headline)
              if recognition.confirmedConceptIDs.isEmpty, recognition.candidates.isEmpty {
                Text("尚未识别").foregroundStyle(.secondary)
              }
              ForEach(model.concepts.filter {
                recognition.confirmedConceptIDs.contains($0.id)
              }) { concept in
                HStack {
                  Label(concept.name, systemImage: "checkmark.seal")
                  Spacer()
                  Menu("改为…") {
                    ForEach(model.concepts.filter { $0.id != concept.id }) { replacement in
                      Button(replacement.name) {
                        model.replaceConceptLabel(
                          from: concept.id, to: replacement.id, itemID: item.id)
                      }
                    }
                  }
                  .disabled(model.concepts.count < 2 || model.isTeachingConcept)
                  Button("纠正") {
                    model.teachConcept(concept.id, itemIDs: [item.id], isPositive: false)
                  }
                  .disabled(model.isTeachingConcept)
                }
              }
              ForEach(recognition.candidates.prefix(3), id: \.conceptID) { candidate in
                if let concept = model.concepts.first(where: { $0.id == candidate.conceptID }) {
                  HStack {
                    Text(
                      recognition.status == .confident
                        && recognition.candidates.first?.conceptID == candidate.conceptID
                        ? "高度相似：\(concept.name)"
                        : "可能是 \(concept.name)"
                    )
                    Spacer()
                    Button("确认") {
                      model.teachConcept(concept.id, itemIDs: [item.id], isPositive: true)
                    }
                    Button("排除") {
                      model.teachConcept(concept.id, itemIDs: [item.id], isPositive: false)
                    }
                  }
                }
              }
            }
            Divider()
            Text("为什么这样建议").font(.headline)
            Text(proposal.reason).foregroundStyle(.secondary)
            Divider()
            RenameReviewView(model: model, item: item)
            Menu("更改目标") {
              ForEach(model.destinations) { destination in
                Button(destination.relativePath) {
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
          "移动 \(moveCount) 项 · 改名 \(model.selectedRenameProposals.count) 项 · 创建 \(approvedFolderCount) 个目录 · 保留 \(model.keptProposals.count) 项 · 待确认改名 \(model.pendingRenameCount) 项 · 阻塞 \(blockingCount) 项"
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

  private var preparedRenameCount: Int {
    model.currentPlan?.operations.filter { $0.namingDecisionFeatures != nil }.count
      ?? model.selectedRenameProposals.count
  }

  private var blockingCount: Int {
    model.reviewProposals.count + model.pendingFolderCount + model.blockedRenameCount
  }
}

private enum OrganizerPage: String, CaseIterable, Identifiable {
  case plan, concepts, rules, history
  var id: String { rawValue }
  var title: String {
    switch self { case .plan: "整理计划"; case .concepts: "文件概念"; case .rules: "我的规则"; case .history: "历史与撤销" }
  }
  var icon: String {
    switch self { case .plan: "rectangle.3.group"; case .concepts: "square.stack.3d.up"; case .rules: "text.badge.checkmark"; case .history: "clock.arrow.circlepath" }
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
        if let proposedName = model.proposedFullName(for: item),
          proposedName != item.name,
          let rename = model.renameProposal(for: item.id)
        {
          HStack(spacing: 6) {
            Text(item.name).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            Text(proposedName).fontWeight(.medium)
            if rename.disposition == .pending {
              Text("待确认").font(.caption2).foregroundStyle(.orange)
            }
          }
          .lineLimit(1)
          .accessibilityIdentifier("rename-row-preview")
        } else {
          Text(item.name).lineLimit(1)
        }
        Text("\(URL(fileURLWithPath: item.path).deletingLastPathComponent().lastPathComponent)  →  \(model.destinationName(proposal.destinationID))")
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      Text(proposal.reason).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
    }
    .padding(.horizontal, 12).padding(.vertical, 9)
    .contentShape(Rectangle())
    .onTapGesture { model.selectedItemID = item.id }
    .draggable(item.id.uuidString)
  }
}
