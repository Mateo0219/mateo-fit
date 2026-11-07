import FitnessCore
import SwiftUI

struct AbilityDirectory: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var exercise: ExerciseGuide?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack { Text("动作能力档案").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() } }
        Text("每个动作按具体器械与重量口径单独记录。旧的自由记录保留，但不会自动猜测属于哪台器械。").font(.subheadline).foregroundStyle(Color.secondaryInk)
        ForEach(TrainingLibrary.guides) { guide in
          Button { exercise = guide } label: {
            Surface {
              Text(guide.name).font(.headline)
              let count = store.data.training?.profiles.filter { $0.exerciseID == guide.id }.count ?? 0
              Text(count == 0 ? "建立器械档案，再记录首轮能力" : "\(count) 个器械档案 · 查看表现与建议").font(.caption).foregroundStyle(Color.secondaryInk)
            }
          }.buttonStyle(.plain)
        }
        if let events = store.data.training?.events, !events.isEmpty {
          DisclosureGroup("训练调整历史") {
            ForEach(events.reversed()) { event in
              VStack(alignment: .leading, spacing: 4) {
                Text("v\(event.revision) · \(event.kind)").font(.headline)
                Text(event.reason).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let target = event.after { Text("目标：\(target.kg.map { String(format: "%.1f kg", $0) } ?? "手动校准") · \(target.reps) 次 × \(target.sets) 组 · \(target.evidence.count) 条依据").font(.caption) }
                Text(event.date.formatted()).font(.caption).foregroundStyle(Color.secondaryInk)
              }.padding(.vertical, 10)
            }
          }
        }
      }.padding(24)
    }.frame(minWidth: 340, minHeight: 560).background(Color.canvas)
      .sheet(item: $exercise) { ExerciseSessionSheet(exerciseID: $0.id) }
  }
}
struct ExerciseSessionSheet: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  let exerciseID: String
  @State private var selected: UUID?
  @State private var editing: ExerciseProfile?
  @State private var creating = false
  @State private var reset = false
  @State private var kg = ""
  @State private var reps = ""
  @State private var rir = -1
  @State private var form = "不确定"
  @State private var kind = "工作组"
  private var profiles: [ExerciseProfile] { store.data.training?.profiles.filter { $0.exerciseID == exerciseID } ?? [] }
  private var profile: ExerciseProfile? { profiles.first { $0.id == selected } }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack { Text(TrainingLibrary.guide(exerciseID)?.name ?? exerciseID).font(.title2.bold()); Spacer(); Button("关闭") { dismiss() } }
        if let guide = TrainingLibrary.guide(exerciseID) { Text(guide.cue); Text(guide.avoid).font(.caption).foregroundStyle(Color.secondaryInk) }
        if profiles.isEmpty { Text("先给这台器械起个名字，填写它实际可用的重量。第一次不会从你的体重推算负重。").font(.subheadline) }
        ForEach(profiles) { p in
          Button { selected = p.id; kg = ""; reps = ""; rir = -1; form = "不确定" } label: {
            HStack { Image(systemName: selected == p.id ? "checkmark.circle.fill" : "circle"); Text(p.equipmentLabel + " · " + p.loadConvention + (p.side == "双侧 / 不适用" ? "" : " · " + p.side)); Spacer() }
          }.buttonStyle(.bordered)
        }
        Button("新增这类动作的器械档案") { creating = true }
        if let p = profile {
          Surface {
            HStack { Text("档案常用：\(p.lowerReps)–\(p.upperReps) 次 · \(p.workSets) 组").font(.headline); Spacer(); Button("设置") { editing = p } }
            if store.data.draft?.programID == StrengthProgram.id { Text("今天的组次以当前完整训练计划和下方目标为准。").font(.caption) }
            Text("可用档位：" + p.availableLoads.sorted().map { String(format: "%g", $0) }.joined(separator: " / ") + " kg").font(.caption)
            Text("器械不同或重量口径不同，请新建档案。设置变更后重新积累可比较记录。").font(.caption).foregroundStyle(Color.secondaryInk)
          }
          let proposal = TrainingProgression.proposal(store.data, profileID: p.id)
          Surface {
            Pill(text: proposal.action)
            Text(proposal.reason).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if let target = proposal.target {
              Text("\(target.kg.map { String(format: "%.1f kg", $0) } ?? "负重待你校准") · \(target.reps) 次 × \(target.sets) 组").font(.headline)
              Text("依据 \(target.evidence.count) 条实际组记录 · 本地规则建议").font(.caption).foregroundStyle(Color.secondaryInk)
              if store.data.draft != nil {
                MainButton(title: "采用此目标，再记录实际完成", symbol: "checkmark") {
                  if store.acceptTraining(proposal) {
                    kg = target.kg.map { String($0) } ?? ""; reps = String(target.reps)
                  }
                }
              } else { Text("开始训练后可确认这个目标。查看建议不会生成已完成记录。").font(.caption) }
            }
          }
          if !TrainingWorkload.hasDuplicateExercises(store.data.draft), let target = store.data.draft?.targets?.first(where: { $0.profileID == p.id }) {
            Surface {
              HStack { Text("记录这一组的实际表现").font(.headline); Spacer(); Button("撤回目标") { store.clearTarget(p.id) } }
              Text("当前目标：\(target.kg.map { String(format: "%.1f kg", $0) } ?? "自行校准") × \(target.reps) 次；请按实际结果修改下方数值。").font(.caption)
              Picker("组类型", selection: $kind) { Text("工作组").tag("工作组"); Text("热身组").tag("热身组") }.pickerStyle(.segmented)
              HStack { TextField("实际 kg", text: $kg).entryField(); TextField("实际次数", text: $reps).entryField() }
              Picker("还能标准完成几次？", selection: $rir) { Text("不清楚 / 不记录").tag(-1); ForEach(0...10, id: \.self) { Text("\($0) 次").tag($0) } }
              Picker("动作感受", selection: $form) { ForEach(["不确定", "标准完成", "动作变形", "疼痛"], id: \.self) { Text($0) } }
              Text("不知道余力可留空；疼痛单独记录，出现疼痛应先停止这个动作。自重动作的 0 kg 不包含你的身体体重。").font(.caption).foregroundStyle(Color.secondaryInk)
              MainButton(title: "这组已实际完成，保存", symbol: "checkmark.circle") {
                if store.logTrackedSet(profileID: p.id, kg: Double(kg) ?? -1, reps: Int(reps) ?? 0, rir: rir < 0 ? nil : rir, form: form, kind: kind) { rir = -1; form = "不确定" }
              }
              let progress = TrainingWorkload.targetProgress(target, profile: p, draft: store.data.draft, state: store.data.training)
              Text(progress.summary).font(.caption)
              if let plan = progress.plan { Text("当前动作计划：" + plan.summary).font(.caption) }
              if let prior = progress.priorSummary { Text(prior).font(.caption).foregroundStyle(Color.secondaryInk) }
              Text("休息计时与全部实际组数在训练主页面。").font(.caption)
            }
          }
          Surface {
            Text("已完成训练中的表现").font(.headline)
            let history = TrainingProgression.history(store.data, profileID: p.id)
            if history.isEmpty { Text("还没有可比较的已完成训练。草稿与热身不会触发加重。").font(.subheadline) }
            ForEach(Array(history.prefix(12))) { set in
              VStack(alignment: .leading, spacing: 4) {
                Text("\(set.kg, specifier: "%.1f") kg × \(set.reps) 次 · \(set.setKind ?? "未标注")")
                Text("\(set.date.formatted(date: .abbreviated, time: .shortened)) · 余力 \(set.rir.map(String.init) ?? "未知") · \(set.form ?? "未知")").font(.caption).foregroundStyle(Color.secondaryInk)
              }
            }
            Button("目前无不适，重新校准这个动作…") { reset = true }
          }
        }
      }.padding(24)
    }.frame(minWidth: 340, minHeight: 560).background(Color.canvas)
      .onAppear { selected = profiles.first?.id }
      .onChange(of: profiles.count) { _, _ in selected = profiles.last?.id }
      .sheet(isPresented: $creating) { ExerciseProfileSheet(initial: ExerciseProfile(exerciseID: exerciseID)) }
      .sheet(item: $editing) { ExerciseProfileSheet(initial: $0, existing: true) }
      .alert("确认适合恢复并重新校准？", isPresented: $reset) {
        Button("取消", role: .cancel) {}
        Button("目前无不适，开始重新校准") { if let selected { store.recalibrate(selected) } }
      } message: { Text("这不是医学许可。若仍疼痛或有运动限制，请先寻求专业评估。历史记录保留，旧负重不再作为新基线。") }
  }
}
struct ExerciseProfileSheet: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  let initial: ExerciseProfile
  var existing = false
  @State private var profile = ExerciseProfile(exerciseID: "sit")
  @State private var loads = ""
  @State private var error: String?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack { Text("动作与器械设置").font(.title2.bold()); Spacer(); Button("取消") { dismiss() } }
        Text(initial.name).font(.headline)
        TextField("器械名称，例如公司健身房 2 号推胸机", text: $profile.equipmentLabel).entryField().disabled(existing)
        Picker("重量口径", selection: $profile.loadConvention) { ForEach(["器械标示重量", "单只哑铃", "杠铃总重", "自重（不计体重）"], id: \.self) { Text($0) } }.disabled(existing)
        Picker("侧别", selection: $profile.side) { ForEach(["双侧 / 不适用", "左侧", "右侧"], id: \.self) { Text($0) } }.disabled(existing)
        if profile.loadConvention == "自重（不计体重）" { Text("重量固定记为 0 kg，能力以动作、次数与感受积累。") }
        else {
          TextField("实际可用 kg 档位，用逗号分开", text: $loads, axis: .vertical).entryField()
          Text("按器械实际刻度填写，不要填希望举起的重量；不同器械的标示重量不能直接比较。").font(.caption)
        }
        Stepper("次数下限 \(profile.lowerReps)", value: $profile.lowerReps, in: 5...20)
        Stepper("次数上限 \(profile.upperReps)", value: $profile.upperReps, in: 5...30)
        Stepper("工作组目标 \(profile.workSets) 组", value: $profile.workSets, in: 1...3)
        Text("单侧动作请分别建立左、右档案，不把一侧的能力套到另一侧。默认范围用于恢复训练的本地模板。可以按已确认的教练安排设置；系统不会自动增加组数。双侧哑铃动作请保持固定记法，不混用两侧的重量。").font(.caption).foregroundStyle(Color.secondaryInk)
        if let error { Text(error).foregroundStyle(.red).font(.caption) }
        MainButton(title: "确认并保存档案", symbol: "checkmark") {
          let components = loads.components(separatedBy: CharacterSet(charactersIn: ",， 、\n")).filter { !$0.isEmpty }
          let parsed = components.compactMap(Double.init)
          if profile.loadConvention == "自重（不计体重）" { profile.availableLoads = [0] }
          else {
            guard components.count == parsed.count else { error = "重量档位只能填写数字，用逗号分开。"; return }
            profile.availableLoads = Array(Set(parsed)).sorted()
          }
          guard profile.valid else { error = "请检查名称、重量档位和次数上下限。"; return }
          if store.saveExerciseProfile(profile) { dismiss() }
        }
      }.padding(24)
    }.frame(minWidth: 340, minHeight: 520).background(Color.canvas).onAppear {
      profile = initial; loads = initial.availableLoads.map { String(format: "%g", $0) }.joined(separator: ", ")
      if !existing, store.data.coach?.preferences.programID == StrengthProgram.id,
         let item = (store.data.draft?.planned ?? (0..<3).flatMap { StrengthProgram.session($0, phase: store.data.coach?.preferences.trainingPhase ?? "恢复适应") }).first(where: { $0.exerciseID == initial.exerciseID }) {
        profile.lowerReps = item.lowerReps ?? 8; profile.upperReps = item.upperReps ?? 12; profile.workSets = item.sets
      }
      if !existing && ["sit", "wall", "calf", "bridge", "deadbug"].contains(initial.exerciseID) { profile.loadConvention = "自重（不计体重）" }
    }
  }
}
