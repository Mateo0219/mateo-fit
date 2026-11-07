import FitnessCore
import Foundation

var passed = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
  guard condition() else { fatalError("FAIL: \(label)") }
  passed += 1
  print("PASS: \(label)")
}
let now = Date(timeIntervalSince1970: 1_800_000_000)
let a = WeightEntry(id: "a", date: now, kg: 119)
check(
  DataMath.mergedWeights([a], additions: [a], deleted: []).count == 1,
  "Health sample replay is idempotent")
check(
  DataMath.mergedWeights([a], additions: [a], deleted: ["a"]).isEmpty,
  "Deletion takes priority over replay")
check(
  !DataMath.validWeight(.nan) && !DataMath.validWeight(.infinity), "Reject non-finite measurements")
let sleep = [
  SleepEntry(id: "a", start: now, end: now.addingTimeInterval(7200), source: "watch"),
  SleepEntry(
    id: "b", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(10800),
    source: "other"),
]
check(
  DataMath.sleepHours(sleep, from: now, to: now.addingTimeInterval(14400)) == 3,
  "Overlap sleep is union, not sum")
check(
  DataMath.sleepHours(sleep, from: now.addingTimeInterval(3600), to: now.addingTimeInterval(7200))
    == 1, "Sleep clips window boundaries")
check(DataMath.sleepHours([], from: now, to: now) == nil, "Absent sleep is unknown, not zero")
check(
  DataMath.weeklyAverage([a, a, a], now: now) == nil,
  "Repeated same-day samples do not imply three days")
let days = (0..<3).map {
  WeightEntry(date: now.addingTimeInterval(Double(-$0) * 86400), kg: Double(119 - $0))
}
check(DataMath.weeklyAverage(days, now: now) == 118, "Daily weighted weekly average")
check(
  DataMath.weeklyAverage([a, WeightEntry(date: now.addingTimeInterval(86400), kg: 1)], now: now)
    == nil, "Future readings excluded")
check(
  MealEngine.suggest(pantry: ["egg"], excluded: [], maxMinutes: 30, reviewed: false).isEmpty,
  "No meals until restrictions reviewed")
let suggestions = MealEngine.suggest(
  pantry: ["egg", "rice", "tomato"], excluded: ["egg"], maxMinutes: 30, reviewed: true)
check(
  suggestions.allSatisfy { !$0.recipe.ingredients.contains("egg") }, "Explicit allergy exclusion")
check(
  MealEngine.suggest(
    pantry: ["egg", "rice", "tomato"], excluded: [], maxMinutes: 15, reviewed: true
  ).first?.ready == true, "Available meal sorted before missing items")
let data = AppData()
let bytes = try JSONEncoder().encode(data)
let decoded = try JSONDecoder().decode(AppData.self, from: bytes)
check(
  decoded.weights.isEmpty && decoded.meals.isEmpty,
  "Initial profile does not create fictional observations")
let json = """
  {"mode":"meal","status":"proposal","snapshot_id":"current","expected_plan_version":null,"message":"m","questions":[],"recommendations":[{"title":"t","action":"a","reason":"r","evidence_ids":["unknown"],"uncertainty":"u","requires_confirmation":true}],"limitations":[]}
  """
let reply = try JSONDecoder().decode(CoachReply.self, from: Data(json.utf8))
do {
  try reply.validate(expectedSnapshot: "current", allowedEvidence: [])
  fatalError("Accepted invented evidence")
} catch {
  passed += 1
  print("PASS: Invented evidence rejected")
}
do {
  try reply.validate(expectedSnapshot: "old", allowedEvidence: ["unknown"])
  fatalError("Accepted stale snapshot")
} catch {
  passed += 1
  print("PASS: Stale snapshot rejected")
}
print("\(passed) core checks passed")

var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(secondsFromGMT: 0)!
let iso = ISO8601DateFormatter()
func date(_ text: String) -> Date { iso.date(from: text)! }
let nightStart = date("2026-10-31T22:00:00Z")
let nightEnd = date("2026-11-01T06:00:00Z")
func segment(_ id: String, _ offset: Double, _ length: Double, _ stage: SleepStage, source: String = "Watch", watch: Bool = true) -> SleepEntry {
  SleepEntry(id: id, start: nightStart.addingTimeInterval(offset * 3600), end: nightStart.addingTimeInterval((offset + length) * 3600), source: source, stage: stage, sourceID: source, isWatch: watch)
}
let stages = [segment("bed", 0, 9, .inBed), segment("total", 0, 8, .unspecified),
  segment("core", 0, 3, .core), segment("deep", 3, 2, .deep), segment("rem", 5, 2, .rem), segment("awake", 7, 1, .awake)]
