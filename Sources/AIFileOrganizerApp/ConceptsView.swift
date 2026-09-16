import AIFileOrganizerCore
import SwiftUI
import UniformTypeIdentifiers

struct ConceptsView: View {
  @ObservedObject var model: AppModel
  @State private var name = ""
  @State private var description = ""
  @State private var aliases = ""
  @State private var parentID: UUID?
  @State private var destinationID: UUID?
  @State private var externalURLs: [URL] = []
  @State private var showingImporter = false
  @State private var editingID: UUID?
  @State private var editName = ""
  @State private var editDescription = ""
  @State private var editAliases = ""
  @State private var editParentID: UUID?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text("教会系统认识文件").font(.title2.bold())
          Text("概念描述文件是什么；目标目录是可选的整理偏好。示例只保存在这台 Mac 上，文件不会被移动。")
            .foregroundStyle(.secondary)
          Text(model.conceptModelStatus).font(.caption).foregroundStyle(.secondary)
          if model.conceptModelStatus != "本地图像概念模型已安装" {
            Button(model.isDownloadingConceptModel ? "正在下载…" : "下载本地图像模型（约 173 MB）") {
              model.installConceptModel()
            }
            .disabled(model.isDownloadingConceptModel)
          }
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("新概念").font(.headline)
          TextField("这些文件是什么？例如：COMP2012 课程讲义", text: $name)
            .textFieldStyle(.roundedBorder)
          TextField("补充说明（可选）", text: $description)
            .textFieldStyle(.roundedBorder)
          TextField("别名（可选，用逗号分隔）", text: $aliases)
            .textFieldStyle(.roundedBorder)
          Picker("上级概念（可选）", selection: $parentID) {
            Text("无").tag(UUID?.none)
            ForEach(model.concepts) { concept in
              Text(concept.name).tag(Optional(concept.id))
            }
          }
          Picker("默认目标（可选）", selection: $destinationID) {
            Text("只学习识别，不指定目录").tag(UUID?.none)
            ForEach(model.destinations.filter { $0.kind == .category }) { destination in
              Text(destination.relativePath).tag(Optional(destination.id))
            }
          }
          Text("已选收件箱项目：\(model.selectedItemIDs.count) · 外部示例：\(externalURLs.count)")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            Button("选择外部示例…") { showingImporter = true }
            Spacer()
            Button("建立概念并学习") {
              guard model.saveConcept(
                name: name, description: description,
                aliases: aliases.split(separator: ",").map {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }, parentID: parentID,
                defaultDestinationID: destinationID,
                itemIDs: model.selectedItemIDs, externalURLs: externalURLs) else { return }
              name = ""
              description = ""
              aliases = ""
              parentID = nil
              destinationID = nil
              externalURLs = []
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || model.isTeachingConcept)
          }
        }
        .padding(16).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))

        Text("已学概念").font(.headline)
        if model.concepts.isEmpty {
          ContentUnavailableView("还没有概念", systemImage: "square.stack.3d.up",
            description: Text("选择代表性文件并告诉系统它们是什么。"))
        }
        ForEach(model.concepts) { concept in
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 4) {
                Text(concept.name).fontWeight(.medium)
                if !concept.description.isEmpty {
                  Text(concept.description).font(.caption).foregroundStyle(.secondary)
                }
                if let parentID = concept.parentID,
                  let parent = model.concepts.first(where: { $0.id == parentID })
                {
                  Text("属于 \(parent.name)").font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              Button("编辑") {
                editingID = concept.id
                editName = concept.name
                editDescription = concept.description
                editAliases = concept.aliases.joined(separator: ", ")
                editParentID = concept.parentID
              }
              if !model.selectedItemIDs.isEmpty || !externalURLs.isEmpty {
                Button("教正例") {
                  model.teachConcept(
                    concept.id, itemIDs: model.selectedItemIDs,
                    externalURLs: externalURLs, isPositive: true)
                  externalURLs = []
                }.disabled(model.isTeachingConcept)
                Button("教反例") {
                  model.teachConcept(
                    concept.id, itemIDs: model.selectedItemIDs,
                    externalURLs: externalURLs, isPositive: false)
                  externalURLs = []
                }.disabled(model.isTeachingConcept)
              }
              Button(role: .destructive) { model.deleteConcept(concept.id) } label: {
                Image(systemName: "trash")
              }.buttonStyle(.borderless)
            }
            if editingID == concept.id {
              TextField("名称", text: $editName).textFieldStyle(.roundedBorder)
              TextField("说明", text: $editDescription).textFieldStyle(.roundedBorder)
              TextField("别名（逗号分隔）", text: $editAliases).textFieldStyle(.roundedBorder)
              Picker("上级概念", selection: $editParentID) {
                Text("无").tag(UUID?.none)
                ForEach(model.concepts.filter { $0.id != concept.id }) { parent in
                  Text(parent.name).tag(Optional(parent.id))
                }
              }
              HStack {
                Button("取消") { editingID = nil }
                Button("保存修改") {
                  if model.updateConcept(
                    concept.id, name: editName, description: editDescription,
                    aliases: editAliases.split(separator: ",").map {
                      $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }, parentID: editParentID)
                  { editingID = nil }
                }.buttonStyle(.borderedProminent)
              }
            }
          }
          .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 12))
        }
      }
      .padding(28).frame(maxWidth: 900)
    }
    .fileImporter(
      isPresented: $showingImporter, allowedContentTypes: [.item, .folder],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls): externalURLs = urls
      case .failure(let error): model.lastError = error.localizedDescription
      }
    }
  }
}
