import FitnessCore
import SwiftUI

struct TrainingView: View {
  @EnvironmentObject var store: AppStore
  @State private var ready = false
  @State private var directory = false
  @State private var selectedGuide: ExerciseGuide?
  @State private var sport = false
  @State private var cancelDraft = false
  @State private var confirmDuration = false
  @State private var name = "健身房训练"
  @State private var exercise = ""
  @State private var kg = ""
  @State private var reps = ""
  @State private var effort = "适中"
  var body: some View {
    TrainingPlanCard()
    Surface {
      HStack { Text("动作能力与递进").font(.headline); Spacer(); Button("动作能力档案") { directory = true } }
      Text("全身 A → B → C：当前等待 \(["A", "B", "C"][(store.data.training?.sequenceIndex ?? 0) % 3])。完成计划工作组后推进；漏练按顺序继续。完整方案的 A/B/C 各有侧重；旧模板仍轮换动作顺序。").font(.caption).fixedSize(horizontal: false, vertical: true)
    }
    Surface {
      Text("先看看现在的状态").font(.headline)
      Toggle("现在没有头晕、困倦或动作不稳", isOn: $ready).tint(Color.pine)
      Text("如果用药后仍困倦或反应受影响，先暂停器械训练。这里不调整你的用药方案。").font(.caption).foregroundStyle(Color.secondaryInk)
    }
    if let draft = store.data.draft {
      Surface {
        HStack {
          Text(draft.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
          Spacer()
          Pill(text: "已保存 \(draft.sets.count) 组")
        }
        if let end = draft.restUntil {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(end.timeIntervalSince(context.date)))
            HStack {
              Label(remaining > 0 ? "休息 \(remaining) 秒" : "休息计时结束", systemImage: "timer")
              Spacer()
              Button("结束计时") { store.endRest() }
            }.font(.subheadline)
          }
        }
        if let planned = draft.planned {
          ForEach(planned) { item in
            if let guide = TrainingLibrary.guide(item.exerciseID) {
              DisclosureGroup(guide.name + " · \(item.sets) 组 × " + item.reps) {
                VStack(alignment: .leading, spacing: 10) {
                  if let rest = item.restSeconds { Text("组间休息 \(rest) 秒；记录一组后自动计时。").font(.caption) }
                  Text(guide.cue); Text(guide.avoid).foregroundStyle(Color.secondaryInk)
                  Button("选器械档案 · 查看建议与记录") { selectedGuide = guide }
                  let progress = TrainingWorkload.progress(item, draft: draft, state: store.data.training)
                  Text(progress.summary).font(.caption)
                  if progress.remaining > 0 && !progress.hasUnevenSides && !TrainingSafety.isPaused(store.data) {
                  ForEach(TrainingWorkload.alternatives(for: item, draft: draft, state: store.data.training, equipment: store.data.coach?.preferences.equipment ?? "徒手", context: store.data.coach?.checkIn?.context ?? "在家", excluded: store.data.coach?.checkIn?.excludedExercises ?? [])) { alternative in
                    Button("器械被占，换成" + alternative.name) {
                      store.substituteExercise(itemID: item.id, exerciseID: alternative.id)
                      store.feedback("训练", "器械被占")
                    }
                  }
                  }
                }.font(.subheadline).padding(.vertical, 8)
              }
            }
          }
        }
        if let reference = draft.referenceSets, !reference.isEmpty {
          Text("上次记录，仅供参考；每一组都需要实际完成后确认。").font(.caption)
          ForEach(reference) { item in
            Button("\(item.exercise) · 上次 \(item.kg, specifier: "%.1f") kg × \(item.reps)") { exercise = item.exercise; kg = ""; reps = "" }
          }
        }
        DisclosureGroup("自由记录（不自动归入器械能力档案）") {
        VStack(alignment: .leading, spacing: 14) {
        Text("按你实际完成的动作记录。0 kg 可用于自重动作。").font(.caption).foregroundStyle(Color.secondaryInk)
        TextField("动作名称，例如坐姿划船", text: $exercise).entryField().accessibilityLabel("动作名称")
        HStack {
          TextField("重量 kg", text: $kg).entryField().accessibilityLabel("重量")
          TextField("次数", text: $reps).entryField().accessibilityLabel("次数")
        }
        MainButton(title: "完成一组并开始休息", symbol: "checkmark") {
          store.addSet(exercise: exercise, kg: Double(kg) ?? -1, reps: Int(reps) ?? 0)
        }.disabled(!ready)
        }
        }
        ForEach(draft.sets.reversed()) { set in
          HStack {
            Text(set.exercise)
            Spacer()
            Text("\(set.kg, specifier:"%.1f") kg × \(set.reps)").monospacedDigit()
            Button("撤销") { _ = store.change { $0.draft?.sets.removeAll { $0.id == set.id } } }
          }.font(.subheadline)
        }
      }
      Surface {
        Text("今天练起来感觉如何？").font(.headline)
        Picker("训练感受", selection: $effort) { ForEach(["轻松", "适中", "吃力"], id: \.self) { Text($0) } }
          .pickerStyle(.segmented)
        MainButton(title: "结束并保存这次训练", symbol: "flag.checkered") {
          if store.workoutNeedsDurationConfirmation() { confirmDuration = true }
          else { store.finishWorkout(effort: effort) }
        }.disabled(draft.sets.isEmpty)
        Text("部分完成也可以保存；尚未完成的循环不会推进。记录与目标始终分开。").font(.caption)
        Button("取消这次草稿", role: .destructive) { cancelDraft = true }
      }
    } else {
      Surface {
        Text("开始你的训练记录").font(.title2.bold())
        TextField("训练名称", text: $name).entryField()
        Text("首页可按当天条件选择恢复训练模板；这里也能自由记录你实际做的动作。负重由你校准，不自动推算。").font(.subheadline)
          .foregroundStyle(Color.secondaryInk)
        MainButton(title: "开始记录", symbol: "play.fill") { store.beginWorkout(name: name) }.disabled(
          !ready || name.isEmpty)
      }
    }
    MainButton(title: "记录乒乓球 / 其他活动", symbol: "figure.table.tennis") { sport = true }
    if !store.recentWorkouts.isEmpty {
      Subheading(title: "已完成的训练")
      ForEach(store.recentWorkouts.prefix(5)) { item in
        Surface {
          HStack {
            Text(item.name).font(.headline)
            Spacer()
            Text(item.date, format: .dateTime.month().day()).font(.caption)
          }
          Text("\(item.sets.count) 组 · \(item.minutes) 分钟 · 感受\(item.effort)").font(.subheadline)
            .foregroundStyle(Color.secondaryInk)
          Button("复用这次训练名称与参考动作") { _ = store.repeatWorkout(item) }.disabled(store.data.draft != nil || !ready || TrainingSafety.isPaused(store.data))
        }
      }
    }
    Text("动作参考：NHS Strength exercises、Mayo Clinic Weight training。不会调器械时请场馆教练现场指导。").font(.caption).foregroundStyle(Color.secondaryInk)
      .sheet(isPresented: $directory) { AbilityDirectory() }
      .sheet(item: $selectedGuide) { ExerciseSessionSheet(exerciseID: $0.id) }
      .sheet(isPresented: $sport) { ActivitySheet() }
      .sheet(isPresented: $confirmDuration) { WorkoutDurationSheet(effort: effort) }
      .alert("取消这次训练草稿？", isPresented: $cancelDraft) {
        Button("继续训练", role: .cancel) {}
        Button("取消草稿", role: .destructive) { _ = store.change { $0.draft = nil } }
      } message: { Text("草稿中的组数将删除；已经结束保存的训练不受影响。") }
  }
}

struct WorkoutDurationSheet: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let effort: String
  @State private var minutes = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack { Text("核对实际训练时长").font(.title2.bold()); Spacer(); Button("取消") { dismiss() } }
      if let started = store.data.draft?.started {
        Text("开始于 \(started.formatted())。这次训练跨日或计时较长，请填写实际运动的分钟数。").font(.subheadline)
      }
      TextField("实际训练分钟数", text: $minutes).entryField()
      Text("不计入离开后忘记结束的时间。取消会保留训练草稿。").font(.caption)
      MainButton(title: "确认时长并保存", symbol: "checkmark") {
        guard let value = Int(minutes), (1...1440).contains(value) else { store.alert = "请输入 1–1440 分钟的实际训练时长。"; return }
        if store.finishWorkout(effort: effort, actualMinutes: value) { dismiss() }
      }
    }.padding(26).frame(minWidth: 340).background(Color.canvas)
  }
}
