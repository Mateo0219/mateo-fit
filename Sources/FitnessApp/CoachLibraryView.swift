import SwiftUI
import FitnessCore

struct CoachThreadRow: View {
  @EnvironmentObject var store: AppStore
  let thread: CoachThread
  var selected = false
  var open: () -> Void
  var rename: () -> Void
  var archive: () -> Void
  private var pending: Bool {
    if thread.id == store.data.activeCoachThreadID, store.data.pendingHomeMeal != nil { return true }
    if thread.pendingMeal != nil { return true }
    return CoachThreads.turns(store.data, in: thread.id).contains { turn in
      guard let exchange = turn.exchange else { return false }
      return exchange.response.cards.contains { card in card.candidate_id.map { !exchange.appliedIDs.contains($0) } ?? false }
    }
  }
  var body: some View {
    Button(action: open) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: thread.pinned ? "pin" : "bubble.left").font(.system(size: 16)).frame(width: 22).padding(.top, 3)
        VStack(alignment: .leading, spacing: 6) {
          Text(thread.title).font(.system(size: 15, weight: selected ? .semibold : .regular)).lineLimit(2).multilineTextAlignment(.leading)
          HStack(spacing: 6) {
            if pending { Circle().fill(Color.orange).frame(width: 5, height: 5); Text("待核对") }
            else if thread.composer?.text.isEmpty == false || thread.composer?.photo != nil { Text("草稿") }
            else { Text(thread.updatedAt, format: .dateTime.month().day()) }
          }.font(.system(size: 11)).foregroundStyle(Color.secondaryInk)
        }
        Spacer(minLength: 4)
      }.padding(.horizontal, 11).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.mist : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
      .contextMenu {
        Button(thread.pinned ? "取消置顶" : "置顶", systemImage: "pin") { store.pinCoachThread(thread.id) }
        Button("重命名", systemImage: "pencil", action: rename)
        if !thread.archived { Button("归档对话", systemImage: "archivebox", action: archive) }
      }
      .accessibilityHint("长按可重命名、置顶或归档")
  }
}
struct CoachLibraryView: View {
  @EnvironmentObject var store: AppStore
  var newChat: () -> Void
  var select: (UUID) -> Void
  var openModule: (CoachAction) -> Void
  var close: () -> Void
  var archive: (UUID) -> Void
  var openMemory: () -> Void
  @State private var search = ""
  @State private var archived = false
  @State private var renaming: CoachThread?
  @State private var name = ""
  private var threads: [CoachThread] {
    CoachThreads.historyThreads(store.data).filter { thread in
      thread.archived == archived && (search.isEmpty || thread.title.localizedCaseInsensitiveContains(search) || CoachThreads.turns(store.data, in: thread.id).contains { $0.text.localizedCaseInsensitiveContains(search) || $0.reply.localizedCaseInsensitiveContains(search) })
    }.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.updatedAt > $1.updatedAt }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Mateo Fit").font(.system(size: 22, weight: .semibold))
        Spacer()
        Button(action: close) { Image(systemName: "xmark").font(.system(size: 16)).frame(width: 44, height: 44) }.accessibilityLabel("关闭侧栏")
      }.padding(.leading, 20).padding(.trailing, 8).padding(.top, 8)
      HStack(spacing: 9) {
        Image(systemName: "magnifyingglass").foregroundStyle(Color.secondaryInk)
        TextField("搜索对话", text: $search).textFieldStyle(.plain).font(.system(size: 15))
      }.padding(12).background(Color.mist, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16).padding(.vertical, 14)
      Button(action: newChat) { Label("新对话", systemImage: "square.and.pencil").font(.system(size: 16, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Color.mist, in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain).padding(.horizontal, 16)
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(archived ? "已归档" : "最近对话").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryInk)
            Spacer()
            Button(archived ? "返回最近" : "归档") { archived.toggle() }.font(.system(size: 12)).foregroundStyle(Color.secondaryInk)
          }.padding(.vertical, 10)
          ForEach(threads) { thread in
            CoachThreadRow(thread: thread, selected: thread.id == store.data.activeCoachThreadID, open: { select(thread.id) }, rename: { name = thread.title; renaming = thread }, archive: { archive(thread.id) })
          }
          if threads.isEmpty { Text(search.isEmpty ? "这里还没有对话" : "没有找到匹配的对话").font(.system(size: 14)).foregroundStyle(Color.secondaryInk).padding(.vertical, 28) }
          if archived { Text("打开归档对话即可继续，正式记录始终保留。").font(.caption).foregroundStyle(Color.secondaryInk).padding(.top, 12) }
        }.padding(.horizontal, 20).padding(.bottom, 20)
      }.scrollDismissesKeyboard(.interactively)
      Divider()
      Button(action: openMemory) { Label("记忆", systemImage: "brain").font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 12) }.buttonStyle(.plain)
      Button { openModule(.settings) } label: {
        HStack(spacing: 11) {
          Text("M").font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 32).background(Color.mist, in: Circle())
          VStack(alignment: .leading, spacing: 3) { Text("Mateo").font(.system(size: 15, weight: .medium)); Text("设置").font(.system(size: 11)).foregroundStyle(Color.secondaryInk) }
          Spacer(); Image(systemName: "gearshape").font(.system(size: 18))
        }.padding(20)
      }.buttonStyle(.plain)
    }.background(Color.canvas).foregroundStyle(Color.ink)
      .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
        TextField("对话名称", text: $name)
        Button("取消", role: .cancel) { renaming = nil }
        Button("保存") { if let thread = renaming { store.renameCoachThread(thread.id, title: name) }; renaming = nil }
      }
  }
}
