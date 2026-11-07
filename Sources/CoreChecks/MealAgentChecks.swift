import FitnessCore
import Foundation

func runMealAgentChecks() throws {
  let json = #"{"request_id":"meal-test","title":"合成餐食","summary":"测试用","questions":[],"limitations":["合成范围"],"items":[{"name":"米饭","grams_low":100,"grams_high":200,"source":"USDA FDC test","note":"非真实餐食"}],"totals":{"energyKcal":{"low":100,"high":200},"proteinG":null,"carbsG":{"low":20,"high":40},"fatG":{"low":0,"high":2}},"requires_confirmation":true,"source":"AI 估计","catalog_version":"test"}"#
  let result = try JSONDecoder().decode(MealAgentResult.self, from: Data(json.utf8))
  try result.validate(expectedID: "meal-test")
  check(result.estimatedNutrition.energyValue == 150 && result.estimatedNutrition.proteinG == nil, "AI interval midpoint preserves unknown nutrients")
  check(result.estimatedNutrition.valid && result.estimatedNutrition.source == "AI 估计", "AI source is accepted only as an explicit estimate")
  check(result.reviewNote.contains("100.0–200.0 kcal") && result.reviewNote.contains("USDA FDC test"), "Saved analysis note retains original ranges and source")
  do { try result.validate(expectedID: "other"); fatalError("stale accepted") } catch { check(true, "Meal result must match the exact request") }
  for pair in [("\"requires_confirmation\":true", "\"requires_confirmation\":false"), ("\"low\":100,\"high\":200", "\"low\":300,\"high\":200"), ("\"source\":\"AI 估计\"", "\"source\":\"包装营养标签\"")] {
    let changed = try JSONDecoder().decode(MealAgentResult.self, from: Data(json.replacingOccurrences(of: pair.0, with: pair.1).utf8))
    do { try changed.validate(expectedID: "meal-test"); fatalError("invalid accepted") } catch { check(true, "Unsafe meal reply rejected: " + pair.0) }
  }
  check(MealAgentTransport.validEndpoint(URL(string: "https://example.com/private")!), "HTTPS service endpoint accepted")
  check(!MealAgentTransport.validEndpoint(URL(string: "http://example.com")!) && !MealAgentTransport.validEndpoint(URL(string: "https://user:pass@example.com")!) && !MealAgentTransport.validEndpoint(URL(string: "https://example.com/?token=secret")!), "Cleartext and embedded-credential endpoints rejected")
  var data = AppData(); data.meals = [MealEntry(title: "合成餐", nutrition: result.estimatedNutrition)]
  let report = FoodDiaryEngine.report(data)
  check(report.estimatedMeals == 1 && report.energy.value == 150 && report.protein.value == nil, "Daily diary marks AI estimates and preserves per-nutrient coverage")
  let restored = try BackupCodec.decode(BackupCodec.encode(FitnessBackup(records: data, photos: [:])))
  check(restored.records.meals[0].nutrition?.source == "AI 估计", "Complete backup retains AI estimate attribution")
}
