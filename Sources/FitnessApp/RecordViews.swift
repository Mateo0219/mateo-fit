import FitnessCore
import SwiftUI

struct ActivitySheet: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var name = "乒乓球"
  @State private var minutes = "60"
  @State private var effort = "适中"
  @State private var date = Date()
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack { Text("记录已完成的活动").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() } }
      TextField("活动名称", text: $name).entryField()
      TextField("实际分钟数", text: $minutes).entryField()
      DatePicker("完成时间", selection: $date, in: ...Date())
      Picker("感受", selection: $effort) { ForEach(["轻松","适中","吃力"], id: \.self) { Text($0) } }
      Text("只保存你实际完成的活动，不推算热量。").font(.caption)
      MainButton(title: "确认已完成并保存", symbol: "checkmark") {
        guard let m = Int(minutes), (1...1440).contains(m), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { store.alert = "请检查活动名称与时长。"; return }
        if store.change({ $0.workouts.append(WorkoutEntry(date: date, name: name, sets: [], effort: effort, minutes: m)) }) { dismiss() }
      }
    }.padding(26).frame(minWidth: 340).background(Color.canvas)
  }
}
struct RecordManager: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var kind = 0
  @State private var deleted = false
  @State private var meal: MealEntry?
  @State private var workout: WorkoutEntry?
  @State private var weight: WeightEntry?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack { Text("记录管理").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() } }
        Picker("类型", selection: $kind) { Text("餐食").tag(0); Text("训练").tag(1); Text("体重").tag(2) }.pickerStyle(.segmented)
        Toggle("查看已移除记录（可恢复）", isOn: $deleted)
        Text("餐食、训练和手动体重可编辑或移除；Apple 健康来源需在来源 App 修改。移除记录仍保存在本机回收区并包含于备份。").font(.caption).foregroundStyle(Color.secondaryInk)
        if kind == 0 {
          let items = (deleted ? store.data.trash?.meals ?? [] : store.data.meals).sorted { $0.date > $1.date }
          if items.isEmpty { Text("这里还没有餐食记录。") }
          ForEach(items) { item in
            Surface {
              Text(item.title).font(.headline); Text(item.date.formatted()).font(.caption)
              HStack {
                if deleted { Button("恢复") { _ = store.change { $0.trash?.meals.removeAll { $0.id == item.id }; $0.meals.append(item) } } }
                else { Button("编辑") { meal = item }; Spacer(); Button("移除", role: .destructive) { store.deleteMeal(item) } }
              }
            }
          }
        } else if kind == 1 {
          let items = (deleted ? store.data.trash?.workouts ?? [] : store.data.workouts).sorted { $0.date > $1.date }
          if items.isEmpty { Text("这里还没有训练记录。") }
          ForEach(items) { item in
            Surface {
              Text(item.name).font(.headline); Text("\(item.date.formatted()) · \(item.sets.count) 组 · \(item.minutes) 分钟").font(.caption)
              HStack {
                if deleted { Button("恢复") { _ = store.change { $0.trash?.workouts.removeAll { $0.id == item.id }; $0.workouts.append(item) } } }
                else { Button("编辑") { workout = item }; Spacer(); Button("移除", role: .destructive) { store.deleteWorkout(item) } }
              }
            }
          }
        } else {
          let items = (deleted ? store.data.trash?.weights ?? [] : store.data.weights).sorted { $0.date > $1.date }
          if items.isEmpty { Text("这里还没有测量记录。") }
          ForEach(items) { item in
            Surface {
              Text("\(item.kg, specifier: "%.1f") kg").font(.headline)
              Text("\(item.date.formatted()) · \(item.source)").font(.caption)
              if item.source == "手动记录" {
                HStack {
                  if deleted { Button("恢复") { _ = store.change { $0.trash?.weights.removeAll { $0.id == item.id }; $0.weights.append(item) } } }
                  else { Button("编辑") { weight = item }; Spacer(); Button("移除", role: .destructive) { store.deleteWeight(item) } }
                }
              }
            }
          }
        }
      }.padding(24)
    }.frame(minWidth: 340, minHeight: 550).background(Color.canvas)
      .sheet(item: $meal) { MealEditSheet(item: $0) }
      .sheet(item: $workout) { WorkoutEditSheet(item: $0) }
      .sheet(item: $weight) { WeightEditSheet(item: $0) }
  }
}
struct MealEditSheet: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State var item: MealEntry
  @State private var facts = MealNutrition()
  var body: some View {
    ScrollView {
    VStack(alignment: .leading, spacing: 18) {
      HStack { Text("编辑餐食").font(.title2.bold()); Spacer(); Button("取消") { dismiss() } }
      TextField("餐食名称", text: $item.title).entryField()
      TextField("份量与备注", text: $item.note, axis: .vertical).entryField()
      DatePicker("实际吃饭时间", selection: $item.date, in: ...Date())
      if let name = item.photoName, let bytes = store.photo(name) { LocalPhoto(bytes: bytes).frame(height: 120).clipped() }
      Text("照片保留，修改数据和时间不会新增一餐。").font(.caption)
      NutritionFields(facts: $facts)
      MainButton(title: "保存修改", symbol: "checkmark") {
        guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { store.alert = "餐食名称不能为空。"; return }
        guard facts.valid else { store.alert = "请检查营养数值、单位和实际克数。"; return }
        item.nutrition = facts.hasNumbers || facts.grams != nil ? facts : nil
        if store.change({ data in if let i = data.meals.firstIndex(where: { $0.id == item.id }) { data.meals[i] = item } }) { dismiss() }
      }
    }.padding(26)
    }.frame(minWidth: 340, minHeight: 560).background(Color.canvas).onAppear { facts = item.nutrition ?? MealNutrition() }
  }
}
struct WeightEditSheet: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State var item: WeightEntry
  @State private var kg = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack { Text("编辑手动体重").font(.title2.bold()); Spacer(); Button("取消") { dismiss() } }
      TextField("kg", text: $kg).entryField()
      DatePicker("测量时间", selection: $item.date, in: ...Date())
      MainButton(title: "保存修改", symbol: "checkmark") {
        guard let value = Double(kg), DataMath.validWeight(value), item.source == "手动记录" else { store.alert = "请检查体重数值与来源。"; return }
        item.kg = value
        if store.change({ data in if let i = data.weights.firstIndex(where: { $0.id == item.id }) { data.weights[i] = item } }) { dismiss() }
      }
    }.padding(26).frame(minWidth: 340).background(Color.canvas).onAppear { kg = String(item.kg) }
  }
}
struct WorkoutEditSheet: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State var item: WorkoutEntry
  @State private var minutes = ""
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack { Text("编辑训练").font(.title2.bold()); Spacer(); Button("取消") { dismiss() } }
        TextField("名称", text: $item.name).entryField()
        TextField("实际分钟数", text: $minutes).entryField()
        DatePicker("完成时间", selection: $item.date, in: ...Date())
        Picker("感受", selection: $item.effort) { ForEach(["轻松","适中","吃力"], id: \.self) { Text($0) } }
        ForEach($item.sets) { $set in
          VStack(alignment: .leading, spacing: 10) {
            TextField("动作", text: $set.exercise).entryField().disabled(set.profileID != nil)
            if set.profileID != nil {
              Text("关联器械档案，动作身份不能直接改名。").font(.caption)
              Picker("还能完成几次", selection: Binding(get: { set.rir ?? -1 }, set: { set.rir = $0 < 0 ? nil : $0 })) { Text("未知").tag(-1); ForEach(0...10, id: \.self) { Text("\($0) 次").tag($0) } }
              Picker("动作感受", selection: Binding(get: { set.form ?? "不确定" }, set: { set.form = $0 })) { ForEach(["不确定", "标准完成", "动作变形", "疼痛"], id: \.self) { Text($0) } }
              Picker("组类型", selection: Binding(get: { set.setKind ?? "工作组" }, set: { set.setKind = $0 })) { Text("工作组").tag("工作组"); Text("热身组").tag("热身组") }
            }
            HStack { Text("kg"); TextField("重量", value: $set.kg, format: .number).entryField(); Text("次"); TextField("次数", value: $set.reps, format: .number).entryField() }
          }
        }
        MainButton(title: "保存修改", symbol: "checkmark") {
          guard let value = Int(minutes), (1...1440).contains(value), !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            item.sets.allSatisfy({ !$0.exercise.isEmpty && $0.kg.isFinite && (0...1000).contains($0.kg) && (1...500).contains($0.reps) }) else { store.alert = "请检查名称、时长、重量和次数。"; return }
          item.minutes = value
          if store.change({ data in if let i = data.workouts.firstIndex(where: { $0.id == item.id }) { data.workouts[i] = item } }) { dismiss() }
        }
      }.padding(26)
    }.frame(minWidth: 340, minHeight: 500).background(Color.canvas).onAppear { minutes = String(item.minutes) }
  }
}