let normalized = HealthAnalytics.normalized(stages, from: nightStart, to: nightEnd)
check(normalized.filter { $0.stage.isAsleep }.reduce(0) { $0 + $1.seconds } == 7 * 3600, "Sleep stages override total summary; awake and in-bed excluded")
check(normalized.count == 4, "Detailed timeline merges without double counting")
let conflict = HealthAnalytics.normalized([segment("a", 0, 2, .core), segment("b", 1, 2, .awake)], from: nightStart, to: nightEnd)
check(conflict.filter { $0.stage == .conflict }.reduce(0) { $0 + $1.seconds } == 3600, "Conflicting awake and sleep intervals are surfaced, not counted")
let multi = stages + [segment("other", 0, 10, .unspecified, source: "Other app", watch: false)]
let nightReports = HealthAnalytics.sleep(multi, days: 7, now: date("2026-11-01T10:00:00Z"), calendar: utc)
check(nightReports.count == 1 && nightReports[0].sleepSeconds == 7 * 3600 && nightReports[0].sourceCount == 2, "One Watch source selected across midnight; other sources not added")
check(nightReports[0].day == date("2026-11-01T00:00:00Z"), "Overnight sleep assigned to its noon-ending sleep day")
let weeklyWeights = (0..<14).map { n in WeightEntry(id: "day-\(n)", date: date("2026-11-01T09:00:00Z").addingTimeInterval(Double(-n) * 86400), kg: n < 7 ? 118 : 120) }
let weightReport = HealthAnalytics.weight(weeklyWeights + [WeightEntry(date: date("2026-11-02T09:00:00Z"), kg: 110)], days: 7, now: date("2026-11-01T10:00:00Z"), calendar: utc)
check(weightReport.daily.count == 7 && weightReport.weekChange == -2 && weightReport.latest?.kg == 118, "Two seven-day means compare observed days and exclude future values")
check(HealthAnalytics.weight([weeklyWeights[0]], days: 7, now: date("2026-11-01T10:00:00Z"), calendar: utc).rangeChange == nil, "A single measurement cannot imply a trend")
let sameDay = weeklyWeights + [WeightEntry(date: date("2026-11-01T09:30:00Z"), kg: 119)]
check(HealthAnalytics.weight(sameDay, days: 7, now: date("2026-11-01T10:00:00Z"), calendar: utc).currentDays == 7, "Extra measurements do not overweight one day")
var la = Calendar(identifier: .gregorian)
la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
let dstSleep = SleepEntry(id: "dst", start: date("2026-11-01T07:00:00Z"), end: date("2026-11-01T16:00:00Z"), source: "Watch", stage: .core)
let dstReport = HealthAnalytics.sleep([dstSleep], days: 7, now: date("2026-11-01T19:00:00Z"), calendar: la)
check(dstReport.count == 1 && dstReport[0].sleepSeconds == 9 * 3600, "DST fall-back preserves elapsed sleep time")
let legacySleep = Data("{\"id\":\"old\",\"start\":0,\"end\":3600,\"source\":\"Watch\"}".utf8)
let oldSleep = try JSONDecoder().decode(SleepEntry.self, from: legacySleep)
check(oldSleep.resolvedStage == .unspecified, "Existing v1 sleep decodes without inventing a stage")
var legacyObject = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
legacyObject.removeValue(forKey: "healthAutoSyncEnabled")
let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
let legacy = try JSONDecoder().decode(AppData.self, from: legacyData)
check(legacy.healthAutoSyncEnabled == nil && legacy.profile.initialWeightKG == 119, "Existing app records remain decodable after optional sync setting")
let sevenNights = (0..<7).map { i in
  SleepEntry(id: "night-\(i)", start: nightStart.addingTimeInterval(Double(-i) * 86400), end: nightEnd.addingTimeInterval(Double(-i) * 86400), source: "Watch", stage: .core)
}
check(HealthAnalytics.sleep(sevenNights, days: 7, now: date("2026-11-01T23:00:00Z"), calendar: utc).count == 7, "Afternoon does not drop a completed night before new sleep arrives")
print("\(passed) total checks passed")

