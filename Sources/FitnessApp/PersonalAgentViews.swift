import SwiftUI
import FitnessCore

struct PersonalMemoryView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var editing: PersonalMemory?
  @State private var forgetting: PersonalMemory?
  @State private var showExpired = false
  private var memories: [PersonalMemory] { (store.data.personalAgent?.memories ?? []).filter { showExpired || $0.active() }.sorted { $0.updatedAt > $1.updatedAt } }
  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("记忆属于你，新对话和换模型后仍保留。修改记忆不会直接改写正式记录或训练计划。").font(.callout).foregroundStyle(.secondary)
          Toggle("显示已过期记忆", isOn: $showExpired)
        }
        if memories.isEmpty { Text("还没有记忆。直接告诉我你的偏好，例如“以后回答简短点”。").foregroundStyle(.secondary) }
        ForEach(memories) { memory in
          Section {
            Text(memory.content).textSelection(.enabled)
            Text("\(memory.confirmation) · 第 \(memory.revision) 版\(memory.active() ? "" : " · 已过期")").font(.caption).foregroundStyle(.secondary)
            if let expiry = memory.expiresAt { Text("有效至 \(expiry.formatted())").font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("来源与时间") {
              Text(memory.sourceText).font(.callout).textSelection(.enabled)
              Text("记录：\(memory.createdAt.formatted())\n更新：\(memory.updatedAt.formatted())").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
              Button("修改 / 有效期") { editing = memory }
              Spacer()
              Button("忘记", role: .destructive) { forgetting = memory }
            }.buttonStyle(.borderless)
          }
        }
      }.navigationTitle("记忆").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .sheet(item: $editing) { MemoryEditView(memory: $0) }
        .confirmationDialog("忘记这条记忆？历史原文和正式记录保留。", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
          Button("忘记", role: .destructive) {
            if let memory = forgetting {
              var input = AgentOperationInput(kind: "forgetMemory", sourceText: "从记忆管理中忘记这条")
              input.target_id = "memory." + memory.id.uuidString
              _ = store.manageMemory(input, source: input.source_text)
            }
            forgetting = nil
          }
        }
    }.tint(Color.ink)
  }
}
private struct MemoryEditView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let memory: PersonalMemory
  @State private var content = ""
  @State private var limited = false
  @State private var expiry = Date().addingTimeInterval(86400)
  var body: some View {
    NavigationStack {
      Form {
        Section("记忆内容") { TextEditor(text: $content).frame(minHeight: 100) }
        Section("有效期") {
          Toggle("限定有效时间", isOn: $limited)
          if limited { DatePicker("有效至", selection: $expiry, in: Date()..., displayedComponents: [.date, .hourAndMinute]) }
          Text("过期后不再作为当前事实使用。健康限制的变化仍需核对正式档案。").font(.caption).foregroundStyle(.secondary)
        }
      }.navigationTitle("修改记忆").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("保存") {
          var input = AgentOperationInput(kind: "updateMemory", sourceText: content)
          input.target_id = "memory." + memory.id.uuidString; input.content = content
          input.topic = MemoryRules.sensitive(content) ? "health_constraint" : memory.topic == "temporary" && !limited ? "general_preference" : memory.topic
          input.expires_at = limited ? ISO8601DateFormatter().string(from: expiry) : nil
          if store.manageMemory(input, source: "修改记忆：" + content) { dismiss() }
        }.disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.count > 500) }
      }.onAppear { content = memory.content; limited = memory.expiresAt != nil; expiry = max(memory.expiresAt ?? expiry, Date().addingTimeInterval(60)) }
    }.tint(Color.ink)
  }
}

