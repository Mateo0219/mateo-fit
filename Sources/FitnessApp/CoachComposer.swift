import FitnessCore
import SwiftUI

struct CoachComposerView: View {
  @ObservedObject var draft: CoachComposerDraft
  let busy: Bool
  var loadingPhoto = false
  var models: [AgentModel] = []
  var modelsLoading = false
  var reloadModels: () -> Void = {}
  var selectedModel = ""
  var chooseModel: (String) -> Void = { _ in }
  var advanced = false
  var generation = CoachGenerationOptions()
  var chooseEffort: (String) -> Void = { _ in }
  var chooseWeb: (String) -> Void = { _ in }
  let focus: FocusState<Bool>.Binding
  let attach: () -> Void
  let removePhoto: () -> Void
  let submit: () -> Void
  private var canSend: Bool { !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.photo != nil }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let photo = draft.photo {
        HStack {
          LocalPhoto(bytes: photo).equatable().frame(width: 58, height: 58).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
          Spacer()
          Button(action: removePhoto) { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44).foregroundStyle(Color.secondaryInk) }.accessibilityLabel("移除图片")
        }.padding(.horizontal, 10).padding(.top, 8)
      }
      HStack(alignment: .bottom, spacing: 4) {
        Button(action: attach) { Image(systemName: "plus").font(.system(size: 22)).frame(width: 44, height: 44) }.accessibilityLabel("添加图片").disabled(loadingPhoto)
        TextField("发送消息", text: draft.editorText, axis: .vertical)
          .id(draft.editorRevision)
          .lineLimit(1...6).font(.system(size: 17)).textFieldStyle(.plain).focused(focus)
          .padding(.vertical, 11).accessibilityLabel("消息")
        Button(action: submit) {
          Image(systemName: busy ? "stop.fill" : "arrow.up")
            .font(.system(size: busy ? 13 : 18, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 34, height: 34).background(canSend || busy ? Color.ink : Color.gray.opacity(0.3), in: Circle())
            .frame(width: 44, height: 44).contentShape(Rectangle())
        }.disabled(!busy && (!canSend || loadingPhoto)).accessibilityLabel(busy ? "停止回复" : "发送")
      }
      HStack(spacing: 7) {
        Menu {
          if models.isEmpty { Button("重新连接模型", action: reloadModels) }
          ForEach(models) { model in
            Button { chooseModel(model.id) } label: {
              Label(model.name + (model.supports_images ? " · 图文" : " · 文字"), systemImage: selectedModel == model.id ? "checkmark" : "circle")
            }
          }
        } label: {
          HStack(spacing: 5) {
            Text(models.first(where: { $0.id == selectedModel })?.name ?? (modelsLoading ? "连接模型中…" : "连接模型")).lineLimit(1).minimumScaleFactor(0.85)
            Image(systemName: "chevron.down").font(.system(size: 9))
          }.font(.system(size: 12)).foregroundStyle(Color.secondaryInk).frame(minHeight: 30)
        }.disabled(modelsLoading).accessibilityLabel("切换模型")
        Spacer()
        if advanced {
          Menu {
            ForEach(CoachGenerationOptions.efforts, id: \.self) { effort in
              Button { chooseEffort(effort) } label: {
                Label(CoachGenerationOptions(effort: effort).effortTitle, systemImage: generation.effort == effort ? "checkmark" : "circle")
              }
            }
          } label: {
            Text(["none":"快速", "low":"低", "high":"高", "max":"最大"][generation.effort] ?? "快速").font(.system(size: 12)).foregroundStyle(Color.secondaryInk).frame(minWidth: 32, minHeight: 30)
          }.accessibilityLabel("思考强度").accessibilityValue(generation.effortTitle)
          Menu {
            ForEach(CoachGenerationOptions.webModes, id: \.self) { mode in
              Button { chooseWeb(mode) } label: {
                Label(CoachGenerationOptions(webMode: mode).webTitle, systemImage: generation.web_mode == mode ? "checkmark" : "circle")
              }
            }
          } label: {
            HStack(spacing: 3) {
              Image(systemName: "globe")
              if generation.web_mode != "off" { Text(generation.web_mode == "research" ? "研究" : "搜索") }
            }.font(.system(size: 12)).foregroundStyle(Color.secondaryInk).frame(minWidth: 28, minHeight: 30)
          }.disabled(draft.photo != nil).accessibilityLabel("联网与研究模式").accessibilityValue(generation.webTitle)
        }
        if loadingPhoto { SwiftUI.ProgressView().controlSize(.small); Text("读取图片…").font(.system(size: 12)).foregroundStyle(Color.secondaryInk) }
      }.padding(.horizontal, 12).padding(.bottom, 4)
    }.buttonStyle(.plain).padding(6)
      .background(Color.subtle, in: RoundedRectangle(cornerRadius: 26))
      .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Color.hairline, lineWidth: 0.75))
      .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
      .frame(maxWidth: 752).frame(maxWidth: .infinity).background(Color.canvas)
  }
}
