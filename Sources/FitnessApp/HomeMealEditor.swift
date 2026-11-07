import SwiftUI
import PhotosUI
import FitnessCore

struct HomeMealEditor: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @Environment(\.scenePhase) var scenePhase
  @State var draft: HomeMealDraft
  @State private var selection: PhotosPickerItem?
  @State private var consent = false
  @State private var checked = false
  @State private var busy = false
  @State private var message: String?
  @State private var task: Task<Void, Never>?
  @State private var requestID: UUID?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack { Text("核对这一餐").font(.title2.bold()); Spacer(); Button("返回对话") { dismiss() } }
        if let photo = draft.photo { LocalPhoto(bytes: photo).frame(height: 180).clipped().clipShape(RoundedRectangle(cornerRadius: 14)) }
        PhotosPicker(selection: $selection, matching: .images) { Label("更换餐食照片", systemImage: "photo") }.disabled(busy)
        TextField("食物名称", text: Binding(get: { draft.title }, set: { draft.title = $0; edited() })).entryField().disabled(busy)
        TextField("实际份量、油酱料或其他补充", text: Binding(get: { draft.description }, set: { draft.description = $0; edited() }), axis: .vertical).entryField().disabled(busy)
        DatePicker("实际吃饭时间", selection: $draft.date, in: ...Date()).onChange(of: draft.date) { _, _ in checked = false; persist() }
        if let result = draft.result { MealAnalysisPreview(result: result) }
        Toggle("同意本次发送食物文字和所选照片给 Agent / DeepSeek", isOn: $consent).font(.caption)
        Text("不附带健康摘要。私人服务不保存餐食内容，服务商可能保留输入；更改食物或照片后须重新确认上传。").font(.caption).foregroundStyle(Color.secondaryInk)
        MainButton(title: busy ? "正在重新分析…" : "分析当前食物与份量", symbol: "sparkles") { analyze() }.disabled(!consent || busy)
        if busy { Button("取消分析") { cancel(); message = "已取消等待，草稿保留；不会自动重试。" } }
        if let message { Text(message).font(.caption).foregroundStyle(Color.secondaryInk) }
        DisclosureGroup("手动核对营养数据") {
          NutritionFields(facts: Binding(get: { draft.nutrition ?? MealNutrition() }, set: { draft.nutrition = $0; checked = false; persist() }))
        }
        Toggle("已核对食物、份量、时间与营养来源", isOn: $checked)
        MainButton(title: "确认吃过并保存", symbol: "checkmark") {
          if store.confirmHomeMeal(draft) { dismiss() }
        }.disabled(!checked || busy || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Text("未保存的修改自动保留为草稿，不进入当日合计。改变食物或份量会清除旧的 AI 估算。").font(.caption).foregroundStyle(Color.secondaryInk)
      }.padding(24)
    }.frame(minWidth: 340, minHeight: 520).background(Color.canvas)
      .onChange(of: selection) { _, item in
        Task { @MainActor in
          guard let bytes = try? await item?.loadTransferable(type: Data.self), item == selection else { return }
          guard bytes.count <= 20_000_000 else { message = "请使用 20 MB 以内的图片。"; return }
          draft.photo = bytes; edited()
        }
      }
      .onChange(of: scenePhase) { _, phase in if phase == .background { cancel(); consent = false } }
      .onDisappear { cancel() }
  }
  private func persist() { _ = store.setHomeMeal(draft) }
  private func cancel() { task?.cancel(); requestID = nil; busy = false }
  private func edited() {
    cancel(); consent = false; checked = false
    draft.invalidateEstimate()
    message = "食物或份量已修改，旧的 AI 估计已清除。"; persist()
  }
  private func analyze() {
    guard consent, let transport = AgentConnection.load().transport else { message = "请先在首页设置 Agent 连接，并确认本次上传。"; return }
    let captured = draft, id = UUID()
    let description = captured.title + "\n" + captured.description
    guard description.count <= 3000 else { message = "名称和描述合计请控制在 3000 字以内。"; return }
    requestID = id; busy = true; checked = false; message = nil
    task = Task { @MainActor in
      defer { if requestID == id { busy = false } }
      do {
        let jpeg = try captured.photo.map(mealUploadJPEG)
        let result = try await transport.analyze(id: id.uuidString, description: description, jpeg: jpeg, consent: true)
        try Task.checkCancellation(); guard requestID == id else { return }
        draft.result = result; draft.title = result.title; draft.analysisInput = draft.description
        draft.nutrition = result.totals.hasNumbers ? result.estimatedNutrition : nil
        consent = false; persist()
      } catch { if requestID == id && !Task.isCancelled { message = "分析未完成，草稿已保留，可手动重试。" } }
    }
  }
}
