import FitnessCore
import SwiftUI

/// Shared plan entry: browsing a plan never starts or completes a workout.
struct TrainingPlanCard: View {
  @EnvironmentObject var store: AppStore
  var onOpenTraining: (() -> Void)? = nil
  @State private var program = false
  @State private var setup = false
  @State private var checkIn = false
  private var plan: DailyWorkoutPlan { DailyPlanner.plan(store.data) }
  private var exercises: [PlannedExercise] { store.data.draft?.planned ?? plan.exercises }
  private var scheduledDays: String {
    let days = [(2, "周一"), (3, "周二"), (4, "周三"), (5, "周四"), (6, "周五"), (7, "周六"), (1, "周日")]
    guard let prefs = store.data.coach?.preferences, prefs.confirmedAt != nil else { return "训练日待确认" }
    return days.filter { prefs.trainingWeekdays.contains($0.0) }.map { $0.1 }.joined(separator: "、")
  }
  var body: some View {
    Surface {
      Label("我的训练计划", systemImage: "list.bullet.clipboard").font(.title2.bold())
      MainButton(title: "查看完整周计划 · A / B / C + 第 4 次", symbol: "calendar") { program = true }
      if store.data.coach?.preferences.programID != StrengthProgram.id {
        Text("新方案可先预览，再确认采用。下方仍是你当前的安排。").font(.caption).foregroundStyle(Color.secondaryInk)
      }
      Text(scheduledDays).font(.subheadline).foregroundStyle(Color.secondaryInk)
      if let draft = store.data.draft {
        Pill(text: "进行中 · 已保存 \(draft.sets.count) 组")
        Text(draft.name).font(.title3.bold())
        if let note = draft.adaptationNote { Text(note).font(.caption).fixedSize(horizontal: false, vertical: true) }
        if exercises.isEmpty { Text("这是一场自由训练，没有预设动作清单。你可以继续记录实际完成的动作。").font(.subheadline) }
      } else {
        Text(plan.title).font(.title3.bold())
        Text(plan.reason).font(.subheadline).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
      }
      if store.data.draft?.programID == StrengthProgram.id || (store.data.draft == nil && store.data.coach?.preferences.programID == StrengthProgram.id && plan.status == "ready") {
        DisclosureGroup("本次流程：热身 → 力量 → 可选有氧 → 放松") {
          Text(StrengthProgram.warmup); Text(StrengthProgram.effort); Text(StrengthProgram.cardio)
        }.font(.caption)
      }
      ForEach(Array(exercises.enumerated()), id: \.element.id) { index, item in
        if let guide = TrainingLibrary.guide(item.exerciseID) {
          HStack(alignment: .top, spacing: 12) {
            Text("\(index + 1)").font(.headline).foregroundStyle(Color.pine).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
              Text(guide.name).font(.headline)
              Text("\(item.sets) 组 · \(item.reps)" + (item.restSeconds.map { " · 休息 \($0) 秒" } ?? "")).font(.subheadline).foregroundStyle(Color.secondaryInk)
            }
            Spacer(minLength: 0)
          }.padding(.vertical, 5)
        }
      }
      if store.data.draft != nil {
        if let onOpenTraining {
          MainButton(title: "继续训练与记录", symbol: "play.fill", action: onOpenTraining)
        } else { Text("下方展开对应动作，选择器械档案并记录实际完成。").font(.caption) }
      } else if plan.status == "setup" {
        Text("第 1 步：确认器械和训练日 → 第 2 步：确认今天状态 → 显示动作清单").font(.caption).fixedSize(horizontal: false, vertical: true)
        MainButton(title: "设置我的训练计划", symbol: "slider.horizontal.3") { setup = true }
      } else if plan.status == "checkin" {
        Text("训练条件已保存，还差今天的状态确认。").font(.caption)
        MainButton(title: "确认今天状态，查看动作清单", symbol: "checkmark.circle") { checkIn = true }
      } else if plan.status == "ready" {
        Text("负重首次由你校准；开始后可查看每个动作的器械档案与递进建议。").font(.caption).foregroundStyle(Color.secondaryInk)
        MainButton(title: "开始这份训练计划", symbol: "play.fill") { if store.startPlan() { onOpenTraining?() } }
      }
      HStack {
        Button("训练日与器械设置") { setup = true }
        Spacer()
        Button("调整今天") { checkIn = true }
      }.font(.subheadline)
    }
    .sheet(isPresented: $program) { ProgramOverview() }
    .sheet(isPresented: $setup) { CoachSetupSheet() }
    .sheet(isPresented: $checkIn) { CheckInSheet() }
  }
}
