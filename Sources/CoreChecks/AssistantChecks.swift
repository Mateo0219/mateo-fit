import Foundation
import FitnessCore

func runAssistantChecks() throws {
  let now = Date()
  var data = AppData()
  var prefs = CoachPreferences(); prefs.confirmedAt = now; prefs.experience = "练过，正在恢复"; prefs.equipment = "器械与哑铃"; prefs.restrictions = "没有已知限制"; prefs.trainingWeekdays = Set(1...7); prefs.workoutMinutes = 60
  var state = CoachState(); state.preferences = prefs
  var checkIn = DailyCheckIn(); checkIn.energy = "状态正常"; checkIn.minutes = 60; state.checkIn = checkIn
  data.coach = state
  data.draft = WorkoutDraft(); data.draft?.planned = [PlannedExercise("press")]
  data.draft?.sets = [SetEntry(exercise: "推胸", kg: 10, reps: 8)]
  data.weights = [WeightEntry(kg: 117.8, source: "synthetic scale")]
  let denied = AssistantContext.build(data, text: "45分钟", includeHealth: false, now: now)
  check(denied.snapshot.facts.isEmpty && denied.snapshot.candidates.isEmpty && denied.snapshot.expected_plan_version == "withheld", "No summary consent sends no facts, plans or proposals")
  let bundle = AssistantContext.build(data, text: "今天只有45分钟", includeHealth: true, now: now)
  check(UUID(uuidString: bundle.snapshot.snapshot_id) != nil && !bundle.snapshot.snapshot_id.contains("117"), "Snapshot identity is opaque, not reversible record data")
  check(bundle.snapshot.facts.allSatisfy { $0.revision.count == 64 && !$0.source_id.isEmpty && !$0.unit.isEmpty && !$0.quality.isEmpty }, "Every summary fact retains revision, unit, provenance and quality")
  check(bundle.snapshot.facts.first { $0.id == "profile" }?.quality == "未知", "Seeded profile is not falsely sent as confirmed")
  check(bundle.snapshot.facts.first { $0.id == "food.today" }?.summary.contains("未知") == true, "Missing nutrition remains unknown in model context")
  check(bundle.snapshot.facts.filter { $0.id.hasPrefix("recipe.") }.isEmpty, "Unconfirmed allergies or pantry withholds actionable recipes")
  let candidate = bundle.snapshot.candidates.first!
  let raw: [String: Any] = ["request_id":"synthetic", "snapshot_id":bundle.snapshot.snapshot_id, "expected_plan_version":bundle.snapshot.expected_plan_version, "status":"proposal", "message":"合成回复，未写入", "questions":[String](), "cards":[["action":candidate.action.rawValue,"title":"45分钟调整","detail":"保留完成组数","evidence_ids":candidate.evidence_ids,"candidate_id":candidate.id]]]
  let reply = try JSONDecoder().decode(CoachAssistantResponse.self, from: JSONSerialization.data(withJSONObject: raw))
  try reply.validate(requestID: "synthetic", snapshot: bundle.snapshot)
  var turn = CoachTurn(text: "今天只有45分钟", reply: reply.message, actions: [.adjustToday])
  turn.exchange = CoachExchange(bundle: bundle, response: reply)
  data.conversation = [turn]
  check(AssistantContext.isFresh(turn.exchange!, data: data, now: now), "Adding a conversation cannot invalidate its own proposal")
  data.homeComposer = HomeComposerDraft(); data.homeComposer?.text = "继续追问"
  check(AssistantContext.isFresh(turn.exchange!, data: data, now: now), "Unsent composer changes do not alter health snapshot")
  check(AssistantContext.history([turn], includeHealth: false).isEmpty, "Withdrawing consent also excludes prior health-bearing AI turns")
  check(AssistantContext.history([turn], includeHealth: true).count == 2, "Consented follow-up retains prior request and reply")
  var changed = data; changed.profile.excludedFoods.insert("egg")
  check(!AssistantContext.isFresh(turn.exchange!, data: changed, now: now), "Changed allergies invalidate old proposals")
  changed = data; changed.weights.append(WeightEntry(kg: 118))
  check(!AssistantContext.isFresh(turn.exchange!, data: changed, now: now), "New health evidence invalidates stale proposals")
  check(!AssistantContext.isFresh(turn.exchange!, data: data, now: now.addingTimeInterval(86401)), "Previous-day proposals cannot be confirmed")
  var pausedData = data
  var pauseRaw = raw; pauseRaw["status"] = "safety_pause"; pauseRaw["cards"] = [[String:String]]()
  let pauseReply = try JSONDecoder().decode(CoachAssistantResponse.self, from: JSONSerialization.data(withJSONObject: pauseRaw))
  var pauseTurn = CoachTurn(text: "合成头晕测试", reply: "先暂停", actions: [])
  pauseTurn.exchange = CoachExchange(bundle: bundle, response: pauseReply)
  pausedData.conversation?.append(pauseTurn)
  check(!AssistantContext.isFresh(turn.exchange!, data: pausedData, now: now) && AssistantContext.build(pausedData, text: "45分钟", includeHealth: true).proposals.isEmpty, "Reported safety pause blocks earlier and new training proposals until fresh check-in")
  let completed = data.draft!.sets[0].id
  try AssistantTransactions.confirm(turnID: turn.id, candidateID: candidate.id, data: &data, now: now)
  check(data.coach?.checkIn?.minutes == 45 && data.draft?.sets.first?.id == completed && data.draft?.targets?.isEmpty == true, "Confirmed adjustment preserves actual sets and clears old targets")
  check(data.coach?.preferences.workoutMinutes == 60 && data.workouts.isEmpty, "Daily adjustment neither changes long-term preference nor completes a workout")
  check(data.conversation?.first?.outcome != nil && data.homeCommitIDs?.contains(candidate.id) == true, "Confirmation records its result and idempotency key")
  do { try AssistantTransactions.confirm(turnID: turn.id, candidateID: candidate.id, data: &data, now: now); fatalError("duplicate") } catch { check(true, "Duplicate confirmation is rejected") }
  let restored = try BackupCodec.decode(BackupCodec.encode(FitnessBackup(records: data, photos: [:])))
  check(restored.records.conversation?.first?.exchange?.appliedIDs == [candidate.id], "Backup preserves applied cards and confirmation ledger")
  var bad = raw; bad["cards"] = [["action":"adjustToday","title":"bad","detail":"bad","evidence_ids":["invented"],"candidate_id":"invented"]]
  do {
    let reply = try JSONDecoder().decode(CoachAssistantResponse.self, from: JSONSerialization.data(withJSONObject: bad))
    try reply.validate(requestID: "synthetic", snapshot: bundle.snapshot); fatalError("invalid evidence")
  } catch { check(true, "Client rejects invented evidence or unregistered proposals") }
  var mealDraft = HomeMealDraft(description: "合成餐食", photo: Data([1,2,3]))
  var estimates = MealNutrition(); estimates.source = "AI 估计"; estimates.energyValue = 100
  mealDraft.nutrition = estimates; mealDraft.analysisInput = mealDraft.description
  mealDraft.description = "更正实际份量"; mealDraft.invalidateEstimate()
  check(mealDraft.nutrition == nil && mealDraft.analysisInput == nil && mealDraft.photo == Data([1,2,3]), "Food edits invalidate AI estimates while retaining the original photo")
  var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppData())) as! [String: Any]
  for key in ["homeComposer", "pendingHomeMeal", "homeCommitIDs", "conversation"] { legacy.removeValue(forKey: key) }
  let legacyDecoded = try JSONDecoder().decode(AppData.self, from: JSONSerialization.data(withJSONObject: legacy))
  check(legacyDecoded.pendingHomeMeal == nil, "Pre-chat records decode with optional new fields")
  if let index = CommandLine.arguments.firstIndex(of: "--assistant-fixture"), CommandLine.arguments.count > index + 1 {
    var fixture = data; fixture.conversation = [turn]; fixture.homeCommitIDs = nil
    fixture.profile.confirmedAt = now; fixture.profile.allergiesReviewed = true; fixture.pantryConfirmedAt = now
    let fixtureBundle = AssistantContext.build(fixture, text: "今天只有45分钟", includeHealth: true)
    try JSONEncoder().encode(fixture).write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    try JSONEncoder().encode(fixtureBundle.snapshot).write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1] + ".snapshot.json"))
  }
}
