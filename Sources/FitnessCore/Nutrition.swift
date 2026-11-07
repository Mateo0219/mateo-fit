import Foundation

public struct MealNutrition: Codable, Equatable {
  public var basis = "本次吃下的份量"
  public var grams: Double?
  public var energyValue: Double?
  public var energyUnit = "kcal"
  public var proteinG: Double?
  public var carbsG: Double?
  public var fatG: Double?
  public var source = "包装营养标签"
  public init() {}
  public var hasNumbers: Bool { [energyValue, proteinG, carbsG, fatG].contains { $0 != nil } }
  public var valid: Bool {
    guard ["kcal", "kJ"].contains(energyUnit), ["本次吃下的份量", "每 100 克"].contains(basis), ["包装营养标签", "餐厅公布数据", "自行估计", "AI 估计", "其他已知来源"].contains(source) else { return false }
    guard grams.map({ $0.isFinite && $0 > 0 && $0 <= 10000 }) ?? true else { return false }
    guard [energyValue, proteinG, carbsG, fatG].allSatisfy({ $0.map { $0.isFinite && $0 >= 0 && $0 <= 10000 } ?? true }) else { return false }
    if basis == "每 100 克" {
      guard grams != nil || !hasNumbers else { return false }
      guard energyValue.map({ (energyUnit == "kJ" ? $0 / 4.184 : $0) <= 1000 }) ?? true else { return false }
      guard [proteinG, carbsG, fatG].allSatisfy({ $0.map { $0 <= 100 } ?? true }) else { return false }
    }
    return true
  }
  public var actualEnergyKcal: Double? { actual(energyValue.map { energyUnit == "kJ" ? $0 / 4.184 : $0 }) }
  public func actual(_ number: Double?) -> Double? {
    guard valid, let number else { return nil }
    if basis == "每 100 克" { guard let grams else { return nil }; return number * grams / 100 }
    return number
  }
}
public struct NutrientTotal {
  public let value: Double?
  public let coveredMeals: Int
  public let totalMeals: Int
}
public struct FoodDiaryReport {
  public let meals: [MealEntry]
  public let energy: NutrientTotal
  public let protein: NutrientTotal
  public let carbs: NutrientTotal
  public let fat: NutrientTotal
  public let estimatedMeals: Int
  public let confirmedComplete: Bool
  public let assessment: String
}
public enum FoodDiaryEngine {
  public static func report(_ data: AppData, now: Date = Date(), calendar: Calendar = .current) -> FoodDiaryReport {
    let meals = data.meals.filter { $0.confirmed && $0.date <= now && calendar.isDate($0.date, inSameDayAs: now) }.sorted { $0.date < $1.date }
    func sum(_ read: (MealNutrition) -> Double?) -> NutrientTotal {
      let values = meals.compactMap { meal -> Double? in guard let facts = meal.nutrition else { return nil }; return facts.valid ? read(facts) : nil }
      return NutrientTotal(value: values.isEmpty ? nil : values.reduce(0, +), coveredMeals: values.count, totalMeals: meals.count)
    }
    let energy = sum { $0.actualEnergyKcal }, protein = sum { $0.actual($0.proteinG) }, carbs = sum { $0.actual($0.carbsG) }, fat = sum { $0.actual($0.fatG) }
    let complete = data.foodDiaryCompleteAt.map { $0 <= now && calendar.isDate($0, inSameDayAs: now) } ?? false
    let missing = meals.count - energy.coveredMeals
    let assessment: String
    if meals.isEmpty { assessment = "先上传今天实际吃过的一餐。照片配上食物名称与大概份量即可，营养数据可以稍后补。" }
    else if missing > 0 { assessment = "已有 \(meals.count) 条饮食记录，其中 \(missing) 条还没有可汇总的能量数据。当前只汇总已填写部分，未填不当作 0。" }
    else if !complete { assessment = "已汇总 \(meals.count) 条记录中的能量数据。还没确认全天吃喝都记完，暂不把它当作全天总摄入。" }
    else { assessment = "你已确认今天吃喝都记完，已记录能量数据也完整。蛋白质等项目仍按各自覆盖率查看；个性化每日目标尚未核验，因此不判断热量缺口或是否达标。" }
    return FoodDiaryReport(meals: meals, energy: energy, protein: protein, carbs: carbs, fat: fat,
      estimatedMeals: meals.filter { ["自行估计", "AI 估计"].contains($0.nutrition?.source ?? "") && $0.nutrition?.hasNumbers == true }.count,
      confirmedComplete: complete, assessment: assessment)
  }
}
