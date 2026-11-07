import FitnessCore
import SwiftUI

struct TodayView: View {
  @EnvironmentObject var store: AppStore
  @Binding var selection: Int
  @State private var recipe: Recipe?
  @State private var mealIndex = 0
  @State private var foodLog = false
  @State private var records = false
  private var plan: DailyWorkoutPlan { DailyPlanner.plan(store.data) }
  private var meals: [MealSuggestion] {
    MealEngine.suggest(pantry: store.data.pantry, excluded: store.data.profile.excludedFoods,
      maxMinutes: store.data.coach?.preferences.cookingMinutes ?? 30, reviewed: store.data.profile.allergiesReviewed)
  }
  var body: some View {
    Surface(dark: true) {
      Pill(text: "今天 · 一步一步来", dark: true)
      Text(plan.title).font(.system(size: 29, weight: .bold))
      Text(store.data.draft == nil ? "安排今天运动，记下今天吃喝。" : "有一场训练还在进行，已保存 \(store.data.draft?.sets.count ?? 0) 组。")
        .font(.subheadline).foregroundStyle(.white.opacity(0.85))
    }
    TrainingPlanCard(onOpenTraining: { selection = 2 })
    FoodDiaryCard(onLog: { foodLog = true }, onEdit: { records = true })
    DisclosureGroup("需要时，帮我选下一餐") {
    Surface {
      HStack { Label("下一餐吃什么", systemImage: "fork.knife").font(.title2.bold()); Spacer() }
      if !store.data.profile.allergiesReviewed {
        Text("先确认过敏和忌口，再给你搭配。")
        Button("去确认饮食限制") { selection = 1 }
      } else if !DailyPlanner.pantryFresh(store.data) {
        Text("今天手边有哪些食材？确认库存后，优先用现有食材搭配。")
        MainButton(title: "告诉我现在有什么", symbol: "basket") { selection = 1 }
      } else if !meals.isEmpty {
        let meal = meals[mealIndex % meals.count]
        Text(meal.recipe.name).font(.title3.bold())
        Text("约 \(meal.recipe.minutes) 分钟 · " + (meal.ready ? "已确认的食材可以搭配" : "还需准备：" + meal.missing.map(FoodCatalog.name).joined(separator: "、")))
          .font(.subheadline).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
        MainButton(title: "看做法与份量备注", symbol: "arrow.right") { recipe = meal.recipe }
        Button("今天不想吃这道，换一道") { mealIndex += 1; store.feedback("饮食", "换一道") }.disabled(meals.count < 2)
      } else { Text("现有菜谱没有符合限制与时间的组合。"); Button("调整准备时间和食材") { selection = 1 } }
      Text("参考主食、蛋白质食物和蔬菜的组合。还没有完整份量记录，暂不判断你缺多少热量或营养素。").font(.caption).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
    }
    }
    Surface {
      Text("今天还差哪一步").font(.headline)
      Text(store.todayMeals.isEmpty ? "还没记录吃过的餐食。可以拍照加一句话，也可以复用上次的餐食。" : "已确认 \(store.todayMeals.count) 条饮食记录，漏记可随时补。")
        .font(.subheadline)
      HStack { Button("快捷记一餐") { selection = 1 }; Spacer(); Button("查看身体趋势") { selection = 3 } }
      if let weight = store.latestWeight { Text("最近测量 \(weight.kg, specifier: "%.1f") kg · \(weight.date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true) }
    }
    Text("本地计划与健康分析 · 主动上传的餐食交由 Agent 分析 · 建议不会自动记为完成").font(.caption).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
      .sheet(isPresented: $foodLog) { MealLogSheet() }
      .sheet(isPresented: $records) { RecordManager() }
      .sheet(item: $recipe) { RecipeSheet(recipe: $0) }
  }
}
struct CoachSetupSheet: View {
  var proposedProgram = false
  var proposedPhase = "恢复适应"
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var preferences = CoachPreferences()
  private let days = [(2,"一"),(3,"二"),(4,"三"),(5,"四"),(6,"五"),(7,"六"),(1,"日")]
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack { Text("训练与做饭条件").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() } }
        Text(preferences.programID == StrengthProgram.id ? "完整计划：每周 3 次主训练 + 可选第 4 次有氧恢复。确认后用于后续安排。" : "确认后才安排本地恢复训练模板；你可以随时修改。").font(.subheadline)
        Picker("力量训练经验", selection: $preferences.experience) { ForEach(["未确认","第一次练","练过，正在恢复","持续训练中"], id: \.self) { Text($0) } }
        Picker("可用器械", selection: $preferences.equipment) { ForEach(["未确认","器械与哑铃","只有哑铃","徒手"], id: \.self) { Text($0) } }
        Picker("运动限制", selection: $preferences.restrictions) { ForEach(["未确认","没有已知限制","有疼痛或医生限制"], id: \.self) { Text($0) } }
        if preferences.restrictions == "有疼痛或医生限制" { TextField("需要注意什么", text: $preferences.restrictionNote, axis: .vertical).entryField() }
        if preferences.programID == StrengthProgram.id {
          Picker("训练阶段", selection: Binding(get: { preferences.trainingPhase ?? "恢复适应" }, set: { preferences.trainingPhase = $0 })) { ForEach(StrengthProgram.phases, id: \.self) { Text($0) } }
          Text("请选择 3 个不相邻的力量日。第 4 次可选有氧恢复不勾选为力量日，乒乓球安排在其余日期并留出休息。").font(.caption)
        }
        Text("哪些天方便训练？").font(.headline)
        HStack { ForEach(days, id: \.0) { day in
          Button(day.1) { if preferences.trainingWeekdays.contains(day.0) { preferences.trainingWeekdays.remove(day.0) } else { preferences.trainingWeekdays.insert(day.0) } }
            .buttonStyle(.bordered).tint(preferences.trainingWeekdays.contains(day.0) ? Color.pine : .gray)
        } }
        Text("尽量给全身力量训练留出间隔；前一天已记录力量训练时，首页会建议恢复。").font(.caption).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
        Picker("默认训练时间", selection: $preferences.workoutMinutes) { Text("20 分钟").tag(20); Text("45 分钟").tag(45); Text("60 分钟").tag(60); Text("90 分钟").tag(90) }
        Picker("默认做饭时间", selection: $preferences.cookingMinutes) { Text("15 分钟").tag(15); Text("30 分钟").tag(30); Text("45 分钟").tag(45) }
        MainButton(title: "确认并保存", symbol: "checkmark") { if store.savePreferences(preferences) { dismiss() } }
      }.padding(24)
    }.frame(minWidth: 340, minHeight: 520).background(Color.canvas)
      .onAppear {
        preferences = store.data.coach?.preferences ?? CoachPreferences()
        if proposedProgram {
          preferences.programID = StrengthProgram.id; preferences.trainingPhase = proposedPhase
          if !StrengthProgram.validDays(preferences.trainingWeekdays) { preferences.trainingWeekdays = [2, 4, 6] }
          preferences.workoutMinutes = 60
        }
      }
  }
}
struct CheckInSheet: View {
  var suggestedMinutes: Int? = nil
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var check = DailyCheckIn()
  @State private var recoveryConfirmed = false
  var body: some View {
    ScrollView {
    VStack(alignment: .leading, spacing: 22) {
      HStack { Text("今天的你").font(.title.bold()); Spacer(); Button("关闭") { dismiss() } }
      if TrainingSafety.isPaused(store.data) {
        Text(TrainingSafety.message).font(.subheadline).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
        Toggle("我已核对：当前没有头晕、困倦、动作不稳或疼痛，且适合恢复训练", isOn: $recoveryConfirmed)
        Text("不勾选也可以更新当天条件，训练暂停会继续保留。").font(.caption).foregroundStyle(Color.secondaryInk)
      }
      Picker("现在感觉", selection: $check.energy) { ForEach(["未确认","状态正常","有点疲惫","不适或困倦"], id: \.self) { Text($0) } }
      Picker("今天在哪里 / 做什么", selection: $check.context) { ForEach(["健身房","在家","乒乓球","休息"], id: \.self) { Text($0) } }
      Picker("可用时间", selection: $check.minutes) { ForEach(Array(Set([20,45,60,90] + [suggestedMinutes ?? 45])).sorted(), id: \.self) { Text("\($0) 分钟").tag($0) } }
      Toggle("过去 24 小时打球较累，或腿部仍明显疲劳", isOn: Binding(get: { check.sportFatigue ?? false }, set: { check.sportFatigue = $0 }))
      Toggle("今天用轻松版本", isOn: Binding(get: { check.lighter ?? false }, set: { check.lighter = $0 }))
      DisclosureGroup("今天不做哪些动作？") {
        ForEach(TrainingLibrary.guides) { guide in
          Toggle(guide.name, isOn: Binding(get: { check.excludedExercises?.contains(guide.id) ?? false }, set: { value in
            var excluded = check.excludedExercises ?? []; if value { excluded.insert(guide.id) } else { excluded.remove(guide.id) }; check.excludedExercises = excluded
          }))
        }
      }
      Text("当天调整不会改长期偏好。已有草稿会保留完成组数，剩余目标重新确认。若出现疼痛，请选不适并暂停，而非仅排除动作。").font(.caption).fixedSize(horizontal: false, vertical: true)
      Text("头晕、明显困倦、疼痛或动作不稳时选“不适或困倦”。只用于今天，不会改成长期偏好。").font(.subheadline).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
      MainButton(title: "确认今天状态", symbol: "checkmark") {
        check.date = Date(); check.confirmedFields = ["energy", "context", "minutes", "sportFatigue", "lighter", "excludedExercises"]
        let saved = TrainingSafety.isPaused(store.data) && recoveryConfirmed ? store.confirmTrainingRecovery(check) : store.saveCheckIn(check)
        if saved { dismiss() }
      }.disabled(check.energy == "未确认" || (TrainingSafety.isPaused(store.data) && recoveryConfirmed && check.energy != "状态正常"))
    }.padding(26)
    }.frame(minWidth: 340, minHeight: 500).background(Color.canvas).onAppear {
      if let existing = store.data.coach?.checkIn, Calendar.current.isDateInToday(existing.date) { check = existing }
      else { check.minutes = store.data.coach?.preferences.workoutMinutes ?? 45 }
      if let suggestedMinutes { check.minutes = suggestedMinutes }
    }
  }
}
struct WeeklyReviewCard: View {
  @EnvironmentObject var store: AppStore
  @State private var proposal: WeeklyReview?
  @State private var confirming = false
  private var review: WeeklyReview { ReviewEngine.review(store.data) }
  var body: some View {
    Surface {
      Text("近 7 天复盘").font(.title2.bold())
      Text("有训练记录 \(review.workoutDays) 天 · 饮食记录 \(review.meals) 条 · 反馈 \(review.feedbackCount) 次").font(.subheadline)
      Text(review.reason).font(.subheadline).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
      Text("体重趋势请结合上方有效测量日查看；漏记不会算作没吃、没练。当前不根据单日体重或睡眠分期自动加练、减餐。").font(.caption).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
      if review.proposed != nil { MainButton(title: "查看并确认这项调整", symbol: "slider.horizontal.3") { proposal = review; confirming = true } }
      if let last = store.data.coach?.changes.last {
        Text("计划版本 \(last.revision) · \(last.reason)").font(.caption)
      }
    }.alert("将默认训练时间改为 20 分钟？", isPresented: $confirming) {
      Button("取消", role: .cancel) { proposal = nil }
      Button("确认调整") { if let proposal { _ = store.applyReview(proposal) }; proposal = nil }
    } message: { Text("训练日不变，不改负重或饮食。保存调整依据，可在“我的 → 调整历史”撤回。") }
  }
}
