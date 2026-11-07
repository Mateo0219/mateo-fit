import FitnessCore
import SwiftUI
import PhotosUI
import Charts

@MainActor final class HomeCoachSession: ObservableObject {
  @Published var busy = false
  @Published var stage = "responding"
  @Published var preview = ""
  var focusComposer = false
  var task: Task<Void, Never>?
  var requestID: UUID?
  func cancel() { task?.cancel(); requestID = nil; busy = false; preview = ""; stage = "responding" }
  func end() { cancel() }
  var stageTitle: String { ["thinking":"正在思考…", "responding":"正在回复…", "searching":"正在搜索…", "reading":"正在阅读来源…", "summarizing":"正在整理结论…"][stage] ?? "正在回复…" }
}
struct HomeDestination: Identifiable {
  let id = UUID()
  let action: CoachAction
  var text = ""
}
struct HomeConfirmation: Identifiable {
  let id: String
  let turnID: UUID
  let title: String
  let detail: String
}
struct CoachHomeView: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var session: HomeCoachSession
  @EnvironmentObject var remote: RemoteCoachCoordinator
  @State private var composerDraft = CoachComposerDraft()
  @AppStorage("coach.includeHealthSummary") private var includeHealthSummary = false
  @AppStorage("coach.includeMemorySummary") private var includeMemorySummary = false
  @State private var supportsPersonalAgent = false
  @State private var advanced = false
  @State private var supportsJobs = false
  @AppStorage("coach.reasoningEffort") private var reasoningEffort = "none"
  @AppStorage("coach.webMode") private var webMode = "off"
  @State private var showingMemory = false
  @Environment(\.scenePhase) private var scenePhase
  private var input: String {
    get { composerDraft.text }
    nonmutating set { composerDraft.text = newValue }
  }
  private var photo: Data? {
    get { composerDraft.photo }
    nonmutating set { composerDraft.photo = newValue }
  }
  @AppStorage("coach.selectedModel") private var selectedModel = ""
  @State private var models: [AgentModel] = []
  @State private var modelsLoading = false
  @State private var copiedTurnID: UUID?
  @State private var loadingPhoto = false
  @State private var photoTask: Task<Void, Never>?
  @State private var visibleTurns = 30
  @State private var followReply = true
  @State private var photoItem: PhotosPickerItem?
  @State private var destination: HomeDestination?
  @State private var message: String?
  @State private var mealChecked = false
  @State private var editMeal = false
  @State private var confirmation: HomeConfirmation?
  @State private var loaded = false
  @State private var moduleFingerprint: String?
  @State private var library = false
  @State private var showPhotoPicker = false
  @FocusState private var inputFocused: Bool
  private var turns: [CoachTurn] { CoachThreads.turns(store.data) }
  private var busy: Bool { session.busy || turns.contains { $0.deliveryState == "sending" } }
  private var thread: CoachThread? { store.data.coachThreads?.first { $0.id == store.data.activeCoachThreadID } }
  private var generation: CoachGenerationOptions { .init(effort: reasoningEffort, webMode: photo == nil ? webMode : "off") }
  var body: some View {
    VStack(spacing: 0) {
      navigationBar
      if turns.isEmpty && store.data.pendingHomeMeal == nil && !busy && message == nil {
        Text("Mateo Fit").font(.system(size: 32, weight: .medium)).tracking(-0.6)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else { conversation }
    }.safeAreaInset(edge: .bottom, spacing: 0) {
      CoachComposerView(draft: composerDraft, busy: busy, loadingPhoto: loadingPhoto, models: models, modelsLoading: modelsLoading, reloadModels: { Task { await loadModels() } }, selectedModel: selectedModel, chooseModel: { selectedModel = $0 }, advanced: advanced, generation: generation, chooseEffort: { reasoningEffort = $0 }, chooseWeb: { webMode = $0; if $0 == "research" && reasoningEffort == "none" { reasoningEffort = "high" } }, focus: $inputFocused,
        attach: { inputFocused = false; showPhotoPicker = true },
        removePhoto: { photo = nil; photoItem = nil },
        submit: { if busy { stopRequest() } else { send() } })
    }
      .background(Color.canvas)
      .overlay { if library { libraryOverlay } }
      .sheet(item: $destination, onDismiss: moduleReturned) { HomeModuleSheet(destination: $0) }
      .sheet(isPresented: $editMeal) { if let draft = store.data.pendingHomeMeal { HomeMealEditor(draft: draft) } }
      .sheet(isPresented: $showingMemory) { PersonalMemoryView() }
      .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
      .alert(item: $confirmation) { item in
        Alert(title: Text(item.title), message: Text(item.detail), primaryButton: .default(Text("确认采用")) { _ = store.confirmAssistant(turnID: item.turnID, candidateID: item.id) }, secondaryButton: .cancel(Text("取消")))
      }
      .onAppear {
        if !loaded {
          let owner = store.data.activeCoachThreadID ?? CoachThreads.legacyID
          let ownerStore = store
          composerDraft.restore(store.data.homeComposer) { [weak ownerStore] text, photo, state in
            guard let ownerStore, (ownerStore.data.activeCoachThreadID ?? CoachThreads.legacyID) == owner else { return false }
            return ownerStore.saveComposer(text: text, photo: photo, state: state)
          }
          if ["sending", "interrupted"].contains(store.data.homeComposer?.state ?? "") { message = "上次请求未完成，输入已恢复，可以手动重试。" }
          loaded = true
          if session.focusComposer { inputFocused = true; session.focusComposer = false }
        }
      }
      .task { await loadModels() }
      .onChange(of: photoItem) { _, item in
        photoTask?.cancel()
        guard let item else { loadingPhoto = false; return }
        loadingPhoto = true
        photoTask = Task { @MainActor in
          defer { if item == photoItem { loadingPhoto = false } }
          do {
            guard let bytes = try await item.loadTransferable(type: Data.self), !Task.isCancelled, item == photoItem else { return }
            guard bytes.count <= 20_000_000 else { message = "请使用 20 MB 以内的餐食图片。"; return }
            photo = bytes
          } catch { if !Task.isCancelled { message = "照片未读取，请重新选择。" } }
        }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active { persist() }
        if phase == .background { stopLegacyRequest() }
        if phase == .active && models.isEmpty { Task { await loadModels() } }
      }
      .onChange(of: includeHealthSummary) { _, allowed in if !allowed { stopLegacyRequest(); remote.reconcile(store) } }
      .onChange(of: includeMemorySummary) { _, allowed in if !allowed { stopLegacyRequest(); remote.reconcile(store) } }
      .onDisappear { persist(); composerDraft.cancelPendingSave(); photoTask?.cancel(); if session.busy { stopLegacyRequest() } }
  }
  private var conversation: some View {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 28) {
            if turns.count > visibleTurns { Button("查看更早的消息") { followReply = false; visibleTurns += 30 }.font(.system(size: 13)).frame(maxWidth: .infinity) }
            ForEach(turns.suffix(visibleTurns)) { turn in conversationTurn(turn).id(turn.id) }
            if let draft = store.data.pendingHomeMeal { mealCard(draft) }
            if let message {
              HStack(alignment: .top, spacing: 8) { Image(systemName: "info.circle"); Text(message).fixedSize(horizontal: false, vertical: true) }
                .font(.system(size: 13)).foregroundStyle(Color.secondaryInk).padding(14).background(Color.mist, in: RoundedRectangle(cornerRadius: 12))
            }
            Color.clear.frame(height: 1).id("conversation-bottom")
          }.padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 18).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.scrollDismissesKeyboard(.interactively)
          .simultaneousGesture(DragGesture().onChanged { _ in followReply = false })
          .defaultScrollAnchor(turns.isEmpty && store.data.pendingHomeMeal == nil ? .top : .bottom)
          .onChange(of: turns.count) { _, _ in withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) } }
          .onChange(of: session.busy) { _, _ in if followReply { withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) } } }
          .onChange(of: session.preview) { _, _ in if followReply { proxy.scrollTo("conversation-bottom", anchor: .bottom) } }
          .onChange(of: store.data.pendingHomeMeal?.id) { _, _ in mealChecked = false; withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) } }
      }
  }
  private var navigationBar: some View {
    HStack(spacing: 4) {
      Button { inputFocused = false; withAnimation(.easeInOut(duration: 0.2)) { library = true } } label: {
        Image(systemName: "line.3.horizontal.decrease").font(.system(size: 21, weight: .regular)).frame(width: 44, height: 44)
      }.accessibilityLabel("历史对话")
      Spacer(minLength: 4)
      if !turns.isEmpty {
        Button { withAnimation { library = true } } label: {
          HStack(spacing: 6) { Text(thread?.title ?? "Mateo Fit").font(.system(size: 15, weight: .semibold)).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 10)) }
        }.buttonStyle(.plain).accessibilityLabel("切换对话")
      }
      Spacer(minLength: 4)
      Menu {
        Toggle("不形成长期记忆", isOn: Binding(get: { thread?.noLongTermMemory == true }, set: { value in stopRequest(); store.setNoLongTermMemory(value) }))
        Button("查看记忆") { showingMemory = true }
      } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("会话选项")
      Button { newChat() } label: { Image(systemName: "square.and.pencil").font(.system(size: 20)).frame(width: 44, height: 44) }.accessibilityLabel("新对话")

    }.buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 5).background(Color.canvas)
  }
  private var libraryOverlay: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Color.black.opacity(0.22).ignoresSafeArea().onTapGesture { withAnimation { library = false } }
        CoachLibraryView(newChat: newChat, select: selectThread, openModule: { action in library = false; open(action) }, close: { withAnimation { library = false } }, archive: archive, openMemory: { library = false; showingMemory = true })
          .frame(width: min(340, geometry.size.width - 32)).frame(maxHeight: .infinity)
          .background(Color.canvas.ignoresSafeArea()).shadow(color: .black.opacity(0.08), radius: 18, x: 6)
          .transition(.move(edge: .leading))
      }
    }
  }
  @ViewBuilder private func conversationTurn(_ turn: CoachTurn) -> some View {
    VStack(alignment: .leading, spacing: 17) {
      if let photo = turn.photo {
        HStack { Spacer(minLength: 40); LocalPhoto(bytes: photo).equatable().frame(width: 160, height: 160).clipped().clipShape(RoundedRectangle(cornerRadius: 16)) }
      }
      HStack {
        Spacer(minLength: 40)
        Text(turn.text).font(.system(size: 16)).lineSpacing(4).padding(.horizontal, 17).padding(.vertical, 13)
          .background(Color.mist, in: RoundedRectangle(cornerRadius: 22)).textSelection(.enabled)
      }.padding(.top, 8).padding(.bottom, 7)
      if let state = turn.deliveryState {
        HStack(spacing: 8) {
          if state == "sending" { SwiftUI.ProgressView().controlSize(.small); Text(turn.remoteJob.map { remote.progress[$0.id]?.title ?? ($0.accepted ? "服务器处理中…" : "正在连接…") } ?? (session.requestID == turn.attemptID ? session.stageTitle : "正在回复…")) }
          else {
            Text(state == "stopped" ? "已停止" : "发送失败")
            Button("重试") { retry(turn) }.disabled(busy)
            Button("编辑") { editMessage(turn) }
          }
        }.font(.system(size: 13)).foregroundStyle(Color.secondaryInk)
        if state == "sending", let job = turn.remoteJob, let preview = remote.progress[job.id]?.preview, !preview.isEmpty {
          Text(.init(preview)).font(.system(size: 16)).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
        }
        if state == "sending", session.requestID == turn.attemptID, !session.preview.isEmpty {
          Text(.init(session.preview)).font(.system(size: 16)).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
        }
        if state == "sending", let job = turn.remoteJob, remote.progress[job.id]?.title.contains("连接暂不可用") == true {
          Button("重新连接") { remote.resume(store) }.font(.system(size: 12))
        }
        if let model = turn.model { Text(models.first(where: { $0.id == model })?.name ?? model).font(.system(size: 11)).foregroundStyle(Color.secondaryInk) }
        if let error = turn.deliveryError { Text(error).font(.system(size: 12)).foregroundStyle(Color.secondaryInk) }
      } else {
      if !CoachReplyText.body(turn).isEmpty {
        Text(.init(CoachReplyText.body(turn))).font(.system(size: 16)).lineSpacing(6).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      ForEach(turn.agentOperationIDs ?? [], id: \.self) { AgentOperationCard(id: $0) }
      if let exchange = turn.exchange {
        ForEach(CoachReplyText.questions(turn), id: \.self) { Text($0).font(.system(size: 16, weight: .medium)).lineSpacing(4) }
        ForEach(CoachReplyText.cards(turn)) { card in responseCard(card, turn: turn, exchange: exchange) }
        if !(exchange.response.sources ?? []).isEmpty {
          DisclosureGroup("来源（\(exchange.response.sources?.count ?? 0)）") {
            ForEach(exchange.response.sources ?? []) { source in
              if let url = URL(string: source.url) { Link("\(source.id) · \(source.title)", destination: url).font(.system(size: 13)).padding(.vertical, 5) }
            }
          }.font(.system(size: 13)).foregroundStyle(Color.secondaryInk)
        }
      }
      if let outcome = turn.outcome, (turn.agentOperationIDs ?? []).isEmpty { Label(outcome, systemImage: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color.success) }
      HStack(spacing: 16) {
        Button { copyReply(turn) } label: { Image(systemName: copiedTurnID == turn.id ? "checkmark" : "doc.on.doc").frame(width: 44, height: 44) }.accessibilityLabel(copiedTurnID == turn.id ? "已复制" : "复制回复")
        Button { editMessage(turn) } label: { Image(systemName: "square.and.pencil").frame(width: 44, height: 44) }.accessibilityLabel("编辑问题后再次发送")
        if let usage = turn.exchange?.response.generation {
          Menu {
            Text(CoachGenerationOptions(effort: usage.effort, webMode: usage.web_mode).effortTitle)
            Text("模型调用 \(usage.model_calls) · 搜索 \(usage.search_calls) · 阅读 \(usage.fetch_calls)")
            Text("输入 \(usage.prompt_tokens.map(String.init) ?? "未提供") · 输出 \(usage.completion_tokens.map(String.init) ?? "未提供") tokens")
            Text("缓存命中 \(usage.cache_hit_tokens.map(String.init) ?? "未提供") · 思考 \(usage.reasoning_tokens.map(String.init) ?? "未提供") tokens")
          } label: { Image(systemName: "info.circle").frame(width: 32, height: 44) }.accessibilityLabel("本次调用详情")
        }
        Spacer()
        if let model = turn.model { Text(models.first(where: { $0.id == model })?.name ?? model).font(.system(size: 10)).lineLimit(1) }
        Text(turn.date, format: .dateTime.hour().minute()).font(.system(size: 11))
      }.font(.system(size: 14)).foregroundStyle(Color.secondaryInk).buttonStyle(.plain)
      }
    }
  }
  private func responseCard(_ card: CoachResponseCard, turn: CoachTurn, exchange: CoachExchange) -> some View {
    let fresh = AssistantContext.isFresh(exchange, data: store.data)
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: card.action.symbol).font(.system(size: 17)).frame(width: 23)
        Text(card.title).font(.system(size: 15, weight: .semibold))
        Spacer(minLength: 0)
        if let id = card.candidate_id { Text(exchange.appliedIDs.contains(id) ? "已采用" : "待确认").font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 4).background(Color.mist, in: Capsule()) }
      }
      Text(card.detail).font(.system(size: 14)).lineSpacing(4).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
      if let id = card.candidate_id, let candidate = exchange.snapshot.candidates.first(where: { $0.id == id }) {
        Text(candidate.detail).font(.system(size: 13)).lineSpacing(3)
        if exchange.appliedIDs.contains(id) { Label("已确认采用", systemImage: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color.success) }
        else {
          Button { confirmation = .init(id: id, turnID: turn.id, title: candidate.title, detail: candidate.detail) } label: {
            HStack { Text("核对并确认采用"); Spacer(); Image(systemName: "arrow.right") }.font(.system(size: 14, weight: .medium)).padding(13).background(fresh ? Color.ink : Color.mist, in: RoundedRectangle(cornerRadius: 11)).foregroundStyle(fresh ? Color.white : Color.secondaryInk)
          }.buttonStyle(.plain).disabled(!fresh)
          if !fresh { Text("记录已更新，请让教练重新评估。").font(.system(size: 12)).foregroundStyle(Color.secondaryInk) }
        }
      }
      if !card.evidence_ids.isEmpty {
        DisclosureGroup("依据与覆盖范围") {
          ForEach(exchange.snapshot.facts.filter { card.evidence_ids.contains($0.id) }) { fact in
            VStack(alignment: .leading, spacing: 4) {
              Text(fact.summary).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
              Text("\(fact.quality) · \(fact.observed_at ?? "时间未知")").font(.system(size: 10)).foregroundStyle(Color.secondaryInk)
            }.padding(.vertical, 5)
          }
        }.font(.system(size: 12)).foregroundStyle(Color.secondaryInk)
      }
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.canvas, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.hairline, lineWidth: 1))
  }
  private func mealCard(_ draft: HomeMealDraft) -> some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack { Label("餐食记录", systemImage: "fork.knife").font(.system(size: 15, weight: .semibold)); Spacer(); Text("待你确认").font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 5).background(Color.mist, in: Capsule()) }
      HStack(alignment: .top, spacing: 12) {
        if let photo = draft.photo { LocalPhoto(bytes: photo).frame(width: 80, height: 80).clipped().clipShape(RoundedRectangle(cornerRadius: 12)) }
        VStack(alignment: .leading, spacing: 6) {
          Text(draft.title.isEmpty ? "补充食物和份量" : draft.title).font(.system(size: 16, weight: .medium))
          Text(draft.description).font(.system(size: 13)).foregroundStyle(Color.secondaryInk).lineLimit(3)
          Text(draft.date, format: .dateTime.month().day().hour().minute()).font(.system(size: 11)).foregroundStyle(Color.secondaryInk)
        }
      }
      if let result = draft.result { DisclosureGroup("识别结果与估计依据") { MealAnalysisPreview(result: result).padding(.top, 10) }.font(.system(size: 13)) }
      else { Text("营养数据尚未确认，未知项目不会按零计算。").font(.system(size: 12)).foregroundStyle(Color.secondaryInk) }
      Button { mealChecked = false; editMeal = true } label: { HStack { Text("修改份量、时间或营养数据"); Spacer(); Image(systemName: "pencil") }.font(.system(size: 14)).padding(.vertical, 7) }.buttonStyle(.plain)
      MainButton(title: "确认实际吃过并保存", symbol: "checkmark") { if store.confirmHomeMeal(draft) { mealChecked = false } }.disabled(draft.title.isEmpty)
      Button("放弃这份草稿", role: .destructive) { if store.discardHomeMeal(id: draft.id) { mealChecked = false } }.font(.system(size: 12))
    }.padding(17).background(Color.canvas, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.hairline, lineWidth: 1))
  }
  private func stopRequest() {
    if let job = turns.first(where: { $0.remoteJob != nil })?.remoteJob { remote.cancel(job.id, store: store) }
    stopLegacyRequest()
  }
  private func stopLegacyRequest() {
    if let attempt = session.requestID { _ = store.stopCoachRequest(attemptID: attempt) }
    session.cancel()
  }
  private func newChat() {
    persist(); stopLegacyRequest()
    session.end(); session.focusComposer = true
    if store.newCoachThread() { library = false; inputFocused = true }
  }
  private func selectThread(_ id: UUID) {
    persist(); stopLegacyRequest()
    session.end(); inputFocused = false
    _ = store.selectCoachThread(id); library = false
  }
  private func archive(_ id: UUID) {
    if id == store.data.activeCoachThreadID { persist(); stopLegacyRequest(); session.end() }
    store.archiveCoachThread(id)
  }
  private func copyReply(_ turn: CoachTurn) {
    let text = CoachReplyText.copy(turn, data: store.data)
    #if os(iOS)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    #endif
    copiedTurnID = turn.id
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      if copiedTurnID == turn.id { copiedTurnID = nil }
    }
  }
  private func loadModels() async {
    guard !modelsLoading, let transport = AgentConnection.load().transport else { return }
    modelsLoading = true
    defer { modelsLoading = false }
    do {
      let status = try await transport.status()
      supportsPersonalAgent = status.assistant_contract_versions?.contains(2) == true
      advanced = status.assistant_features?.streaming == true
      supportsJobs = status.assistant_features?.background_jobs == true
      if !advanced { reasoningEffort = "none"; webMode = "off" }
      try Task.checkCancellation()
      models = status.models ?? (status.model.isEmpty ? [] : [.init(id: status.model, name: status.model, supportsImages: status.model == "deepseek-flash")])
      if !models.contains(where: { $0.id == selectedModel }) { selectedModel = status.model }
    } catch { /* The model menu offers a manual reconnect; keep all input. */ }
  }
  private func persist(state: String = "editing") { _ = composerDraft.flush(state: state) }
  private func open(_ action: CoachAction, text: String = "") {
    persist(); inputFocused = false; moduleFingerprint = AssistantContext.fingerprint(store.data); destination = .init(action: action, text: text)
  }
  private func moduleReturned() {
    if let before = moduleFingerprint, before != AssistantContext.fingerprint(store.data) {
      var turn = CoachTurn(text: "完成模块操作", reply: "本机记录或设置已更新。下一次回复会重新读取已授权的最新摘要。", actions: [.records], origin: "本机确认结果")
      turn.outcome = "已检测到本机数据更新；具体事实以最新摘要为准。"
      _ = store.addConversation(turn)
    }
    moduleFingerprint = nil
  }
  private func editMessage(_ turn: CoachTurn) {
    guard input.isEmpty && photo == nil else { message = "输入框已有草稿，请先发送或清空。"; return }
    input = turn.text; photo = turn.photo; inputFocused = true
  }
  private func modelForSend(photo: Data?) -> String? {
    guard let model = models.first(where: { $0.id == selectedModel }) else { message = "模型列表尚未连接，请稍后重试或检查设置。"; return nil }
    guard photo == nil || model.supports_images else { message = "这个模型仅支持文字，请切换 DeepSeek Flash 后发送图片。"; return nil }
    return model.id
  }
  private func send() {
    guard !busy, !loadingPhoto else { return }
    guard input.count <= 3000 else { message = "本次输入请控制在 3000 字以内。"; return }
    guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil else { return }
    guard photo == nil || store.data.pendingHomeMeal == nil else { message = "请先保存或放弃当前餐食草稿。"; return }
    let localText = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if photo == nil, store.handlesLocalAgentText(localText) {
      if composerDraft.submit(accept: { text, _ in store.submitLocalAgentText(text.trimmingCharacters(in: .whitespacesAndNewlines)) }) { message = nil; followReply = true; inputFocused = true }
      return
    }
    guard photo != nil || supportsPersonalAgent else { message = "当前服务尚未支持记忆与聊天操作，请在模型菜单重新连接；本地记忆和记录仍可使用。"; return }
    guard let transport = AgentConnection.load().transport else { message = "暂未连接教练，请在侧栏的设置中检查连接。"; return }
    guard let model = modelForSend(photo: photo) else { return }
    let attempt = UUID()
    var submitted: CoachTurn?
    guard composerDraft.submit(accept: { text, photo in
      var turn = CoachTurn(text: text.isEmpty ? "餐食照片" : text, reply: "", actions: [], origin: "AI 教练")
      turn.photo = photo; turn.model = model; turn.attemptID = attempt; turn.deliveryState = "sending"
      turn.generation = advanced ? generation : nil
      if supportsJobs {
        do { turn.remoteJob = try prepareRemote(turn, attempt: attempt, transport: transport) }
        catch { message = "本次任务未能准备，输入已保留。"; return false }
      }
      guard store.beginCoachRequest(turn) else { return false }
      submitted = CoachThreads.turns(store.data).last
      return true
    }), let turn = submitted else { return }
    photoItem = nil; message = nil; inputFocused = true; followReply = true
    run(turn, attempt: attempt, transport: transport)
  }
  private func retry(_ turn: CoachTurn) {
    guard !busy else { return }
    guard let transport = AgentConnection.load().transport else { message = "暂未连接教练，请在侧栏设置中检查连接。"; return }
    guard let model = modelForSend(photo: turn.photo) else { return }
    let attempt = UUID()
    var requested = turn; requested.model = model
    let job: CoachRemoteJob?
    do { job = supportsJobs ? try prepareRemote(requested, attempt: attempt, transport: transport) : nil }
    catch { message = "本次任务未能准备，原消息已保留。"; return }
    guard store.retryCoachRequest(turnID: turn.id, attemptID: attempt, model: model, remoteJob: job),
      let retried = store.data.conversation?.first(where: { $0.id == turn.id }) else { return }
    message = nil; followReply = true
    run(retried, attempt: attempt, transport: transport)
  }
  private func prepareRemote(_ turn: CoachTurn, attempt: UUID, transport: MealAgentTransport) throws -> CoachRemoteJob {
    let bundle = turn.photo == nil ? PersonalAgentContext.build(store.data, text: turn.text, health: includeHealthSummary, memory: includeMemorySummary) : nil
    let history = turn.photo == nil ? PersonalAgentContext.history(store.data, text: turn.text, health: includeHealthSummary, memory: includeMemorySummary) : []
    return try transport.prepareJob(id: attempt, threadID: store.data.activeCoachThreadID ?? CoachThreads.legacyID, deviceID: RemoteCoachCoordinator.deviceID, text: turn.text, jpeg: turn.photo == nil ? nil : mealUploadJPEG(turn.photo!), bundle: bundle, history: history, health: includeHealthSummary, memory: includeMemorySummary, learning: thread?.noLongTermMemory != true, model: turn.model!, generation: turn.generation ?? .init())
  }
  private func run(_ turn: CoachTurn, attempt: UUID, transport: MealAgentTransport) {
    if turn.remoteJob != nil { remote.resume(store); return }
    message = "当前服务尚未提供后台任务，本次回复需要保持 App 在前台。"

    let summary = includeHealthSummary, memory = includeMemorySummary, learning = thread?.noLongTermMemory != true, selectedModel = turn.model
    session.requestID = attempt; session.busy = true; session.preview = ""; session.stage = "responding"
    session.task = Task { @MainActor in
      defer { if session.requestID == attempt { session.busy = false; session.requestID = nil; session.preview = "" } }
      let update: @MainActor (CoachStreamUpdate) -> Void = { event in
        guard session.requestID == attempt else { return }
        switch event { case .status(let stage): session.stage = stage; case .message(let value): session.preview = value }
      }
      do {
        await Task.yield()
        try Task.checkCancellation()
        if let photo = turn.photo {
          let result: MealAgentResult
          if advanced, let settings = turn.generation, let selectedModel {
            result = try await transport.analyzeStream(id: attempt.uuidString, description: turn.text, jpeg: mealUploadJPEG(photo), consent: true, model: selectedModel, generation: settings, onUpdate: update)
          } else { result = try await transport.analyze(id: attempt.uuidString, description: turn.text, jpeg: mealUploadJPEG(photo), consent: true, model: selectedModel) }
          try Task.checkCancellation(); guard session.requestID == attempt else { return }
          if !store.finishCoachMeal(turnID: turn.id, attemptID: attempt, result: result) { _ = store.stopCoachRequest(attemptID: attempt, error: "结果未保存，请处理已有餐食草稿后重试。") }
          mealChecked = false
        } else {
          let bundle = PersonalAgentContext.build(store.data, text: turn.text, health: summary, memory: memory)
          let history = PersonalAgentContext.history(store.data, text: turn.text, health: summary, memory: memory)
          let reply: CoachAssistantResponse
          if advanced, let settings = turn.generation, let selectedModel {
            reply = try await transport.respondStream(id: attempt.uuidString, text: turn.text, history: history, snapshot: bundle.snapshot, health: summary, memory: memory, learning: learning, model: selectedModel, generation: settings, onUpdate: update)
          } else { reply = try await transport.respondV2(id: attempt.uuidString, text: turn.text, history: history, snapshot: bundle.snapshot, health: summary, memory: memory, learning: learning, model: selectedModel) }
          try Task.checkCancellation(); guard session.requestID == attempt else { return }
          if !store.finishPersonalRequest(turnID: turn.id, attemptID: attempt, bundle: bundle, response: reply) { _ = store.stopCoachRequest(attemptID: attempt, error: store.alert ?? "回复未能保存，请重试。") }
        }
      } catch {
        guard session.requestID == attempt, !Task.isCancelled else { return }
        _ = store.stopCoachRequest(attemptID: attempt, error: (error as? CoachStreamError)?.localizedDescription ?? (error as? MealAgentError)?.localizedDescription ?? "暂时未收到回复，请重试。")
      }
    }
  }

}

