import Foundation

public struct Profile: Codable, Equatable {
  public var confirmedAt: Date?
  public var age: Int = 24
  public var heightCM: Double = 183
  public var initialWeightKG: Double = 119
  public var goal = "减脂，重新建立训练习惯"
  public var allergiesReviewed = false
  public var excludedFoods: Set<String> = []
  public var weeklyGymDays = 3
  public init() {}
}
public struct WeightEntry: Codable, Identifiable, Equatable {
  public var id: String
  public var date: Date
  public var kg: Double
  public var source: String
  public init(
    id: String = UUID().uuidString, date: Date = Date(), kg: Double, source: String = "手动记录"
  ) {
    self.id = id
    self.date = date
    self.kg = kg
    self.source = source
  }
}
public struct SleepEntry: Codable, Identifiable {
  public var id: String
  public var start: Date
  public var end: Date
  public var source: String
  public var stage: SleepStage?
  public var sourceID: String?
  public var isWatch: Bool?
  public var resolvedStage: SleepStage { stage ?? .unspecified }
  public init(id: String, start: Date, end: Date, source: String,
              stage: SleepStage? = nil, sourceID: String? = nil, isWatch: Bool? = nil) {
    self.id = id
    self.start = start
    self.end = end
    self.source = source
    self.stage = stage
    self.sourceID = sourceID
    self.isWatch = isWatch
  }
}
public struct MealEntry: Codable, Identifiable, Equatable {
  public var id: UUID
  public var date: Date
  public var title: String
  public var note: String
  public var photoName: String?
  public var confirmed: Bool
  public var nutrition: MealNutrition?
  public init(
    id: UUID = UUID(), date: Date = Date(), title: String, note: String = "",
    photoName: String? = nil, confirmed: Bool = true, nutrition: MealNutrition? = nil
  ) {
    self.id = id
    self.date = date
    self.title = title
    self.note = note
    self.photoName = photoName
    self.confirmed = confirmed
    self.nutrition = nutrition
  }
}
public struct SetEntry: Codable, Identifiable {
  public var id = UUID()
  public var exercise: String
  public var kg: Double
  public var reps: Int
  public var date = Date()
  public var profileID: UUID?
  public var profileRevision: Int?
  public var exerciseID: String?
  public var rir: Int?
  public var form: String?
  public var setKind: String?
  public var targetID: UUID?
  public init(exercise: String, kg: Double, reps: Int) {
    self.exercise = exercise
    self.kg = kg
    self.reps = reps
  }
}
public struct WorkoutEntry: Codable, Identifiable {
  public var id: UUID
  public var date: Date
  public var name: String
  public var sets: [SetEntry]
  public var effort: String
  public var minutes: Int
  public init(
    id: UUID = UUID(), date: Date = Date(), name: String, sets: [SetEntry], effort: String,
    minutes: Int
  ) {
    self.id = id
    self.date = date
    self.name = name
    self.sets = sets
    self.effort = effort
    self.minutes = minutes
  }
}
public struct WorkoutDraft: Codable {
  public var programID: String?
  public var started = Date()
  public var name = "健身房训练"
  public var sets: [SetEntry] = []
  public var restUntil: Date?
  public var planned: [PlannedExercise]?
  public var referenceSets: [SetEntry]?
  public var targets: [TrainingTarget]?
  public var sequenceSlot: Int?
  public var adaptationNote: String?
  public init() {}
}
public struct AppData: Codable {
  public var version = 1
  public var profile = Profile()
  public var pantry: Set<String> = ["egg", "rice", "tomato"]
  public var pantryConfirmedAt: Date?
  public var weights: [WeightEntry] = []
  public var sleep: [SleepEntry] = []
  public var meals: [MealEntry] = []
  public var workouts: [WorkoutEntry] = []
  public var draft: WorkoutDraft?
  public var healthAnchors: [String: Data] = [:]
  public var healthSyncedAt: Date?
  public var lastHealthSummary: String?
  public var healthAutoSyncEnabled: Bool?
  public var coach: CoachState?
  public var trash: RecordTrash?
  public var foodDiaryCompleteAt: Date?
  public var training: TrainingState?
  public var trainingSafety: TrainingSafetyState?
  public var conversation: [CoachTurn]?
  public var coachThreads: [CoachThread]?
  public var activeCoachThreadID: UUID?
  public var homeComposer: HomeComposerDraft?
  public var pendingHomeMeal: HomeMealDraft?
  public var coachJobCleanup: [CoachJobCleanup]?
  public var homeCommitIDs: [String]?
  public var personalAgent: PersonalAgentState?
  public var selectedTab = 0
  public init() {}
}
public struct Ingredient: Identifiable, Hashable {
  public let id: String
  public let name: String
  public let symbol: String
  public let group: String
}
public struct Recipe: Identifiable {
  public let id: String
  public let name: String
  public let ingredients: [String]
  public let minutes: Int
  public let directions: [String]
  public let note: String
  public init(
    id: String, name: String, ingredients: [String], minutes: Int, directions: [String],
    note: String
  ) {
    self.id = id
    self.name = name
    self.ingredients = ingredients
    self.minutes = minutes
    self.directions = directions
    self.note = note
  }
}
public enum FoodCatalog {
  public static let ingredients: [Ingredient] = [
    .init(id: "egg", name: "鸡蛋", symbol: "circle.lefthalf.filled", group: "蛋白质食物"),
    .init(id: "chicken", name: "鸡胸肉", symbol: "fork.knife", group: "蛋白质食物"),
    .init(id: "tofu", name: "豆腐", symbol: "square.grid.2x2", group: "蛋白质食物"),
    .init(id: "fish", name: "鱼", symbol: "fish", group: "蛋白质食物"),
    .init(id: "rice", name: "米饭", symbol: "takeoutbag.and.cup.and.straw", group: "主食"),
    .init(id: "potato", name: "土豆", symbol: "oval", group: "主食"),
    .init(id: "noodles", name: "面条", symbol: "line.3.horizontal", group: "主食"),
    .init(id: "tomato", name: "番茄", symbol: "circle.fill", group: "蔬菜"),
    .init(id: "broccoli", name: "西兰花", symbol: "tree", group: "蔬菜"),
    .init(id: "greens", name: "绿叶菜", symbol: "leaf", group: "蔬菜"),
  ]
  public static func name(_ id: String) -> String { ingredients.first { $0.id == id }?.name ?? id }
  public static let recipes: [Recipe] = [
    .init(
      id: "tomato-egg", name: "番茄炒蛋配米饭", ingredients: ["egg", "tomato", "rice"], minutes: 15,
      directions: ["先确认鸡蛋、番茄和米饭的可用份量。", "番茄切块，鸡蛋打散；油与调味料单独记录。", "鸡蛋与番茄炒熟，搭配米饭。"],
      note: "提供搭配思路；个性化份量与营养目标尚待确认。"),
    .init(
      id: "tofu-bowl", name: "番茄炖豆腐配米饭", ingredients: ["tofu", "tomato", "rice"], minutes: 20,
      directions: ["豆腐切块，番茄切丁。", "将番茄炒出汁，加豆腐炖熟。", "配米饭，记录实际吃下的份量。"], note: "豆腐属于大豆制品；按已确认的过敏与忌口筛选。"),
    .init(
      id: "chicken-bowl", name: "鸡肉西兰花饭", ingredients: ["chicken", "broccoli", "rice"], minutes: 25,
      directions: ["确认鸡肉、蔬菜和米饭的实际份量。", "鸡肉切片炒至完全熟透，西兰花煮熟。", "组合成一餐，油和酱料也计入记录。"],
      note: "先给可执行组合；不把照片估计当精确热量。"),
    .init(
      id: "fish-potato", name: "清蒸鱼配土豆和青菜", ingredients: ["fish", "potato", "greens"], minutes: 30,
      directions: ["土豆与青菜洗净，鱼处理好。", "鱼和土豆蒸至熟透，青菜煮熟。", "按实际食用份量记录。"],
      note: "鱼的种类与做法会影响营养值；当前不估算精确缺口。"),
    .init(
      id: "egg-noodles", name: "番茄鸡蛋面", ingredients: ["egg", "tomato", "noodles"], minutes: 15,
      directions: ["煮熟面条，准备番茄与鸡蛋。", "将鸡蛋、番茄做成汤底，确保食材熟透。", "加入面条，记录面条份量和汤底调料。"],
      note: "面条可能含小麦或鸡蛋；需核对包装过敏原。"),
  ]
}
public struct MealSuggestion: Identifiable {
  public var id: String { recipe.id }
  public let recipe: Recipe
  public let missing: [String]
  public var ready: Bool { missing.isEmpty }
}
public enum MealEngine {
  public static func suggest(
    pantry: Set<String>, excluded: Set<String>, maxMinutes: Int, reviewed: Bool
  ) -> [MealSuggestion] {
    guard reviewed else { return [] }
    return FoodCatalog.recipes.filter {
      $0.minutes <= maxMinutes && Set($0.ingredients).isDisjoint(with: excluded)
    }
    .map { MealSuggestion(recipe: $0, missing: $0.ingredients.filter { !pantry.contains($0) }) }
    .sorted { a, b in
      a.missing.count == b.missing.count
        ? a.recipe.id < b.recipe.id : a.missing.count < b.missing.count
    }
  }
}
public enum DataMath {
  public static func validWeight(_ value: Double) -> Bool {
    value.isFinite && value >= 20 && value <= 500
  }
  public static func mergedWeights(
    _ existing: [WeightEntry], additions: [WeightEntry], deleted: Set<String>
  ) -> [WeightEntry] {
    var byID = Dictionary(
      existing.filter { !deleted.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    for item in additions where validWeight(item.kg) && !deleted.contains(item.id) {
      byID[item.id] = item
    }
    return byID.values.sorted { $0.date < $1.date }
  }
  public static func sleepHours(_ intervals: [SleepEntry], from: Date, to: Date) -> Double? {
    let parts = intervals.filter { $0.resolvedStage.isAsleep }.map { (max($0.start, from), min($0.end, to)) }.filter { $0.1 > $0.0 }
      .sorted { $0.0 < $1.0 }
    guard var current = parts.first else { return nil }
    var seconds = 0.0
    for part in parts.dropFirst() {
      if part.0 <= current.1 {
        current.1 = max(part.1, current.1)
      } else {
        seconds += current.1.timeIntervalSince(current.0)
        current = part
      }
    }
    seconds += current.1.timeIntervalSince(current.0)
    return seconds / 3600
  }
  public static func dailyWeights(_ entries: [WeightEntry], calendar: Calendar = .current)
    -> [WeightEntry]
  {
    Dictionary(grouping: entries, by: { calendar.startOfDay(for: $0.date) }).compactMap {
      _, items in items.max { $0.date < $1.date }
    }.sorted { $0.date < $1.date }
  }
  public static func weeklyAverage(
    _ entries: [WeightEntry], now: Date = Date(), calendar: Calendar = .current
  ) -> Double? {
    let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
    let daily = dailyWeights(
      entries.filter { $0.date >= start && $0.date <= now }, calendar: calendar)
    guard daily.count >= 3 else { return nil }
    return daily.reduce(0) { $0 + $1.kg } / Double(daily.count)
  }
}
public struct CoachReply: Codable {
  public var mode: String
  public var status: String
  public var snapshot_id: String
  public var expected_plan_version: String?
  public var message: String
  public var questions: [String]
  public var recommendations: [Recommendation]
  public var limitations: [String]
  public struct Recommendation: Codable {
    public var title: String
    public var action: String
    public var reason: String
    public var evidence_ids: [String]
    public var uncertainty: String
    public var requires_confirmation: Bool
  }
  public func validate(expectedSnapshot: String, allowedEvidence: Set<String>) throws {
    guard snapshot_id == expectedSnapshot else { throw CoachError.stale }
    guard ["daily", "training", "meal", "review"].contains(mode),
      ["proposal", "needs_input", "insufficient_data", "safety_pause"].contains(status),
      questions.count <= 3, recommendations.count <= 5
    else { throw CoachError.invalid }
    guard status != "safety_pause" || recommendations.isEmpty else { throw CoachError.invalid }
    guard status != "needs_input" || !questions.isEmpty else { throw CoachError.invalid }
    for r in recommendations {
      guard r.requires_confirmation, Set(r.evidence_ids).isSubset(of: allowedEvidence) else {
        throw CoachError.invalid
      }
    }
  }
}
public enum CoachError: Error { case stale, invalid, notConfigured, noConsent }