struct AgentOperationCard: View {
  @EnvironmentObject var store: AppStore
  let id: UUID
  @State private var editing = false
  @State private var showingMemory = false
  private var operation: AgentOperation? { store.data.personalAgent?.operations.first { $0.id == id } }
  private var receipt: AgentReceipt? { store.data.personalAgent?.receipts.first { $0.id == id } }
  private var canUndo: Bool { receipt?.undone == false && store.data.personalAgent?.receipts.last(where: { !$0.undone })?.id == id }
  var body: some View {
    if let op = operation {
      if ["remember", "updateMemory"].contains(op.input.kind), op.status == "applied", receipt != nil {
        let current = store.data.personalAgent?.memories.contains { $0.active() && ($0.sourceTurnID == op.turnID || $0.content == op.input.content) } == true
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 14) {
            Label(current ? "已记住" : "记忆已变更", systemImage: "checkmark.circle").font(.system(size: 14))
            Button("查看") { showingMemory = true }
            if canUndo { Button("撤销") { _ = store.undoAgentOperation(id) } }
          }.font(.system(size: 13))
          Text(op.input.content ?? "").font(.system(size: 14)).foregroundStyle(Color.secondaryInk)
        }.sheet(isPresented: $showingMemory) { PersonalMemoryView() }
      } else {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Image(systemName: AgentOperations.scope(op.input.kind) == "memory" ? "brain" : "checklist")
          Text(op.status == "pending" ? "待核对" : op.status == "cancelled" ? "已取消" : op.status == "undone" ? "已撤销" : op.input.kind == "remember" ? "已记住" : op.input.kind == "forgetMemory" ? "已忘记" : "已保存").font(.system(size: 14, weight: .semibold))
          Spacer()
        }
        Text(receipt?.summary ?? op.summary).font(.system(size: 14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        if op.status == "pending" {
          let fresh = AgentOperations.fresh(op, data: store.data)
          HStack(spacing: 20) {
            Button("修改") { editing = true }
            Button("取消", role: .cancel) { store.cancelAgentOperation(id) }
            Spacer()
            Button { _ = store.commitAgentOperation(id) } label: {
              Text(op.input.kind == "remember" ? "记住" : "确认保存").foregroundStyle(Color.white).padding(.horizontal, 14).padding(.vertical, 10).background(fresh ? Color.ink : Color.gray, in: Capsule())
            }.buttonStyle(.plain).disabled(!fresh)
          }.font(.system(size: 13))
          if !fresh { Text("相关记录或条件已更新。请点“修改”重新核对当前内容，再确认。").font(.caption).foregroundStyle(.secondary) }
        } else if op.status == "applied", canUndo {
          Button("撤销") { _ = store.undoAgentOperation(id) }.font(.system(size: 13))
        }
      }.padding(15).background(Color.mist, in: RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $editing) { AgentOperationEditor(operation: op) }
      }
    }
  }
}
struct AgentOperationEditor: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let operation: AgentOperation
  @State private var content = ""
  @State private var exercise = ""
  @State private var kg = ""
  @State private var reps = ""
  @State private var count = ""
  @State private var minutes = ""
  @State private var energy = ""
  @State private var context = ""
  @State private var selectedTarget = ""
  @State private var replacement = ""
  @State private var error: String?
  private var kind: String { operation.input.kind }
  private var targets: [(String, String)] {
    if kind == "correctSet" { return ((store.data.draft?.sets ?? []) + store.data.workouts.flatMap(\.sets)).suffix(100).reversed().map { ("set." + $0.id.uuidString, "\($0.exercise) · \($0.kg) kg × \($0.reps) · \($0.date.formatted(date: .abbreviated, time: .shortened))") } }
    if kind == "correctMeal" { return store.data.meals.suffix(100).reversed().map { ("meal." + $0.id.uuidString, "\($0.title) · \($0.date.formatted(date: .abbreviated, time: .shortened))") } }
    if ["remember", "updateMemory", "forgetMemory"].contains(kind) { return (store.data.personalAgent?.memories ?? []).filter { $0.active() }.map { ("memory." + $0.id.uuidString, $0.content) } }
    if kind == "substituteExercise" { return (store.data.draft?.planned ?? []).map { ("planned." + $0.id.uuidString, TrainingLibrary.guide($0.exerciseID)?.name ?? $0.exerciseID) } }
    return []
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("核对后更新草稿") {
          if !targets.isEmpty { Picker(kind == "remember" ? "保存方式" : "修改哪条", selection: $selectedTarget) {
            if kind == "remember" { Text("新增一条记忆").tag("") }
            ForEach(targets, id: \.0) { Text($0.1).tag($0.0) }
          } }
          if ["remember", "updateMemory", "logMeal", "correctMeal"].contains(kind) { TextEditor(text: $content).frame(minHeight: 90) }
          if kind == "logSet" { TextField("动作", text: $exercise); TextField("实际组数", text: $count) }
          if ["logSet", "correctSet"].contains(kind) { TextField("重量 kg", text: $kg); TextField("次数", text: $reps) }
          if ["updateToday", "finishWorkout"].contains(kind) { TextField("分钟；留空不修改", text: $minutes) }
          if kind == "updateToday" {
            Picker("状态", selection: $energy) { Text("不修改").tag(""); ForEach(["状态正常", "有点疲惫", "不适或困倦"], id: \.self) { Text($0).tag($0) } }
            Picker("地点", selection: $context) { Text("不修改").tag(""); ForEach(["健身房", "在家", "乒乓球", "休息"], id: \.self) { Text($0).tag($0) } }
          }
          if kind == "substituteExercise" {
            Picker("替代动作", selection: $replacement) { ForEach(TrainingLibrary.guides) { Text($0.name).tag($0.id) } }
            Text("保存草稿时会重新检查当前条件，只接受现有规则允许的替代。").font(.caption).foregroundStyle(.secondary)
          }
          if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }
        Section { Text("这里只修改待确认草稿。返回对话核对最新内容，点一次“确认保存”才写入。").font(.caption).foregroundStyle(.secondary) }
      }.navigationTitle("修改操作").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("更新草稿") { save() } }
      }.onAppear {
        let p = operation.input
        content = p.content ?? ""; exercise = p.exercise ?? ""; kg = p.kg.map(String.init(describing:)) ?? ""; reps = p.reps.map(String.init) ?? ""; count = p.count.map(String.init) ?? (kind == "logSet" ? "1" : "")
        minutes = p.minutes.map(String.init) ?? ""; energy = p.energy ?? ""; context = p.context ?? ""; selectedTarget = p.target_id ?? ""; replacement = p.exercise_id ?? ""
      }
    }.tint(Color.ink)
  }
  private func save() {
    guard [kg].allSatisfy({ $0.isEmpty || Double($0)?.isFinite == true }), [reps, count, minutes].allSatisfy({ $0.isEmpty || Int($0) != nil }) else { error = "请填写有效数值。"; return }
    var p = operation.input
    if ["remember", "updateMemory", "logMeal", "correctMeal"].contains(kind) { p.content = content; if MemoryRules.sensitive(content), p.topic != nil { p.topic = "health_constraint" } }
    if kind == "logSet" { p.exercise = exercise; p.count = Int(count) }
    if ["logSet", "correctSet"].contains(kind) { p.kg = Double(kg); p.reps = Int(reps) }
    if ["updateToday", "finishWorkout"].contains(kind) { p.minutes = Int(minutes) }
    if kind == "updateToday" { p.energy = energy.isEmpty ? nil : energy; p.context = context.isEmpty ? nil : context }
    if !selectedTarget.isEmpty {
      p.target_id = selectedTarget
      if kind == "remember" { p.kind = "updateMemory" }
    }
    if kind == "substituteExercise" { p.exercise_id = replacement }
    if store.editAgentOperation(operation.id, input: p) { dismiss() } else { error = store.alert }
  }
}