struct HomeModuleSheet: View {
  let destination: HomeDestination
  @Environment(\.dismiss) var dismiss
  @State private var active: CoachAction?
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button { dismiss() } label: { Image(systemName: "chevron.left").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44) }.accessibilityLabel("返回对话")
        Spacer()
        Text((active ?? destination.action).title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
        Spacer()
        Color.clear.frame(width: 44, height: 44)
      }.buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 6).background(Color.canvas)
      Divider().overlay(Color.hairline)
      content
    }.background(Color.canvas).foregroundStyle(Color.ink).frame(minWidth: 340, minHeight: 500)
  }
  @ViewBuilder private var content: some View {
    let action = active ?? destination.action
    if action == .meal { MealLogSheet(prefill: destination.text.isEmpty ? nil : MealEntry(title: destination.text, note: "来自首页输入，尚未确认吃过", confirmed: false)) }
    else if action == .adjustToday { CheckInSheet(suggestedMinutes: HomeCoach.minutes(in: destination.text)) }
    else if action == .recordWeight { WeightEntrySheet(initialText: destination.text) }
    else {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          switch action {
          case .daily: TodayView(selection: Binding(get: { 0 }, set: { active = $0 == 2 ? .training : $0 == 1 ? .foodIdeas : .weight }))
          case .training: TrainingView()
          case .foodIdeas: FoodView()
          case .weight: ProgressViewScreen()
          case .sleep: ProgressViewScreen(initialSection: 1)
          case .forecast: WeightForecastCard()
          case .review: WeeklyReviewCard(); WeightForecastCard()
          case .records: ModuleRecordsView()
          case .settings: SettingsView()
          default: EmptyView()
          }
        }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
      }
    }
  }
}
struct ModuleRecordsView: View {
  @EnvironmentObject var store: AppStore
  @State private var section = 0
  @State private var manage = false
  @State private var mealLog = false
  var body: some View {
    Text("记录各自归档，教练统一调用").font(.title2.bold())
    Picker("记录模块", selection: $section) { Text("饮食").tag(0); Text("训练").tag(1); Text("身体").tag(2) }.pickerStyle(.segmented)
    if section == 0 {
      FoodDiaryCard(onLog: { mealLog = true }, onEdit: { manage = true })
      ForEach(store.data.meals.sorted { $0.date > $1.date }.prefix(30)) { meal in Surface { Text(meal.title).font(.headline); Text(meal.date.formatted()).font(.caption); Text(meal.nutrition?.source ?? "营养未知").font(.caption) } }
    } else if section == 1 {
      ForEach(store.data.workouts.sorted { $0.date > $1.date }.prefix(30)) { workout in Surface { Text(workout.name).font(.headline); Text("\(workout.minutes) 分钟 · \(workout.sets.count) 组"); Text(workout.date.formatted()).font(.caption) } }
      if store.data.workouts.isEmpty { Text("还没有已保存训练，计划不会当成完成记录。") }
    } else { ProgressViewScreen() }
    Button("编辑、移除或恢复记录") { manage = true }.sheet(isPresented: $manage) { RecordManager() }.sheet(isPresented: $mealLog) { MealLogSheet() }
  }
}
struct WeightEntrySheet: View {
  var initialText = ""
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var value = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("记录今天实际测量的体重").font(.title2.bold())
      Text("目标体重、预测数字不计入测量记录。").font(.subheadline)
      TextField("kg", text: $value).entryField()
      MainButton(title: "确认测量并保存", symbol: "checkmark") { if store.addWeight(Double(value) ?? .nan) { dismiss() } }
    }.padding(24).onAppear {
      let pattern = try! NSRegularExpression(pattern: "(?<![0-9.])([0-9]{2,3}(?:\\.[0-9]{1,2})?)\\s*(kg|公斤|千克|斤)", options: [.caseInsensitive])
      let matches = pattern.matches(in: initialText, range: NSRange(initialText.startIndex..., in: initialText))
      if matches.count == 1, let r = Range(matches[0].range(at: 1), in: initialText), let u = Range(matches[0].range(at: 2), in: initialText), let raw = Double(initialText[r]) {
        let kg = String(initialText[u]) == "斤" ? raw / 2 : raw
        if DataMath.validWeight(kg) { value = String(format: "%.2f", kg) }
      }
    }
  }
}
struct WeightForecastCard: View {
  @EnvironmentObject var store: AppStore
  private var projection: WeightProjection { WeightProjector.project(store.data.weights) }
  var body: some View {
    Surface {
      Label("预计体重 · 短期趋势外推", systemImage: "chart.xyaxis.line").font(.headline)
      Text(projection.message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
      if !projection.points.isEmpty {
        Chart {
          ForEach(projection.measured) { entry in LineMark(x: .value("日期", entry.date), y: .value("实测", entry.kg), series: .value("类型", "实测")).foregroundStyle(Color.pine) }
          ForEach(projection.points) { point in
            AreaMark(x: .value("日期", point.date), yStart: .value("下界", point.low), yEnd: .value("上界", point.high)).foregroundStyle(Color.pine.opacity(0.12))
            LineMark(x: .value("日期", point.date), y: .value("外推", point.kg), series: .value("类型", "外推")).lineStyle(StrokeStyle(lineWidth: 2, dash: [4,4])).foregroundStyle(Color.secondaryInk)
          }
        }.chartYScale(domain: chartDomain).frame(height: 180)
        ForEach(projection.points) { point in
          HStack { Text("\(point.days) 天后"); Spacer(); Text("\(point.low, specifier: "%.1f")–\(point.high, specifier: "%.1f") kg").bold() }
        }
        Text("基于近 30 天 \(projection.measured.count) 个测量日，同一数据来源。未来饮食、活动、水分和测量条件变化都会让外推偏离。实线为实测、虚线为外推。").font(.caption).foregroundStyle(Color.secondaryInk)
      }
      Text("这不是目标值，不会据此自动减餐或增加训练。").font(.caption).foregroundStyle(Color.secondaryInk)
    }
  }
  private var chartDomain: ClosedRange<Double> {
    let values=projection.measured.map(\.kg)+projection.points.flatMap { [$0.low,$0.high] }
    return ((values.min() ?? 0)-0.5)...((values.max() ?? 1)+0.5)
  }
}

struct HomeHealthSummary: View {
  @EnvironmentObject var store: AppStore
  let actions: [CoachAction]
  var body: some View {
    Surface {
      Text("来自你的本机记录").font(.headline)
      if actions.contains(.weight) || actions.contains(.daily) {
        let report = HealthAnalytics.weight(store.data.weights, days: 30)
        if let latest = report.latest {
          Text("最近测量 \(latest.kg, specifier: "%.1f") kg").font(.title3.bold())
          Text(latest.date.formatted(date: .abbreviated, time: .shortened) + " · " + latest.source).font(.caption)
          if let change = report.weekChange { Text("近两周测量均值变化 \(change, specifier: "%+.1f") kg").font(.subheadline) }
          else { Text("两周均值对比尚缺足够测量日，不根据单次升降改计划。").font(.caption) }
        } else { Text("暂无真实称重；起始档案不会算作今日测量。") }
      }
      if actions.contains(.sleep) || actions.contains(.daily) {
        if let last = HealthAnalytics.sleep(store.data.sleep, days: 7).last {
          Text("最近已记录睡眠 \(last.sleepSeconds / 3600, specifier: "%.1f") 小时").font(.title3.bold())
          Text(last.day.formatted(date: .abbreviated, time: .omitted) + " · " + last.source).font(.caption)
          Text("清醒不计入睡眠，分期不作为医学诊断。详情中可查看时间轴与来源。").font(.caption)
        } else { Text("最近 7 天暂无可用睡眠记录，不能按没睡计算。") }
      }
      Text("显示当前可用数据，未上传给模型。").font(.caption).foregroundStyle(Color.secondaryInk)
    }
  }
}