// Coach workflow regression checks, using only synthetic records.
let planningNow = date("2026-11-02T10:00:00Z")
var planning = AppData()
check(DailyPlanner.plan(planning, now: planningNow, calendar: utc).status == "setup", "No plan without confirmed conditions")
var coach = CoachState()
coach.preferences.confirmedAt = planningNow; coach.preferences.experience = "练过，正在恢复"
coach.preferences.equipment = "器械与哑铃"; coach.preferences.restrictions = "没有已知限制"
planning.coach = coach
check(DailyPlanner.plan(planning, now: planningNow, calendar: utc).status == "checkin", "Daily readiness is required")
var checkIn = DailyCheckIn(); checkIn.date = planningNow; checkIn.energy = "状态正常"
planning.coach?.checkIn = checkIn
check(DailyPlanner.plan(planning, now: planningNow, calendar: utc).exercises.count == 4, "Confirmed gym conditions yield an actionable local template")
planning.coach?.checkIn?.minutes = 20
check(DailyPlanner.plan(planning, now: planningNow, calendar: utc).exercises.count == 3, "Short session reduces the template")
planning.coach?.checkIn?.energy = "不适或困倦"
check(DailyPlanner.plan(planning, now: planningNow, calendar: utc).status == "pause", "Symptoms pause exercise suggestions")
planning.coach?.checkIn?.energy = "状态正常"
planning.coach?.checkIn?.date = planningNow.addingTimeInterval(-86400)
check(DailyPlanner.plan(planning, now: planningNow, calendar: utc).status == "checkin", "Yesterday's readiness never silently persists")
planning.coach?.checkIn?.date = planningNow
planning.workouts = [WorkoutEntry(date: planningNow.addingTimeInterval(-86400), name: "力量", sets: [SetEntry(exercise: "测试", kg: 0, reps: 8)], effort: "适中", minutes: 20)]
check(DailyPlanner.plan(planning, now: planningNow, calendar: utc).status == "rest", "Previous-day strength record triggers recovery day")
planning.workouts = []
check(!DailyPlanner.pantryFresh(planning, now: planningNow, calendar: utc), "Example pantry is not confirmed stock")
planning.pantryConfirmedAt = planningNow.addingTimeInterval(-86400)
check(!DailyPlanner.pantryFresh(planning, now: planningNow, calendar: utc), "Yesterday's pantry needs reconfirmation")
planning.coach?.feedback = [CoachFeedback(kind: "训练", reason: "时间不够", date: planningNow), CoachFeedback(kind: "训练", reason: "时间不够", date: planningNow)]
check(ReviewEngine.review(planning, now: planningNow, calendar: utc).proposed == nil, "Repeated taps on one day are not multi-day evidence")
planning.coach?.feedback.append(CoachFeedback(kind: "训练", reason: "时间不够", date: planningNow.addingTimeInterval(-86400)))
let review = ReviewEngine.review(planning, now: planningNow, calendar: utc)
let reread = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(planning))
check(ReviewEngine.review(reread, now: planningNow, calendar: utc).token == review.token, "Review token survives JSON round trip and unordered sets")
var adjusted = planning
try ReviewEngine.apply(review, to: &adjusted, now: planningNow, calendar: utc)
check(adjusted.coach?.revision == 1 && adjusted.coach?.preferences.workoutMinutes == 20 && adjusted.coach?.changes.count == 1, "Accepted proposal atomically records revision and evidence")
do { try ReviewEngine.apply(review, to: &adjusted, now: planningNow, calendar: utc); fatalError("Duplicate proposal accepted") } catch { check(true, "Duplicate proposal rejected") }
var changed = planning; changed.meals.append(MealEntry(title: "新记录"))
do { try ReviewEngine.apply(review, to: &changed, now: planningNow, calendar: utc); fatalError("Stale proposal accepted") } catch { check(true, "Changed evidence invalidates old proposal") }
var backupData = planning
let photoName = UUID().uuidString + ".image"
backupData.meals = [MealEntry(title: "测试餐", photoName: photoName)]
let backup = FitnessBackup(records: backupData, photos: [photoName: Data([1,2,3])])
let restored = try BackupCodec.decode(BackupCodec.encode(backup))
check(restored.photos[photoName] == Data([1,2,3]) && restored.records.meals[0].id == backupData.meals[0].id, "Complete backup preserves photo bytes and stable record IDs")
func rejectsBackup(_ value: FitnessBackup, _ label: String) {
  do { try BackupCodec.validate(value); fatalError("Invalid backup accepted: " + label) } catch { check(true, label) }
}
var broken = backup; broken.photos = [:]; rejectsBackup(broken, "Missing photo rejects incomplete backup")
broken = backup; broken.records.meals[0].photoName = "../secret.image"; rejectsBackup(broken, "Unsafe photo path rejected")
broken = backup; broken.records.meals.append(broken.records.meals[0]); rejectsBackup(broken, "Duplicate record IDs rejected")
broken = backup; broken.records.weights = [WeightEntry(kg: -1)]; rejectsBackup(broken, "Invalid imported measurement rejected")
var oldObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(planning)) as! [String: Any]
oldObject.removeValue(forKey: "coach"); oldObject.removeValue(forKey: "trash")
let oldRecords = try JSONDecoder().decode(AppData.self, from: JSONSerialization.data(withJSONObject: oldObject))
check(oldRecords.coach == nil && oldRecords.trash == nil, "Old installed app data loads without migration loss")
print("\(passed) total checks passed including coach and backups")

