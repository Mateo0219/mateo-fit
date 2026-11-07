import Foundation
import FitnessCore

func runPersonalAgentChecks() throws {
  check(CoachReplyText.claimsUncommittedWrite("已记住，以后会注意。") && CoachReplyText.claimsUncommittedWrite("我已经帮你记住了。"), "Uncommitted write claims are recognized before display")
  check(!CoachReplyText.claimsUncommittedWrite("请核对这条记忆。") && !CoachReplyText.claimsUncommittedWrite("你已保存的记录显示今天练过。"), "Pending proposals and references to existing records are not success claims")
  let falseSuccess = CoachTurn(text: "记住这个偏好", reply: "已记住。", actions: [])
  check(CoachReplyText.body(falseSuccess).contains("尚未保存"), "Historical model-only success cannot impersonate a saved receipt")
  let synthetic = AppData()
  let viewBundle = PersonalAgentContext.build(synthetic, text: "今天怎么练", health: false, memory: false)
  let replyRaw: [String:Any] = ["contract_version":2, "request_id":"test", "snapshot_id":viewBundle.snapshot.snapshot_id, "expected_plan_version":viewBundle.snapshot.expected_plan_version, "status":"needs_input", "message":"今天有多少时间？", "questions":["今天有多少时间？"], "cards":[["action":"training", "title":"查看训练", "detail":"请在完整训练模块中确认各种状态。", "evidence_ids":[String](), "candidate_id":NSNull()]], "operations":[[String:String]]()]
  let viewResponse = try JSONDecoder().decode(CoachAssistantResponse.self, from: JSONSerialization.data(withJSONObject: replyRaw))
  var display = CoachTurn(text: "今天怎么练", reply: viewResponse.message, actions: [])
  display.exchange = CoachExchange(bundle: viewBundle, response: viewResponse)
  check(CoachReplyText.questions(display).isEmpty && CoachReplyText.cards(display).isEmpty, "Repeated questions and navigation-only explanation are absent from the actual reply presentation")
  check(CoachReplyText.copy(display, data: synthetic) == "今天有多少时间？", "Copying a reply uses the same concise text as the chat")
  let now = Date()
  func reject(_ label: String, _ action: () throws -> Void) {
    do { try action(); fatalError("Accepted: " + label) } catch { check(true, label) }
  }
  func stage(_ input: AgentOperationInput, _ data: inout AppData, at date: Date = Date()) throws -> UUID {
    if data.personalAgent == nil { data.personalAgent = PersonalAgentState() }
    var turn = CoachTurn(text: input.source_text, reply: "待核对", actions: [])
    turn.date = date; turn.threadID = data.activeCoachThreadID ?? CoachThreads.legacyID
    let op = try AgentOperations.stage(input, turn: turn, data: data, now: date)
    turn.agentOperationIDs = [op.id]; CoachThreads.record(turn, into: &data)
    data.personalAgent?.operations.append(op)
    return op.id
  }
  var data = AppData()
  let before = AssistantContext.fingerprint(data)
  data.personalAgent = PersonalAgentState()
  check(before == AssistantContext.fingerprint(data), "Empty agent state does not expire the first proposal")
  let text = "以后回答简短点"
  let input = MemoryRules.localInput(text)!
  var memoryTurn = CoachTurn(text: text, reply: "", actions: []); memoryTurn.threadID = CoachThreads.legacyID
  check(MemoryRules.canAutoRemember(input, data: data, turn: memoryTurn), "Explicit ordinary preference qualifies for reversible automatic memory")
  check(MemoryRules.localInput("例如“我喜欢跑步”") == nil && MemoryRules.localInput("我膝盖疼，记住") == nil && MemoryRules.localInput("今天很累") == nil, "Quotes, health restrictions and temporary fatigue are not auto memories")
  check(MemoryRules.localInput("记住我体重100kg") == nil && MemoryRules.localInput("记住我今天吃了鸡蛋") == nil, "Measurements and actual meals are not automatically stored as stable preferences")
  let memoryOp = try stage(input, &data, at: now)
  check(data.personalAgent?.memories.isEmpty == true, "A proposal alone does not save memory")
  try AgentOperations.commit(memoryOp, data: &data, now: now)
  check(data.personalAgent?.memories.first?.content == text, "Confirmed operation saves sourced memory")
  reject("Duplicate memory confirmation is rejected") { try AgentOperations.commit(memoryOp, data: &data, now: now) }
  let memory = data.personalAgent!.memories[0]
  let hidden = PersonalAgentContext.build(data, text: "今天怎么练", health: false, memory: false, now: now)
  check(hidden.snapshot.facts.allSatisfy { $0.id == "public.clock" } && hidden.snapshot.expected_plan_version == "withheld", "Both summary scopes denied expose only device clock")
  let allowed = PersonalAgentContext.build(data, text: "今天怎么练", health: false, memory: true, now: now)
  check(allowed.snapshot.facts.contains { $0.id == "memory." + memory.id.uuidString }, "Memory scope can be enabled independently of health")
  var expired = data; expired.personalAgent?.memories[0].expiresAt = now.addingTimeInterval(-1)
  check(!PersonalAgentContext.build(expired, text: "继续", health: false, memory: true, now: now).snapshot.facts.contains { $0.id.hasPrefix("memory.") }, "Expired memory never enters current context")
  var conflict = input; conflict.source_text = "以后回答详细点"; conflict.content = conflict.source_text
  check(!MemoryRules.canAutoRemember(conflict, data: data, turn: CoachTurn(text: conflict.source_text, reply: "", actions: [])), "Conflicting ordinary preferences require review")
  var edit = AgentOperationInput(kind: "updateMemory", sourceText: "以后回答详细点"); edit.content = edit.source_text; edit.topic = "reply_style"; edit.target_id = "memory." + memory.id.uuidString
  let edited = try stage(edit, &data, at: now)
  try AgentOperations.commit(edited, data: &data, now: now)
  check(data.personalAgent?.memories[0].revision == 2 && data.personalAgent?.memories[0].content == edit.content, "Memory correction retains identity and increments revision")
  var forget = AgentOperationInput(kind: "forgetMemory", sourceText: "忘掉这条"); forget.target_id = edit.target_id
  let forgetting = try stage(forget, &data, at: now)
  try AgentOperations.commit(forgetting, data: &data, now: now)
  check(data.personalAgent?.memories.isEmpty == true && !data.personalAgent!.forgotten.isEmpty, "Forgetting removes retrievable memory and retains a content-free tombstone")
  check(PersonalAgentContext.history(data, health: true, memory: true).isEmpty, "Forgotten memory cannot echo back through old conversation history")
  try AgentOperations.undo(forgetting, data: &data, now: now)
  check(data.personalAgent?.memories.count == 1, "Explicit undo can restore a forgotten memory")
  data.personalAgent?.memories[0].revision += 1
  reject("Undo refuses to overwrite a later memory edit") { try AgentOperations.undo(edited, data: &data, now: now) }
  var today = AppData()
  var partial = AgentOperationInput(kind: "updateToday", sourceText: "今天只有四十分钟"); partial.minutes = 40
  let partialID = try stage(partial, &today, at: now)
  try AgentOperations.commit(partialID, data: &today, now: now)
  check(today.coach?.checkIn?.confirmedFields == ["minutes"] && today.coach?.checkIn?.context == "未确认" && today.coach?.checkIn?.energy == "未确认", "A time-only patch never confirms default location or energy")
  let partialContext = PersonalAgentContext.build(today, text: "怎么练", health: true, memory: false, now: now)
  check(partialContext.snapshot.facts.first { $0.id == "today" }?.summary.contains("地点 未知") == true, "Partial conditions expose unknown values explicitly")
  let nextDay = now.addingTimeInterval(86400)
  check(PersonalAgentContext.build(today, text: "怎么练", health: true, memory: false, now: nextDay).snapshot.facts.first { $0.id == "today" }?.quality == "未知", "Yesterday's partial condition expires without implying recovery")
  var log = AgentOperationInput(kind: "logSet", sourceText: "我想练推胸20kg，10次"); log.exercise = "推胸"; log.kg = 20; log.reps = 10
  reject("Training intent cannot become completed sets") { _ = try stage(log, &today, at: now) }
  log.source_text = "刚做了推胸20kg，10次，2组"; log.count = 2
  let logged = try stage(log, &today, at: now)
  check(today.draft == nil && today.workouts.isEmpty, "Workout proposal does not affect actual totals")
  try AgentOperations.commit(logged, data: &today, now: now)
  check(today.draft?.sets.count == 2 && today.workouts.isEmpty, "Actual set confirmation saves draft sets without finishing the workout")
  let firstSet = today.draft!.sets[0].id
  var heldMeal = AgentOperationInput(kind: "logMeal", sourceText: "今天吃了米饭"); heldMeal.content = "米饭"
  let heldID = try stage(heldMeal, &today, at: now)
  var correct = AgentOperationInput(kind: "correctSet", sourceText: "刚才那组是22kg"); correct.kg = 22; correct.target_id = "set." + firstSet.uuidString
  let correction = try stage(correct, &today, at: now)
  try AgentOperations.commit(correction, data: &today, now: now)
  check(today.draft?.sets.count == 2 && today.draft?.sets[0].id == firstSet && today.draft?.sets[0].kg == 22, "Correction updates the exact existing set without duplication")
  try AgentOperations.undo(correction, data: &today, now: now)
  check(today.draft?.sets[0].kg == 20, "Workout correction undo restores the previous measurement")
  check(!AgentOperations.fresh(today.personalAgent!.operations.first { $0.id == heldID }!, data: today, now: now), "Undo cannot revive a previously stale pending proposal even when record values match again")
  let finish = AgentOperationInput(kind: "finishWorkout", sourceText: "训练结束了")
  let finishID = try stage(finish, &today, at: now)
  try AgentOperations.commit(finishID, data: &today, now: now)
  check(today.draft == nil && today.workouts.count == 1 && today.workouts[0].sets.count == 2, "Finishing archives only real sets exactly once")
  var meal = AgentOperationInput(kind: "logMeal", sourceText: "昨天吃了鸡蛋两个"); meal.content = "鸡蛋两个"
  let mealID = try stage(meal, &today, at: now)
  check(today.meals.isEmpty, "Unconfirmed meal is absent from official diary")
  try AgentOperations.commit(mealID, data: &today, now: now)
  check(today.meals.count == 1 && today.meals[0].nutrition == nil && !Calendar.current.isDate(today.meals[0].date, inSameDayAs: now), "Meal confirmation retains date and leaves missing nutrition unknown")
  var estimate = MealNutrition(); estimate.energyValue = 200; today.meals[0].nutrition = estimate
  var mealEdit = AgentOperationInput(kind: "correctMeal", sourceText: "其实吃了鸡蛋一个"); mealEdit.content = "鸡蛋一个"; mealEdit.target_id = "meal." + today.meals[0].id.uuidString
  let mealEditID = try stage(mealEdit, &today, at: now)
  let mealRecordID = today.meals[0].id
  try AgentOperations.commit(mealEditID, data: &today, now: now)
  check(today.meals[0].id == mealRecordID && today.meals[0].nutrition == nil && today.meals[0].title == "鸡蛋一个", "Meal correction invalidates old estimate and preserves record identity")
  let unrelated = MealEntry(title: "其他入口保存的独立记录")
  today.meals.append(unrelated)
  try AgentOperations.undo(mealEditID, data: &today, now: now)
  check(today.meals.contains { $0.id == unrelated.id } && today.meals.first { $0.id == mealRecordID }?.title == "鸡蛋两个", "Undo changes only its own record and preserves unrelated later records")
  var stale = meal; stale.source_text = "今天吃了米饭"; stale.content = "米饭"
  let staleID = try stage(stale, &today, at: now)
  today.profile.excludedFoods.insert("egg")
  reject("Changed safety context invalidates a pending write") { try AgentOperations.commit(staleID, data: &today, now: now) }
  let staleOp = today.personalAgent!.operations.first { $0.id == staleID }!
  check(!AgentOperations.fresh(staleOp, data: today, now: nextDay), "Prior-day proposals cannot be confirmed after restart")
  let encoded = try BackupCodec.encode(FitnessBackup(records: today, photos: [:]))
  let restored = try BackupCodec.decode(encoded).records
  check(restored.personalAgent?.operations.last?.status == "pending" && restored.personalAgent?.receipts.count == today.personalAgent?.receipts.count, "Backup round trip retains pending operations, receipts and undo versions")
  var noMemory = AppData(); CoachThreads.prepare(&noMemory); noMemory.coachThreads?[0].noLongTermMemory = true
  check(!MemoryRules.canAutoRemember(input, data: noMemory, turn: memoryTurn), "A no-memory conversation cannot automatically learn")
  var invalid = input; invalid.kg = .nan
  check(!invalid.valid, "Non-finite model numbers are rejected")
  var fabricated = log; fabricated.kg = 999
  reject("Model-invented numeric fields fail source grounding") { _ = try stage(fabricated, &today, at: now) }

  var trained = AppData(); var prefs = CoachPreferences(); prefs.confirmedAt = now; prefs.experience = "练过"; prefs.equipment = "器械与哑铃"; prefs.restrictions = "没有已知限制"; prefs.trainingWeekdays = Set(1...7)
  var state = CoachState(); state.preferences = prefs; var condition = DailyCheckIn(); condition.date = now; condition.energy = "状态正常"; condition.minutes = 60; state.checkIn = condition; trained.coach = state
  var draft = WorkoutDraft(); let planned = PlannedExercise("row", sets: 3); draft.planned = [planned]; var done = SetEntry(exercise: "坐姿器械划船", kg: 20, reps: 10); done.exerciseID = "row"; done.setKind = "工作组"; draft.sets = [done]; trained.draft = draft
  var substitute = AgentOperationInput(kind: "substituteExercise", sourceText: "划船器械被占了，换个动作"); substitute.target_id = "planned." + planned.id.uuidString; substitute.exercise_id = "dbrow"
  let subID = try stage(substitute, &trained, at: now)
  try AgentOperations.commit(subID, data: &trained, now: now)
  check(trained.draft?.sets.first?.id == done.id && trained.draft?.planned?.first?.sets == 2 && trained.draft?.planned?.first?.exerciseID == "dbrow", "Equipment substitution preserves completed sets and replaces only remaining sets")
  var unknownTarget = substitute; unknownTarget.target_id = "planned." + UUID().uuidString
  reject("Invented operation targets are rejected") { _ = try stage(unknownTarget, &trained, at: now) }
  if let i = CommandLine.arguments.firstIndex(of: "--memory-fixture"), CommandLine.arguments.count > i + 1 {
    var preview = AppData()
    let first = MemoryRules.localInput("合成测试：我不喜欢甜食")!
    let id = try stage(first, &preview)
    try AgentOperations.commit(id, data: &preview)
    preview.conversation?[0].reply = "已记住。"; preview.conversation?[0].origin = "本机结果"
    let second = MemoryRules.localInput("合成测试：我喜欢吃米饭")!
    _ = try stage(second, &preview)
    preview.conversation?[1].reply = "请核对这条记忆。"
    try JSONEncoder().encode(preview).write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
  }
  if let i = CommandLine.arguments.firstIndex(of: "--personal-agent-fixture"), CommandLine.arguments.count > i + 1 {
    var preview = AppData()
    var previewMeal = AgentOperationInput(kind: "logMeal", sourceText: "合成测试：今天吃了鸡蛋两个，请帮我记录。")
    previewMeal.content = "鸡蛋两个"
    _ = try stage(previewMeal, &preview)
    preview.personalAgent?.memories.append(PersonalMemory(content: "以后回答简短点", topic: "reply_style", sourceText: "合成测试偏好", sourceTurnID: nil))
    // Adding the independent sample memory precedes the pending proposal's final snapshot.
    let fingerprint = AssistantContext.fingerprint(preview)
    preview.personalAgent?.operations[0].fingerprint = fingerprint
    try JSONEncoder().encode(preview).write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
  }
}
