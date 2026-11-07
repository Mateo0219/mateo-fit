import Foundation
import FitnessCore

func runTrainingReviewChecks() throws {
  let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
  func reject(_ label: String, _ action: () throws -> Void) {
    do { try action(); fatalError("Accepted: " + label) } catch { check(true, label) }
  }
  func ready() -> AppData {
    var data = AppData(), coach = CoachState(), condition = DailyCheckIn()
    coach.preferences.confirmedAt = now; coach.preferences.experience = "练过"; coach.preferences.equipment = "器械与哑铃"
    coach.preferences.restrictions = "没有已知限制"; coach.preferences.trainingWeekdays = Set(1...7)
    condition.date = now; condition.energy = "状态正常"; condition.minutes = 60; coach.checkIn = condition; data.coach = coach
    var profile = ExerciseProfile(exerciseID: "row"); profile.equipmentLabel = "合成器械"; profile.availableLoads = [10, 20]; profile.workSets = 3
    var state = TrainingState(); state.profiles = [profile]; data.training = state
    return data
  }
  func set(_ exercise: String = "row", kind: String? = "工作组", profile: UUID? = nil) -> SetEntry {
    var entry = SetEntry(exercise: TrainingLibrary.guide(exercise)!.name, kg: 10, reps: 10)
    entry.exerciseID = exercise; entry.setKind = kind; entry.profileID = profile; entry.form = "标准完成"; entry.date = now
    return entry
  }
  func operation(_ input: AgentOperationInput, data: AppData, at date: Date = Date()) throws -> AgentOperation {
    var turn = CoachTurn(text: input.source_text, reply: "待确认", actions: []); turn.date = date
    return try AgentOperations.stage(input, turn: turn, data: data, now: date)
  }
  func apply(_ input: AgentOperationInput, to data: inout AppData, at date: Date) throws {
    if data.personalAgent == nil { data.personalAgent = PersonalAgentState() }
    let op = try operation(input, data: data, at: date)
    data.personalAgent?.operations.append(op)
    try AgentOperations.commit(op.id, data: &data, now: date)
  }
  func pauseTurn(_ data: AppData) throws -> CoachTurn {
    let bundle = AssistantContext.build(data, text: "合成头晕", includeHealth: true, now: now)
    let raw: [String: Any] = ["request_id": "synthetic-pause", "snapshot_id": bundle.snapshot.snapshot_id,
      "expected_plan_version": bundle.snapshot.expected_plan_version, "status": "safety_pause", "message": "暂停训练建议", "questions": [String](), "cards": [[String: String]]()]
    let response = try JSONDecoder().decode(CoachAssistantResponse.self, from: JSONSerialization.data(withJSONObject: raw))
    var turn = CoachTurn(text: "合成头晕", reply: "暂停训练建议", actions: [])
    turn.date = now.addingTimeInterval(-60); turn.exchange = CoachExchange(bundle: bundle, response: response)
    return turn
  }

  var safety = ready()
  let original = safety, profileID = safety.training!.profiles[0].id
  var draft = WorkoutDraft(); draft.started = now; draft.planned = [PlannedExercise("row", sets: 3)]; draft.sets = [set()]; safety.draft = draft
  let oldProposal = TrainingProgression.proposal(safety, profileID: profileID, now: now)
  safety.conversation = [try pauseTurn(safety)]
  // Simulate old storage: a later time-only check-in exists, with no separate safety field.
  let oldJSON = try JSONEncoder().encode(safety)
  safety = try JSONDecoder().decode(AppData.self, from: oldJSON)
  check(safety.trainingSafety == nil && TrainingSafety.isPaused(safety), "F1 legacy later check-in does not prove recovery")
  check(DailyPlanner.plan(safety, now: now).status == "pause" && TrainingProgression.proposal(safety, profileID: profileID, now: now).target == nil, "F1 native plan and ability recommendation share the legacy pause")
  reject("F1 accepting an earlier ability suggestion is blocked after pause") { try TrainingProgression.accept(oldProposal, into: &safety, now: now) }
  check(TrainingSafety.migrateLegacy(&safety), "F1 legacy safety response migrates to independent state")
  let persistedPause = safety.trainingSafety
  safety.conversation = []
  safety = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(safety))
  check(safety.trainingSafety == persistedPause && TrainingSafety.isPaused(safety), "F1 deleting chat and restarting preserves migrated safety pause")
  var minutes = AgentOperationInput(kind: "updateToday", sourceText: "今天40分钟"); minutes.minutes = 40
  try apply(minutes, to: &safety, at: now.addingTimeInterval(1))
  check(safety.coach?.checkIn?.minutes == 40 && TrainingSafety.isPaused(safety) && safety.draft?.sets.first?.id == draft.sets[0].id, "F1 minutes-only update preserves pause and completed history")
  var place = AgentOperationInput(kind: "updateToday", sourceText: "今天在家"); place.context = "在家"
  try apply(place, to: &safety, at: now.addingTimeInterval(2))
  check(TrainingSafety.isPaused(safety) && DailyPlanner.plan(safety, now: now.addingTimeInterval(2)).exercises.isEmpty, "F1 location-only update does not release training")
  var normal = original.coach!.checkIn!; normal.date = now.addingTimeInterval(3)
  AssistantTransactions.applyDailyCheck(normal, to: &safety, now: normal.date)
  check(TrainingSafety.isPaused(safety), "F1 ordinary normal check-in cannot silently acknowledge recovery")
  let undo = AgentUndo.capture(original, scope: "training")
  undo.restore(&safety)
  check(TrainingSafety.isPaused(safety), "F1 undoing training data cannot erase the independent safety state")
  var restoredOld = original
  TrainingSafety.preservePause(from: safety, in: &restoredOld)
  check(TrainingSafety.isPaused(restoredOld), "F1 restoring an older backup cannot clear a current pause")
  let backedUp = try BackupCodec.decode(BackupCodec.encode(FitnessBackup(records: safety, photos: [:]))).records
  check(TrainingSafety.isPaused(backedUp), "F1 full backup round trip retains safety state")
  var incomplete = normal; incomplete.confirmedFields = ["minutes"]
  reject("F1 recovery requires explicit complete current conditions") { try TrainingSafety.confirmRecovery(incomplete, in: &safety, now: normal.date) }
  normal.confirmedFields = ["energy", "context", "minutes"]
  try TrainingSafety.confirmRecovery(normal, in: &safety, now: normal.date)
  check(!TrainingSafety.isPaused(safety) && DailyPlanner.plan(safety, now: normal.date).status == "ready", "F1 explicit recovery re-enables native planning")
  safety.conversation = [try pauseTurn(safety)]
  check(!TrainingSafety.migrateLegacy(&safety) && !TrainingSafety.isPaused(safety), "F1 retained old safety messages do not override explicit recovery")
  TrainingSafety.pause(&safety, at: normal.date.addingTimeInterval(1))
  safety = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(safety))
  check(TrainingSafety.isPaused(safety), "F1 a new pause after recovery survives restart")

  var workloadData = ready()
  for completed in [0, 1, 3] {
    var d = WorkoutDraft(); let item = PlannedExercise("row", sets: 3); d.planned = [item]
    d.sets = (0..<completed).map { _ in set() }
    let ids = d.sets.map(\.id)
    if completed == 3 {
      reject("F2 no substitute volume after all work sets are done") { _ = try TrainingWorkload.replacement(item, with: "dbrow", draft: d, state: workloadData.training) }
    } else {
      let replacement = try TrainingWorkload.replacement(item, with: "dbrow", draft: d, state: workloadData.training)
      check(replacement.sets + completed == 3 && d.sets.map(\.id) == ids, "F2 replacement preserves total budget and record IDs with \(completed) completed sets")
    }
  }
  var d = WorkoutDraft(); let row = PlannedExercise("row", sets: 3); d.planned = [row]
  d.sets = [set(kind: "热身组"), set(kind: "热身组"), set(kind: "热身组"), set(kind: nil)]
  let warmupIDs = d.sets.map(\.id)
  workloadData.draft = d
  var substitution = AgentOperationInput(kind: "substituteExercise", sourceText: "划船器械被占了，换个动作")
  substitution.target_id = "planned." + row.id.uuidString; substitution.exercise_id = "dbrow"
  let preview = try operation(substitution, data: workloadData, at: now)
  check(preview.summary.contains("剩余 3 组"), "F3 preview does not deduct warmup or untyped sets")
  try apply(substitution, to: &workloadData, at: now)
  check(workloadData.draft?.planned?.first?.sets == 3 && workloadData.draft?.sets.map(\.id) == warmupIDs, "F3 commit preserves all work volume when only warmups exist")
  var left = ExerciseProfile(exerciseID: "dbrow"); left.side = "左侧"; left.equipmentLabel = "合成哑铃"; left.availableLoads = [5, 10]
  var right = left; right.id = UUID(); right.side = "右侧"
  workloadData.training?.profiles += [left, right]
  d = workloadData.draft!; let unilateral = d.planned![0]
  d.sets.append(set("dbrow", profile: left.id))
  let onlyLeft = TrainingWorkload.progress(unilateral, draft: d, state: workloadData.training)
  check(onlyLeft.completed == 0 && onlyLeft.hasUnevenSides && onlyLeft.left == 1 && onlyLeft.right == 0, "F3 left-only work cannot count as a completed bilateral pair")
  reject("F3 asymmetric sides cannot trigger a volume-changing substitution") { _ = try TrainingWorkload.replacement(unilateral, with: "row", draft: d, state: workloadData.training) }
  d.sets.append(set("dbrow", profile: right.id))
  let afterPair = try TrainingWorkload.replacement(unilateral, with: "row", draft: d, state: workloadData.training)
  check(afterPair.sets == 2 && d.sets.count == warmupIDs.count + 2, "F3 one completed left-right pair deducts one prescribed set per side")
  // Switch away and back twice: original completed sets must never be charged again.
  d = WorkoutDraft(); d.planned = [row]; d.sets = [set()]
  let first = try TrainingWorkload.replacement(row, with: "dbrow", draft: d, state: workloadData.training)
  d.planned = [first]
  let second = try TrainingWorkload.replacement(first, with: "row", draft: d, state: workloadData.training)
  d.planned = [second]
  let third = try TrainingWorkload.replacement(second, with: "dbrow", draft: d, state: workloadData.training)
  check(first.sets == 2 && second.sets == 2 && third.sets == 2, "F2/F3 repeated substitutions neither add volume nor deduct old completed sets twice")
  d.planned = [second]; d.sets.append(set())
  check(TrainingWorkload.progress(second, draft: d, state: workloadData.training).remaining == 1, "F2/F3 returning exercise counts only newly completed work")
  workloadData.draft = d
  let adopted = TrainingProgression.proposal(workloadData, profileID: workloadData.training!.profiles[0].id, now: now)
  check(adopted.target?.sets == 2, "F2 substitute prescription is not reset by a profile's larger default")

  // The ability sheet must display the same post-substitution boundary as the plan.
  var returned = ready(); let returnedProfile = returned.training!.profiles[0]
  var returnedDraft = WorkoutDraft(); returnedDraft.planned = [row]
  let oldRow = set(profile: returnedProfile.id); returnedDraft.sets = [oldRow]
  let away = try TrainingWorkload.replacement(row, with: "dbrow", draft: returnedDraft, state: returned.training)
  returnedDraft.planned = [away]
  let back = try TrainingWorkload.replacement(away, with: "row", draft: returnedDraft, state: returned.training)
  returnedDraft.planned = [back]; returned.draft = returnedDraft
  let backProposal = TrainingProgression.proposal(returned, profileID: returnedProfile.id, now: now)
  try TrainingProgression.accept(backProposal, into: &returned, now: now)
  let backTarget = returned.draft!.targets!.first { $0.profileID == returnedProfile.id }!
  var display = TrainingWorkload.targetProgress(backTarget, profile: returnedProfile, draft: returned.draft, state: returned.training)
  check(display.completed == 0 && display.target == 2 && display.plan?.completed == 0 && display.plan?.remaining == 2,
    "F2 ability and plan both show 0/2 after row to dumbbell to row")
  check(display.priorCompleted == 1 && display.priorSummary?.contains("此前已抵扣 1") == true && returned.draft?.sets.first?.id == oldRow.id,
    "F2 ability separately labels the preserved previously deducted actual row")
  returned.draft?.sets.append(set(profile: returnedProfile.id))
  returned.draft?.sets.append(set(kind: "热身组", profile: returnedProfile.id))
  display = TrainingWorkload.targetProgress(backTarget, profile: returnedProfile, draft: returned.draft, state: returned.training)
  check(display.completed == 1 && display.target == 2 && display.plan?.completed == 1 && display.plan?.remaining == 1 && !TrainingProgression.planCompleted(returned.draft!, state: returned.training),
    "F2 ability stays at 1/2 after one new work set and excludes the new warmup")
  returned = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(returned))
  display = TrainingWorkload.targetProgress(backTarget, profile: returnedProfile, draft: returned.draft, state: returned.training)
  check(display.completed == 1 && display.priorCompleted == 1 && display.plan?.remaining == 1,
    "F2 ability accounting boundary survives the actual data round trip")
  var sideDraft = WorkoutDraft(); var sideItem = PlannedExercise("dbrow", sets: 2)
  let oldLeft = set("dbrow", profile: left.id), oldRight = set("dbrow", profile: right.id)
  sideItem.priorSetIDs = [oldLeft.id, oldRight.id]; sideDraft.planned = [sideItem]
  sideDraft.sets = [oldLeft, oldRight, set("dbrow", profile: left.id), set("dbrow", kind: "热身组", profile: right.id)]
  let leftTarget = TrainingTarget(profileID: left.id, kg: 10, reps: 10, sets: 2, reason: "合成目标", evidence: [])
  let rightTarget = TrainingTarget(profileID: right.id, kg: 10, reps: 10, sets: 2, reason: "合成目标", evidence: [])
  let leftDisplay = TrainingWorkload.targetProgress(leftTarget, profile: left, draft: sideDraft, state: workloadData.training)
  let rightDisplay = TrainingWorkload.targetProgress(rightTarget, profile: right, draft: sideDraft, state: workloadData.training)
  check(leftDisplay.completed == 1 && rightDisplay.completed == 0 && leftDisplay.priorCompleted == 1 && rightDisplay.priorCompleted == 1 && leftDisplay.summary.contains("左侧") && rightDisplay.summary.contains("右侧"),
    "F3 ability profile counts preserve separate sides and previous work after substitution")
  check(leftDisplay.plan?.left == 1 && leftDisplay.plan?.right == 0 && leftDisplay.plan?.completed == 0 && rightDisplay.plan?.completed == 0,
    "F3 both ability profiles show the same incomplete bilateral plan without counting warmup or prior sides")

  // Real B days already contain a row; pulldown cannot become a second row.
  for phase in ["恢复适应", "稳定训练"] {
    var bday = ready(), bDraft = WorkoutDraft()
    bDraft.programID = StrengthProgram.id; bDraft.sequenceSlot = 1; bDraft.started = now
    bDraft.planned = StrengthProgram.session(1, phase: phase, minutes: 60)
    bday.training?.sequenceIndex = 1; bday.draft = bDraft
    let pull = bDraft.planned!.first { $0.exerciseID == "pulldown" }!
    let rowItem = bDraft.planned!.first { $0.exerciseID == "row" }!
    let expected = phase == "恢复适应" ? 2 : 3
    check(pull.sets == expected && rowItem.sets == expected, "F2/F3 real B-day fixture has \(expected)-set pulldown and row")
    check(TrainingWorkload.alternatives(for: pull, draft: bDraft, state: bday.training, equipment: "器械与哑铃", context: "健身房").isEmpty,
      "F2/F3 shared native/chat candidates exclude colliding B-day row for \(phase)")
    reject("F2/F3 replacement mutation rejects colliding B-day row for \(phase)") {
      _ = try TrainingWorkload.replacement(pull, with: "row", draft: bDraft, state: bday.training)
    }
    var colliding = AgentOperationInput(kind: "substituteExercise", sourceText: "高位下拉器械被占了，换成划船")
    colliding.target_id = "planned." + pull.id.uuidString; colliding.exercise_id = "row"
    reject("F2/F3 chat preview rejects colliding B-day row for \(phase)") { _ = try operation(colliding, data: bday, at: now) }
    let candidate = PersonalAgentContext.build(bday, text: colliding.source_text, health: true, memory: false, now: now).snapshot.facts.first { $0.id == "planned." + pull.id.uuidString }
    check(candidate != nil && candidate?.summary.contains("row（") == false,
      "F2/F3 serialized chat context omits the colliding row candidate for \(phase)")
    var pendingCollision = AgentOperation(turnID: UUID(), input: colliding, fingerprint: AssistantContext.fingerprint(bday), summary: "旧候选", grounding: colliding.source_text)
    pendingCollision.createdAt = now
    bday.personalAgent = PersonalAgentState(); bday.personalAgent?.operations = [pendingCollision]
    let unchangedPlan = bday.draft!.planned!.map(\.id)
    reject("F2/F3 pending collision is rechecked at chat commit for \(phase)") {
      try AgentOperations.commit(pendingCollision.id, data: &bday, now: now)
    }
    check(bday.draft?.planned?.map(\.id) == unchangedPlan && bday.draft?.sets.isEmpty == true,
      "F2/F3 rejected collision leaves B-day plan identities and records unchanged for \(phase)")

    // A legacy bug may already have persisted two rows before today's work was logged.
    let pullIndex = bDraft.planned!.firstIndex { $0.id == pull.id }!
    bDraft.planned?[pullIndex] = PlannedExercise("row", sets: pull.sets, reps: pull.reps)
    for item in StrengthProgram.session(1, phase: phase, minutes: 60) where item.exerciseID != "pulldown" {
      for _ in 0..<item.sets { bDraft.sets.append(set(item.exerciseID, profile: item.exerciseID == "row" ? bday.training!.profiles[0].id : nil)) }
    }
    bday.draft = bDraft
    bday = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(bday))
    let actualIDs = bday.draft!.sets.map(\.id)
    let oldCollisionProgress = TrainingWorkload.progress(bday.draft!.planned![pullIndex], draft: bday.draft!, state: bday.training)
    check(TrainingWorkload.hasDuplicateExercises(bday.draft) && !TrainingProgression.planCompleted(bday.draft!, state: bday.training) && oldCollisionProgress.requiresPlanReview && oldCollisionProgress.summary.contains("核对计划"),
      "F2/F3 restored duplicate B-day cannot credit one batch of rows to two goals for \(phase)")
    let ambiguousTarget = TrainingProgression.proposal(bday, profileID: bday.training!.profiles[0].id, now: now)
    check(ambiguousTarget.target == nil && ambiguousTarget.reason.contains("核对计划"),
      "F2/F3 restored duplicate B-day pauses ability targets for \(phase)")
    var finish = AgentOperationInput(kind: "finishWorkout", sourceText: "训练结束了，实际30分钟"); finish.minutes = 30
    try apply(finish, to: &bday, at: now)
    check(bday.draft == nil && bday.workouts.last?.sets.map(\.id) == actualIDs && bday.training?.sequenceIndex == 1,
      "F2/F3 legacy duplicate B-day can archive actual history without advancing sequence for \(phase)")
  }

  var log = AgentOperationInput(kind: "logSet", sourceText: "记录今天做了推胸20kg，10次，1组")
  log.exercise = "推胸"; log.kg = 20; log.reps = 10; log.count = 1
  let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
  let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
  log.source_text = "记录\(f.string(from: tomorrow))做了推胸20kg，10次，1组"
  var futureData = ready()
  reject("F9 explicit future date rejected while generating confirmation") { _ = try operation(log, data: futureData, at: now) }
  // Even an imported/edited pending operation must pass the submission boundary.
  var forged = AgentOperation(turnID: UUID(), input: log, fingerprint: AssistantContext.fingerprint(futureData), summary: "旧卡片", grounding: log.source_text)
  forged.createdAt = now; forged.edited = true
  futureData.personalAgent = PersonalAgentState(); futureData.personalAgent?.operations = [forged]
  reject("F9 confirmation revalidates future date even for edited operation") { try AgentOperations.commit(forged.id, data: &futureData, now: now) }
  check(futureData.draft == nil && futureData.workouts.isEmpty, "F9 failed future confirmation creates no draft or actual record")
  for day in [0, -1] {
    var actual = ready(); TrainingSafety.pause(&actual, at: now)
    let date = Calendar.current.date(byAdding: .day, value: day, to: now)!
    log.source_text = "记录\(f.string(from: date))做了推胸20kg，10次，1组"
    let proposed = try operation(log, data: actual, at: now)
    check(proposed.summary.contains("日期：" + f.string(from: date)), "F9 confirmation shows the actual training date for offset \(day)")
    try apply(log, to: &actual, at: now)
    check(actual.draft?.sets.count == 1 && Calendar.current.isDate(actual.draft!.started, inSameDayAs: date) && TrainingSafety.isPaused(actual), "F1/F9 true historical recording remains available during pause for offset \(day)")
    let unchanged = actual.draft!.started
    log.source_text = "记录\(f.string(from: Calendar.current.date(byAdding: .day, value: day - 1, to: now)!))做了推胸20kg，10次，1组"
    reject("F9 different-day set is rejected before confirming against active draft") { _ = try operation(log, data: actual, at: now) }
    check(actual.draft?.started == unchanged && actual.draft?.sets.count == 1, "F9 rejected mismatched date leaves the existing draft unchanged")
  }
}