// Structured diet data uses entered values, never invented photo estimates.
var nutrition = MealNutrition()
nutrition.basis = "每 100 克"; nutrition.grams = 150; nutrition.energyUnit = "kJ"
nutrition.energyValue = 418.4; nutrition.proteinG = 8; nutrition.carbsG = 0
check(nutrition.valid && abs((nutrition.actualEnergyKcal ?? 0) - 150) < 0.001, "Per-100g and kJ convert to actual kcal once")
check(nutrition.actual(nutrition.proteinG) == 12, "Actual protein follows consumed grams")
var missingPortion = nutrition; missingPortion.grams = nil
check(!missingPortion.valid && missingPortion.actualEnergyKcal == nil, "Per-100g nutrition cannot imply intake without portion")
var diary = AppData()
diary.meals = [MealEntry(date: planningNow, title: "包装食物", nutrition: nutrition), MealEntry(date: planningNow, title: "没填数据的午餐")]
let partialDiary = FoodDiaryEngine.report(diary, now: planningNow, calendar: utc)
check(partialDiary.energy.coveredMeals == 1 && partialDiary.energy.totalMeals == 2 && abs((partialDiary.energy.value ?? 0) - 150) < 0.001, "Partial diary reports nutrient-specific coverage")
check(partialDiary.carbs.value == 0 && partialDiary.fat.value == nil, "Confirmed zero and unknown nutrients remain distinct")
check(!partialDiary.confirmedComplete, "Meal records alone do not imply a complete day")
diary.foodDiaryCompleteAt = planningNow
check(FoodDiaryEngine.report(diary, now: planningNow, calendar: utc).confirmedComplete, "Explicit daily completeness is respected")
check(!FoodDiaryEngine.report(diary, now: planningNow.addingTimeInterval(86400), calendar: utc).confirmedComplete, "Completeness expires on the next local day")
diary.meals.append(MealEntry(date: planningNow.addingTimeInterval(3600), title: "未来", nutrition: nutrition))
check(FoodDiaryEngine.report(diary, now: planningNow, calendar: utc).meals.count == 2, "Future-dated food is not counted as eaten now")
var estimate = nutrition; estimate.source = "自行估计"; diary.meals[0].nutrition = estimate
check(FoodDiaryEngine.report(diary, now: planningNow, calendar: utc).estimatedMeals == 1, "Estimated nutrient entries remain explicitly identified")
var wrongNutrition = nutrition; wrongNutrition.proteinG = -1
check(!wrongNutrition.valid, "Negative nutrition rejected")
var badDiary = FitnessBackup(records: diary, photos: [:]); badDiary.records.meals[0].nutrition = wrongNutrition
rejectsBackup(badDiary, "Backup import also validates nutrition")
let oldMeal = try JSONDecoder().decode(MealEntry.self, from: Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"date\":0,\"title\":\"旧餐\",\"note\":\"\",\"confirmed\":true}".utf8))
check(oldMeal.nutrition == nil, "Existing meal records decode without fabricated nutrient values")
print("\(passed) total checks passed including food diary")

try runTrainingChecks()
try runProgramChecks()
try runMealAgentChecks()
try runConversationChecks()
try runAssistantChecks()
try runPersonalAgentChecks()
try runGenerationChecks()
try runTrainingReviewChecks()
try runMemoryRelevanceChecks()
print("\(passed) total core checks passed")

// Explicit opt-in synthetic preview data. Never used in the shipping app.
if let index = CommandLine.arguments.firstIndex(of: "--fixture"), CommandLine.arguments.count > index + 1 {
  var fixture = AppData()
  let current = Date()
  fixture.weights = (0..<21).map { n in WeightEntry(date: current.addingTimeInterval(Double(-n) * 86400), kg: 118 + Double(n) * 0.07 + sin(Double(n)) * 0.25, source: "演示数据 · Xiaomi Home") }
  let todayStart = Calendar.current.startOfDay(for: current)
  for n in 0..<10 {
    let morning = Calendar.current.date(byAdding: .day, value: -n, to: todayStart)!.addingTimeInterval(7 * 3600)
    let base = morning.addingTimeInterval(-8 * 3600)
    let values: [(Double, Double, SleepStage)] = [(0, 2, .core), (2, 1.4, .deep), (3.4, 0.6, .rem), (4, 0.15, .awake), (4.15, 2, .core), (6.15, 1.25, .rem), (7.4, 0.6, .core)]
    for (i, value) in values.enumerated() {
      fixture.sleep.append(SleepEntry(id: "demo-\(n)-\(i)", start: base.addingTimeInterval(value.0 * 3600), end: base.addingTimeInterval((value.0 + value.1) * 3600), source: "演示数据 · Apple Watch", stage: value.2, sourceID: "fixture", isWatch: true))
    }
  }
  fixture.healthSyncedAt = current
  try JSONEncoder().encode(fixture).write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
}
