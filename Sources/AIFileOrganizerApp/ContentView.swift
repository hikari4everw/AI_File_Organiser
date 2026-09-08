import AIFileOrganizerCore
import SwiftUI

struct ContentView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Group {
      if model.workspace == nil {
        SetupView(model: model)
      } else {
        OrganizerView(model: model)
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
