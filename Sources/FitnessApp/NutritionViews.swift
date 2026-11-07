import FitnessCore
import SwiftUI

struct NutritionFields: View {
  @Binding var facts: MealNutrition
  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      Text("食物数据 · 有多少填多少").font(.headline)
      Text("包装上的数据常是每 100 克，先选对口径。能量单位可选 kcal 或 kJ，会自动换算。可使用饮食 Agent 先分析，再在这里核对或修改。").font(.caption).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
      Picker("数据口径", selection: $facts.basis) { Text("本次吃下的份量").tag("本次吃下的份量"); Text("每 100 克").tag("每 100 克") }
      HStack { Text("实际吃下 g"); TextField("不清楚可留空", value: $facts.grams, format: .number).entryField() }
      if facts.basis == "每 100 克" { Text("按每 100 克填写营养数值，App 用实际吃下的克数换算。").font(.caption) }
      HStack { Text("能量"); TextField("未填写", value: $facts.energyValue, format: .number).entryField(); Picker("单位", selection: $facts.energyUnit) { Text("kcal").tag("kcal"); Text("kJ").tag("kJ") }.frame(width: 95) }
      HStack { Text("蛋白质 g"); TextField("未填写", value: $facts.proteinG, format: .number).entryField() }
      HStack { Text("碳水 g"); TextField("未填写", value: $facts.carbsG, format: .number).entryField() }
      HStack { Text("脂肪 g"); TextField("未填写", value: $facts.fatG, format: .number).entryField() }
      Picker("数据来源", selection: $facts.source) { ForEach(["包装营养标签", "餐厅公布数据", "自行估计", "AI 估计", "其他已知来源"], id: \.self) { Text($0) } }
      Text("留空表示未知，0 表示你确认是零。混合餐食可以填写整餐数据；若每种食物来源不同，可分别上传记录。").font(.caption).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
    }
  }
}
struct FoodDiaryCard: View {
  @EnvironmentObject var store: AppStore
  var onLog: () -> Void
  var onEdit: () -> Void
  private var report: FoodDiaryReport { FoodDiaryEngine.report(store.data) }
  var body: some View {
    Surface {
      Text("今天的饮食分析").font(.title2.bold())
      Text(report.assessment).font(.subheadline).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
      nutrient("已记录能量", report.energy, "kcal")
      nutrient("已记录蛋白质", report.protein, "g")
      nutrient("已记录碳水", report.carbs, "g")
      nutrient("已记录脂肪", report.fat, "g")
      if report.estimatedMeals > 0 { Text("其中 \(report.estimatedMeals) 条来自人工或 AI 估计，总和也包含这些估计值。").font(.caption).foregroundStyle(.orange) }
      MainButton(title: "上传今天吃的与食物数据", symbol: "plus") { onLog() }
      HStack { Button("补充 / 修改已上传数据") { onEdit() }; Spacer() }
      if !report.meals.isEmpty {
        Toggle("今天的正餐、零食和饮料都记完了", isOn: Binding(get: { report.confirmedComplete }, set: { value in _ = store.change { $0.foodDiaryCompleteAt = value ? Date() : nil } }))
          .font(.caption).tint(Color.pine)
        Text("新增或修改今天的餐食后会重新确认，避免漏项。未建立个人营养目标，不给出达标或过量判断。").font(.caption).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
  private func nutrient(_ name: String, _ total: NutrientTotal, _ unit: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 3) {
        Text(name).font(.subheadline)
        Text("\(total.coveredMeals)/\(total.totalMeals) 条记录有此数据").font(.caption).foregroundStyle(Color.secondaryInk)
      }
      Spacer()
      Text(total.value.map { String(format: "%.1f %@", $0, unit) } ?? "未知").font(.headline).monospacedDigit()
    }
  }
}
