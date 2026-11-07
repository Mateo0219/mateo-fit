import Foundation
import FitnessCore

@main struct StoreChecks {
  @MainActor static func main() throws {
    guard let dir = ProcessInfo.processInfo.environment["XUXU_DATA_DIR"], dir.contains("mateo-store-check-") else { fatalError("Use an isolated test directory") }
    let store = AppStore()
    var passed = 0
    func check(_ ok: Bool, _ label: String) { precondition(ok, label); passed += 1; print("PASS: " + label) }
    let turn = CoachTurn(text: "合成对话", reply: "准备看计划，未记录完成", actions: [.training])
    check(store.addConversation(turn), "Coach conversation persists")
    check(AppStore().data.conversation?.first?.id == turn.id && store.data.workouts.isEmpty, "Conversation restores without recording completed workout")
    check(try BackupCodec.decode(store.backupBytes()).records.conversation?.count == 1, "Conversation included in full backup")
    let photo = Data([1, 2, 3, 4])
    check(store.addMeal(title: "合成测试餐", note: "非真实记录", photo: photo), "Meal and photo save")
    var nutrition = MealNutrition(); nutrition.energyValue = 200
    check(store.change { $0.meals[0].nutrition = nutrition }, "Structured meal data saves")
    check(store.change { $0.foodDiaryCompleteAt = Date() }, "Day completeness can be saved")
    check(store.data.foodDiaryCompleteAt != nil, "Saving completeness does not invalidate itself")
    _ = store.change { $0.selectedTab = 1 }
    check(store.data.foodDiaryCompleteAt != nil, "Unrelated changes preserve completeness")
    _ = store.change { $0.meals[0].note = "更正份量" }
    check(store.data.foodDiaryCompleteAt == nil, "Editing today's food invalidates completeness")
    let first = store.data.meals[0]
    let backup = try BackupCodec.decode(store.backupBytes())
    store.deleteMeal(first)
    check(store.data.meals.isEmpty && store.data.trash?.meals.count == 1, "Removal retains recoverable record")
    check(try BackupCodec.decode(store.backupBytes()).photos.count == 1, "Backup includes removed-record photo")
    check(store.restore(backup), "Complete restore succeeds")
    check(store.data.meals[0].id == first.id && store.data.meals[0].photoName != first.photoName, "Restore preserves ID and isolates photo filenames")
    check(store.photo(store.data.meals[0].photoName!) == photo, "Restored photo bytes match")
    check(store.recoveryFiles.count == 1, "Restore preserves pre-restore backup")
    check(try store.recoveryBackup(store.recoveryFiles[0]).records.trash?.meals.count == 1, "Recovery backup includes prior removed state")
    store.healthBusy = true
    check(!store.restore(backup), "Restore cannot race active HealthKit sync")
    store.healthBusy = false
    let reloaded = AppStore()
    check(reloaded.data.meals.count == 1 && reloaded.data.meals[0].id == first.id, "Relaunch loads restored records")
    reloaded.beginWorkout(name: "测试")
    reloaded.finishWorkout(effort: "适中")
    check(reloaded.data.workouts.isEmpty && reloaded.data.draft != nil, "Empty strength draft cannot become completed workout")
    reloaded.addSet(exercise: "测试动作", kg: 0, reps: 8)
    reloaded.finishWorkout(effort: "适中")
    check(reloaded.data.workouts.count == 1 && reloaded.data.draft == nil, "Completed sets commit with workout")
    check(reloaded.repeatWorkout(reloaded.data.workouts[0]), "Workout can be reused")
    check(reloaded.data.draft?.sets.isEmpty == true && reloaded.data.draft?.referenceSets?.count == 1, "Reusing workout never pre-completes sets")
    // Isolated new training flow: preserve completed sets through same-day changes.
    _ = reloaded.change { $0.draft = nil; $0.workouts = [] }
    var prefs = CoachPreferences(); prefs.experience = "练过，正在恢复"; prefs.equipment = "器械与哑铃"; prefs.restrictions = "没有已知限制"; prefs.trainingWeekdays = Set(1...7)
    check(reloaded.savePreferences(prefs), "Training conditions saved")
    var today = DailyCheckIn(); today.energy = "状态正常"
    check(reloaded.saveCheckIn(today) && reloaded.startPlan(), "Daily plan starts with confirmed readiness")
    var ability = ExerciseProfile(exerciseID: "press"); ability.equipmentLabel = "合成测试机"; ability.availableLoads = [10,20,21]
    check(reloaded.saveExerciseProfile(ability), "Exercise profile persists")
    let proposal = TrainingProgression.proposal(reloaded.data, profileID: ability.id)
    check(reloaded.acceptTraining(proposal), "Calibration proposal can be confirmed")
    check(!reloaded.acceptTraining(proposal), "Store rejects duplicate target confirmation")
    check(reloaded.logTrackedSet(profileID: ability.id, kg: 10, reps: 8, rir: nil, form: "标准完成", kind: "工作组"), "Tracked set records unknown RIR explicitly")
    let setID = reloaded.data.draft!.sets[0].id
    today.context = "在家"; today.minutes = 20
    check(reloaded.saveCheckIn(today), "Daily location and time adapt")
    check(reloaded.data.draft?.sets[0].id == setID && reloaded.data.draft?.targets?.isEmpty == true, "Adaptation preserves completed sets and invalidates pending targets")
    check(reloaded.data.draft?.planned?.allSatisfy { ["sit", "wall", "calf"].contains($0.exerciseID) } == true, "Home adjustment excludes unavailable machines")
    check(!reloaded.logTrackedSet(profileID: ability.id, kg: 10, reps: 8, rir: 3, form: "标准完成", kind: "工作组"), "Removed machine cannot keep logging under stale target")
    let trainedBackup = try BackupCodec.decode(reloaded.backupBytes())
    check(trainedBackup.records.draft?.sets[0].profileID == ability.id, "Backup includes tracked ability data")
    let again = AppStore()
    check(again.data.draft?.sets[0].id == setID && again.data.training?.profiles.count == 1, "Relaunch preserves active plan, ability and completed sets")
    reloaded.finishWorkout(effort: "适中")
    check(reloaded.data.training?.sequenceIndex == 0, "Partial adapted plan saves without falsely advancing sequence")
    _ = reloaded.change { data in
      var complete = WorkoutDraft(); complete.sequenceSlot = 0; complete.planned = [PlannedExercise("press")]
      var copied = data.workouts.last!.sets[0]; copied.id = UUID(); copied.date = Date(); complete.sets = [copied]; data.draft = complete
    }
    reloaded.finishWorkout(effort: "适中")
    check(reloaded.data.training?.sequenceIndex == 1, "Completed planned work sets advance the sequence")
    let completedCount = reloaded.data.workouts.count
    reloaded.finishWorkout(effort: "适中")
    check(reloaded.data.workouts.count == completedCount && reloaded.data.training?.sequenceIndex == 1, "Finishing twice neither duplicates workout nor advances again")
    var renamed = ability; renamed.equipmentLabel = "不同机器"
    check(!reloaded.saveExerciseProfile(renamed), "Equipment identity cannot be silently remapped")
    // Full-program adoption, active-draft protection, metadata and rest timer.
    var full = prefs; full.programID = StrengthProgram.id; full.trainingPhase = "恢复适应"; full.trainingWeekdays = [2,4,6]; full.workoutMinutes = 60
    _ = reloaded.change { $0.draft = WorkoutDraft() }
    check(!reloaded.savePreferences(full), "New program cannot replace an active draft")
    _ = reloaded.change { $0.draft = nil; $0.workouts = [] }
    check(reloaded.savePreferences(full), "Confirmed full program persists with phase and schedule")
    check(reloaded.data.coach?.checkIn == nil, "Adopting a new program requires fresh readiness instead of inheriting short-session inputs")
    // Choose three nonadjacent days including today, independent of when checks run.
    let weekday = Calendar.current.component(.weekday, from: Date())
    full.trainingWeekdays = Set([0,2,4].map { ((weekday - 1 + $0) % 7) + 1 })
    _ = reloaded.savePreferences(full)
    today.context = "健身房"; today.minutes = 60
    check(reloaded.saveCheckIn(today) && reloaded.startPlan() && reloaded.data.draft?.programID == StrengthProgram.id, "Full plan starts with explicit program identity")
    // Sequence may be B after earlier checks; use a new profile for its first movement.
    let firstPlan = reloaded.data.draft!.planned!.first!
    var fullAbility = ExerciseProfile(exerciseID: firstPlan.exerciseID); fullAbility.equipmentLabel = "完整计划测试器械"; fullAbility.availableLoads = [0,10]
    _ = reloaded.saveExerciseProfile(fullAbility)
    let fullProposal = TrainingProgression.proposal(reloaded.data, profileID: fullAbility.id)
    check(reloaded.acceptTraining(fullProposal) && fullProposal.target?.sets == 2, "New target keeps two-set program despite one-set profile default")
    check(reloaded.logTrackedSet(profileID: fullAbility.id, kg: 0, reps: firstPlan.lowerReps ?? 8, rir: 3, form: "标准完成", kind: "工作组"), "Full program actual set saves")
    let remaining = reloaded.data.draft!.restUntil!.timeIntervalSinceNow
    check(remaining > Double((firstPlan.restSeconds ?? 90) - 3) && remaining <= Double(firstPlan.restSeconds ?? 90), "Rest timer follows the current exercise prescription")
    var nextPhase = full; nextPhase.trainingPhase = "稳定训练"
    check(!reloaded.savePreferences(nextPhase), "Phase change cannot silently rewrite an active workout")
    today.sportFatigue = true
    let fullSetID = reloaded.data.draft!.sets[0].id
    check(reloaded.saveCheckIn(today) && reloaded.data.draft?.sets[0].id == fullSetID && reloaded.data.draft?.planned?.allSatisfy { $0.sets == 1 } == true && reloaded.data.draft?.targets?.isEmpty == true, "Sports fatigue preserves actual work and invalidates previous volume targets")
    let fullBackup = try BackupCodec.decode(reloaded.backupBytes())
    check(fullBackup.records.coach?.preferences.programID == StrengthProgram.id && fullBackup.records.draft?.planned?.first?.restSeconds != nil, "Export retains full program and exercise metadata")
    var estimated = MealNutrition(); estimated.source = "AI 估计"; estimated.energyValue = 150
    check(reloaded.addMeal(title: "合成 AI 记录", note: "原始估计范围 100–200 kcal；非真实数据", photo: nil, nutrition: estimated), "Confirmed AI estimate saves as a distinct source")
    let aiRestored = try BackupCodec.decode(reloaded.backupBytes())
    check(aiRestored.records.meals.last?.nutrition?.source == "AI 估计" && aiRestored.records.meals.last?.note.contains("100–200") == true, "Backup retains AI source and original uncertainty note")
    check(reloaded.saveComposer(text: "尚未发送", photo: Data([3,4]), state: "sending"), "Home input persists before network request")
    check(AppStore().data.homeComposer?.state == "sending" && AppStore().data.homeComposer?.photo == Data([3,4]), "Interrupted input and photo survive restart")
    var pending = HomeMealDraft(description: "合成午饭，未确认", photo: Data([5,6]))
    pending.title = "合成待确认餐"; pending.nutrition = estimated
    let beforeMeals = reloaded.data.meals.count
    check(reloaded.setHomeMeal(pending) && reloaded.data.meals.count == beforeMeals, "Pending meal is not included in actual records")
    check(AppStore().data.pendingHomeMeal?.photo == Data([5,6]), "Pending meal photo restores without reselection")
    let draftBackup = try BackupCodec.decode(reloaded.backupBytes())
    check(draftBackup.records.pendingHomeMeal?.id == pending.id && draftBackup.records.homeComposer?.text == "尚未发送", "Full backup includes pending meal and composer")
    check(reloaded.confirmHomeMeal(pending), "Confirmed home meal commits atomically")
    check(reloaded.data.pendingHomeMeal == nil && reloaded.data.meals.count == beforeMeals + 1 && reloaded.data.conversation?.last?.outcome != nil, "Meal commit clears draft and records actual outcome")
    check(!reloaded.confirmHomeMeal(pending) && reloaded.data.meals.count == beforeMeals + 1, "Double-confirm cannot duplicate meal")
    check(!reloaded.setHomeMeal(pending) && reloaded.data.pendingHomeMeal == nil, "Late editor updates cannot restore an already committed draft")
    check(reloaded.photo(reloaded.data.meals.last!.photoName!) == Data([5,6]), "Confirmed draft retains original photo")
    let originalThread = reloaded.data.activeCoachThreadID!
    let originalTurns = CoachThreads.turns(reloaded.data).map(\.id)
    _ = reloaded.saveComposer(text: "本段未发送内容", photo: Data([8,9]))
    let heldMeal = HomeMealDraft(description: "另一餐合成草稿", photo: Data([10,11]))
    _ = reloaded.setHomeMeal(heldMeal)
    check(reloaded.newCoachThread() && reloaded.data.activeCoachThreadID != originalThread && reloaded.data.homeComposer == nil && reloaded.data.pendingHomeMeal == nil, "New chat starts empty without deleting the previous unfinished input")
    let secondThread = reloaded.data.activeCoachThreadID!
    let threadCount = reloaded.data.coachThreads?.count
    check(!CoachThreads.historyThreads(reloaded.data).contains(where: { $0.id == secondThread }) && CoachThreads.historyThreads(reloaded.data).contains(where: { $0.id == originalThread }), "New empty chat stays outside history while prior messages remain visible")
    check(reloaded.newCoachThread() && reloaded.data.activeCoachThreadID == secondThread && reloaded.data.coachThreads?.count == threadCount, "Repeated new-chat action reuses the empty chat")
    _ = reloaded.saveComposer(text: "未发送的新对话草稿", photo: Data([12,13]))
    _ = reloaded.selectCoachThread(originalThread)
    check(!CoachThreads.historyThreads(reloaded.data).contains(where: { $0.id == secondThread }), "Unsent text and photo do not create a history row")
    check(reloaded.newCoachThread() && reloaded.data.activeCoachThreadID == secondThread && reloaded.data.homeComposer?.text == "未发送的新对话草稿" && reloaded.data.homeComposer?.photo == Data([12,13]) && reloaded.data.coachThreads?.count == threadCount, "Returning to new chat restores its unsent draft instead of creating another hidden thread")
    check(reloaded.newCoachThread() && reloaded.data.activeCoachThreadID == secondThread && reloaded.data.homeComposer?.photo == Data([12,13]), "Repeated new chat preserves unsent input")
    _ = reloaded.addConversation(CoachTurn(text: "第二段对话", reply: "独立回复", actions: [.review]))
    check(CoachThreads.historyThreads(reloaded.data).filter { $0.id == secondThread }.count == 1, "First submitted message makes its conversation visible once")
    check(CoachThreads.turns(AppStore().data).map(\.text) == ["第二段对话"], "Restart restores selected chat and only its messages")
    check(reloaded.selectCoachThread(originalThread) && CoachThreads.turns(reloaded.data).map(\.id) == originalTurns && reloaded.data.homeComposer?.photo == Data([8,9]) && reloaded.data.pendingHomeMeal?.id == heldMeal.id, "Selecting prior chat restores exact pending input and meal")
    reloaded.renameCoachThread(originalThread, title: "训练与饮食"); reloaded.pinCoachThread(originalThread)
    check(AppStore().data.coachThreads?.first(where: { $0.id == originalThread })?.title == "训练与饮食" && reloaded.data.coachThreads?.first(where: { $0.id == originalThread })?.pinned == true, "Rename and pin persist without changing health records")
    let actualMealCount = reloaded.data.meals.count
    reloaded.archiveCoachThread(originalThread)
    check(reloaded.data.coachThreads?.first(where: { $0.id == originalThread })?.archived == true && reloaded.data.activeCoachThreadID != originalThread && reloaded.data.meals.count == actualMealCount, "Archiving preserves pending drafts and formal records")
    let chatsBackup = try BackupCodec.decode(reloaded.backupBytes())
    check(chatsBackup.records.coachThreads?.first(where: { $0.id == originalThread })?.pendingMeal?.photo == Data([10,11]), "Full backup retains archived meal photos")
    _ = reloaded.selectCoachThread(secondThread); reloaded.clearCurrentCoachConversation()
    check(CoachThreads.turns(reloaded.data).isEmpty && !CoachThreads.turns(reloaded.data, in: originalThread).isEmpty && reloaded.data.meals.count == actualMealCount, "Clear affects only selected chat, not other conversations or logs")
    check(!CoachThreads.historyThreads(reloaded.data).contains(where: { $0.id == secondThread }), "Cleared conversation with only unsent input leaves history")
    check(reloaded.selectCoachThread(originalThread) && reloaded.data.pendingHomeMeal?.id == heldMeal.id && reloaded.data.coachThreads?.first(where: { $0.id == originalThread })?.archived == false, "Opening archived chat restores it with its unfinished meal")
    // v0.9 uses the same atomic file transaction, including memory and operation state.
    check(reloaded.submitLocalAgentText("以后回答简短点"), "Explicit preference saves locally without a model")
    check(AppStore().data.personalAgent?.memories.first?.content == "以后回答简短点", "Memory restores from the real JSON store")
    check(reloaded.data.homeComposer?.text.isEmpty == true, "Local memory submission clears the persisted composer")
    let learned = reloaded.data.personalAgent!.memories[0]
    let receiptID = reloaded.data.personalAgent!.receipts.last!.id
    check(reloaded.newCoachThread(), "New conversation can be created with existing memory")
    check(reloaded.data.personalAgent?.memories.first?.id == learned.id, "New conversation retains the same personal memory identity")
    reloaded.setNoLongTermMemory(true)
    let oldMemoryCount = reloaded.data.personalAgent!.memories.count
    check(reloaded.submitLocalAgentText("我通常周一晚上训练") && reloaded.data.personalAgent!.memories.count == oldMemoryCount, "No-memory conversation does not create a new preference")
    reloaded.setNoLongTermMemory(false)
    check(reloaded.undoAgentOperation(receiptID) && AppStore().data.personalAgent?.memories.isEmpty == true, "Memory undo persists atomically")
    check(!reloaded.undoAgentOperation(receiptID), "Repeated undo cannot change records twice")
    check(reloaded.submitLocalAgentText("以后回答简短点"), "Preference may be explicitly learned again after undo")
    let personalBackup = try BackupCodec.decode(reloaded.backupBytes())
    check(personalBackup.records.personalAgent?.memories.count == 1 && personalBackup.records.personalAgent?.receipts.isEmpty == false, "Full backup includes memories and receipts")
    var submitted = CoachTurn(text: "今天吃了鸡蛋两个", reply: "", actions: [])
    submitted.threadID = reloaded.data.activeCoachThreadID; submitted.deliveryState = "sending"; submitted.attemptID = UUID()
    check(reloaded.beginCoachRequest(submitted), "V2 transaction starts with a persisted request")
    let bundle = PersonalAgentContext.build(reloaded.data, text: submitted.text, health: false, memory: false)
    let raw: [String:Any] = ["contract_version":2, "request_id":submitted.attemptID!.uuidString, "snapshot_id":bundle.snapshot.snapshot_id, "expected_plan_version":bundle.snapshot.expected_plan_version, "status":"proposal", "message":"请核对", "questions":[String](), "cards":[[String:String]](), "operations":[["kind":"logMeal", "source_text":submitted.text,"content":"鸡蛋两个","evidence_ids":[String]()]]]
    let response = try JSONDecoder().decode(CoachAssistantResponse.self, from: JSONSerialization.data(withJSONObject: raw))
    check(reloaded.finishPersonalRequest(turnID: submitted.id, attemptID: submitted.attemptID!, bundle: bundle, response: response), "Validated V2 reply stages a local operation")
    let proposalID = reloaded.data.personalAgent!.operations.last!.id
    let mealsBefore = reloaded.data.meals.count
    check(AppStore().data.personalAgent?.operations.last?.status == "pending" && reloaded.data.meals.count == mealsBefore, "Restart retains pending proposal without saving a meal")
    check(reloaded.commitAgentOperation(proposalID) && AppStore().data.meals.count == mealsBefore + 1, "Confirmation atomically saves actual meal and receipt")
    check(!reloaded.commitAgentOperation(proposalID) && reloaded.data.meals.count == mealsBefore + 1, "Duplicate confirmation is idempotent across saved state")
    check(!reloaded.finishPersonalRequest(turnID: submitted.id, attemptID: submitted.attemptID!, bundle: bundle, response: response), "Late duplicate model response cannot stage another operation")
    // Regression: model prose alone is never proof of a memory transaction.
    var falseTurn = CoachTurn(text: "请记一下，我对花生过敏", reply: "", actions: [])
    falseTurn.threadID = reloaded.data.activeCoachThreadID; falseTurn.deliveryState = "sending"; falseTurn.attemptID = UUID()
    _ = reloaded.beginCoachRequest(falseTurn)
    let falseBundle = PersonalAgentContext.build(reloaded.data, text: falseTurn.text, health: false, memory: false)
    let falseRaw: [String:Any] = ["contract_version":2, "request_id":falseTurn.attemptID!.uuidString, "snapshot_id":falseBundle.snapshot.snapshot_id, "expected_plan_version":falseBundle.snapshot.expected_plan_version, "status":"proposal", "message":"已记住，以后会注意。", "questions":[String](), "cards":[[String:String]](), "operations":[[String:String]]()]
    let falseReply = try JSONDecoder().decode(CoachAssistantResponse.self, from: JSONSerialization.data(withJSONObject: falseRaw))
    let savedMemoryCount = reloaded.data.personalAgent!.memories.count
    check(!reloaded.finishPersonalRequest(turnID: falseTurn.id, attemptID: falseTurn.attemptID!, bundle: falseBundle, response: falseReply), "Model-only saved claim is rejected at the real request completion boundary")
    check(AppStore().data.personalAgent!.memories.count == savedMemoryCount && reloaded.data.conversation?.last?.reply.isEmpty == true, "Uncommitted claim never becomes a visible success or a phantom memory")
    _ = reloaded.stopCoachRequest(attemptID: falseTurn.attemptID!)
    var confirmedTurn = falseTurn; confirmedTurn.id = UUID(); confirmedTurn.attemptID = UUID()
    _ = reloaded.beginCoachRequest(confirmedTurn)
    let confirmedBundle = PersonalAgentContext.build(reloaded.data, text: confirmedTurn.text, health: false, memory: false)
    var confirmedRaw = falseRaw
    confirmedRaw["request_id"] = confirmedTurn.attemptID!.uuidString; confirmedRaw["snapshot_id"] = confirmedBundle.snapshot.snapshot_id
    confirmedRaw["message"] = "请核对这条记忆。"
    confirmedRaw["operations"] = [["kind":"remember", "source_text":confirmedTurn.text, "content":"我对花生过敏", "topic":"health_constraint", "evidence_ids":[String]()]]
    let confirmedReply = try JSONDecoder().decode(CoachAssistantResponse.self, from: JSONSerialization.data(withJSONObject: confirmedRaw))
    check(reloaded.finishPersonalRequest(turnID: confirmedTurn.id, attemptID: confirmedTurn.attemptID!, bundle: confirmedBundle, response: confirmedReply), "Cloud memory proposal reaches the same confirmation flow as the phone")
    let confirmMemoryID = reloaded.data.personalAgent!.operations.last!.id
    check(AppStore().data.personalAgent!.memories.count == savedMemoryCount, "Pending cloud memory remains absent until the confirm button action")
    check(reloaded.commitAgentOperation(confirmMemoryID), "Memory confirm button commits through the actual store transaction")
    check(AppStore().data.personalAgent!.memories.contains { $0.content == "我对花生过敏" } && AppStore().data.personalAgent!.receipts.last?.id == confirmMemoryID, "Confirmed cloud memory and real receipt are both readable after restart")
    check(reloaded.submitLocalAgentText("我不喜欢甜食") && reloaded.submitLocalAgentText("我喜欢吃米饭"), "Two independent food preferences enter the real store flow")
    let extraMemory = reloaded.data.personalAgent!.operations.last!.id
    check(reloaded.commitAgentOperation(extraMemory), "The second preference can be explicitly confirmed")
    let memoryContents = AppStore().data.personalAgent!.memories.map(\.content)
    check(memoryContents.contains("我不喜欢甜食") && memoryContents.contains("我喜欢吃米饭"), "Confirmed same-category memory preserves other preferences after restart")
    passed += try reviewStorageRegressions(parentDirectory: dir)
    passed += try reviewTrainingRegressions(parentDirectory: dir)
    let missing = reloaded.data.meals[0].photoName!
    try FileManager.default.removeItem(at: URL(fileURLWithPath: dir).appendingPathComponent(missing))
    do { _ = try reloaded.backupBytes(); fatalError("Incomplete photo backup accepted") } catch { check(true, "Missing photo blocks incomplete export") }
    // Make the record destination unwritable while leaving its prior bytes intact elsewhere.
    let path = URL(fileURLWithPath: dir).appendingPathComponent("records-v1.json")
    try FileManager.default.moveItem(at: path, to: path.appendingPathExtension("preserved"))
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    let count = reloaded.data.weights.count
    check(!reloaded.addWeight(100) && reloaded.data.weights.count == count, "Failed atomic write does not mutate in-memory records")
    let memoryCountBeforeFailure = reloaded.data.personalAgent?.memories.count
    check(!reloaded.submitLocalAgentText("我通常周三晚上训练") && reloaded.data.personalAgent?.memories.count == memoryCountBeforeFailure, "Failed atomic save does not falsely acknowledge a memory")
    print("\(passed) store checks passed")
  }

  @MainActor static func reviewTrainingRegressions(parentDirectory: String) throws -> Int {
    var passed = 0
    func check(_ ok: Bool, _ label: String) { precondition(ok, label); passed += 1; print("PASS: " + label) }
    let root = URL(fileURLWithPath: parentDirectory).appendingPathComponent("review-training")
    setenv("XUXU_DATA_DIR", root.path, 1)
    defer { setenv("XUXU_DATA_DIR", parentDirectory, 1) }
    let store = AppStore()
    var prefs = CoachPreferences(); prefs.experience = "练过"; prefs.equipment = "器械与哑铃"; prefs.restrictions = "没有已知限制"; prefs.trainingWeekdays = Set(1...7)
    var condition = DailyCheckIn(); condition.energy = "状态正常"; condition.minutes = 60; condition.confirmedFields = ["energy", "context", "minutes"]
    check(store.savePreferences(prefs) && store.saveCheckIn(condition) && store.startPlan(), "F1 Store starts a native plan before any pause")
    var profile = ExerciseProfile(exerciseID: "row"); profile.equipmentLabel = "合成划船器械"; profile.availableLoads = [10, 20]
    check(store.saveExerciseProfile(profile), "F1 Store saves the isolated ability fixture")
    let beforePause = TrainingProgression.proposal(store.data, profileID: profile.id)
    check(store.acceptTraining(beforePause), "F1 Store accepts an ability target before pause")
    let earlierBackup = try BackupCodec.decode(store.backupBytes())
    func response(_ bundle: CoachContextBundle, attempt: UUID) throws -> CoachAssistantResponse {
      let raw: [String: Any] = ["contract_version": 2, "request_id": attempt.uuidString, "snapshot_id": bundle.snapshot.snapshot_id,
        "expected_plan_version": bundle.snapshot.expected_plan_version, "status": "safety_pause", "message": "合成暂停，请核对当前状态。",
        "questions": [String](), "cards": [[String: String]](), "operations": [[String: String]]()]
      return try JSONDecoder().decode(CoachAssistantResponse.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    var turn = CoachTurn(text: "合成：现在头晕", reply: "", actions: [])
    let attempt = UUID(); turn.deliveryState = "sending"; turn.attemptID = attempt
    check(store.beginCoachRequest(turn), "F1 Store begins an isolated assistant request")
    let bundle = PersonalAgentContext.build(store.data, text: turn.text, health: true, memory: false)
    check(store.finishPersonalRequest(turnID: turn.id, attemptID: attempt, bundle: bundle, response: try response(bundle, attempt: attempt)), "F1 personal assistant pause finishes through its real transaction")
    check(TrainingSafety.isPaused(AppStore().data) && store.data.draft?.targets?.isEmpty == true && !store.acceptTraining(beforePause), "F1 received pause persists, invalidates targets and blocks old ability adoption")
    _ = store.change { $0.draft = nil }
    check(!store.startPlan() && store.data.draft == nil, "F1 native startPlan cannot bypass a chat pause")
    let actual = WorkoutEntry(name: "历史合成训练", sets: [SetEntry(exercise: "推胸", kg: 10, reps: 8)], effort: "适中", minutes: 20)
    check(!store.repeatWorkout(actual) && store.data.draft == nil, "F1 reuse reference entry cannot bypass pause")
    store.clearCurrentCoachConversation()
    check(store.data.conversation?.isEmpty == true && TrainingSafety.isPaused(AppStore().data), "F1 clearing the entire paused chat and relaunching keeps the pause")
    var patch = AgentOperationInput(kind: "updateToday", sourceText: "今天40分钟"); patch.minutes = 40
    let patchTurn = CoachTurn(text: patch.source_text, reply: "待确认", actions: [])
    let patchOp = try AgentOperations.stage(patch, turn: patchTurn, data: store.data)
    _ = store.change { if $0.personalAgent == nil { $0.personalAgent = PersonalAgentState() }; $0.personalAgent?.operations.append(patchOp) }
    check(store.commitAgentOperation(patchOp.id) && TrainingSafety.isPaused(store.data) && !store.startPlan(), "F1 committing only minutes cannot release native start")
    check(store.undoAgentOperation(patchOp.id) && TrainingSafety.isPaused(AppStore().data), "F1 Store undo keeps independent safety pause across restart")
    check(store.restore(earlierBackup) && TrainingSafety.isPaused(AppStore().data), "F1 real backup restoration cannot clear the later current pause")
    _ = store.change { $0.draft = nil }
    condition.date = Date()
    check(store.saveCheckIn(condition) && TrainingSafety.isPaused(store.data), "F1 ordinary full-form normal check-in does not silently recover")
    store.beginWorkout(name: "已发生的合成运动")
    store.addSet(exercise: "已做推胸", kg: 10, reps: 8)
    check(store.finishWorkout(effort: "适中", actualMinutes: 20) && store.data.workouts.count == 1 && TrainingSafety.isPaused(store.data), "F1 actual historical workout can still be saved during pause")

    // An unsuccessful recovery write must leave both the live state and disk paused.
    let path = root.appendingPathComponent("records-v1.json"), preserved = path.appendingPathExtension("preserved")
    try FileManager.default.moveItem(at: path, to: preserved)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    condition.date = Date()
    check(!store.confirmTrainingRecovery(condition) && TrainingSafety.isPaused(store.data), "F1 failed atomic recovery never releases in-memory safety")
    check(TrainingSafety.isPaused(try JSONDecoder().decode(AppData.self, from: Data(contentsOf: preserved))), "F1 failed recovery preserves the paused on-disk version")
    try FileManager.default.removeItem(at: path)
    try FileManager.default.moveItem(at: preserved, to: path)
    condition.date = Date()
    check(store.confirmTrainingRecovery(condition) && !TrainingSafety.isPaused(AppStore().data), "F1 explicit successful recovery persists after restart")
    _ = store.change { $0.workouts = []; $0.draft = nil }
    check(store.startPlan() && TrainingProgression.proposal(store.data, profileID: profile.id).target != nil, "F1 recovery re-enables native plan and ability recommendation")

    // Compatibility request completion must write the same persistent pause.
    var legacyTurn = CoachTurn(text: "合成：又头晕", reply: "", actions: []); let legacyAttempt = UUID()
    legacyTurn.deliveryState = "sending"; legacyTurn.attemptID = legacyAttempt
    check(store.beginCoachRequest(legacyTurn), "F1 compatibility request starts")
    let legacyBundle = AssistantContext.build(store.data, text: legacyTurn.text, includeHealth: true)
    let exchange = CoachExchange(bundle: legacyBundle, response: try response(legacyBundle, attempt: legacyAttempt))
    check(store.finishCoachRequest(turnID: legacyTurn.id, attemptID: legacyAttempt, exchange: exchange) && TrainingSafety.isPaused(AppStore().data), "F1 compatibility completion also persists the pause")

    // Older JSON has only the chat response and a misleading newer check-in timestamp.
    var legacyData = store.data; legacyData.trainingSafety = nil
    let legacyIndex = legacyData.conversation!.count - 1
    legacyData.conversation?[legacyIndex].date = Date().addingTimeInterval(-60)
    legacyData.coach?.checkIn?.date = Date()
    try JSONEncoder().encode(legacyData).write(to: path, options: .atomic)
    let migrated = AppStore()
    let migratedDisk = try JSONDecoder().decode(AppData.self, from: Data(contentsOf: path))
    check(migratedDisk.trainingSafety != nil && TrainingSafety.isPaused(migrated.data), "F1 actual legacy JSON load durably migrates unresolved pause")
    migrated.clearCurrentCoachConversation()
    check(TrainingSafety.isPaused(AppStore().data), "F1 clearing immediately after legacy migration cannot bypass restart safety")

    // Native substitution shares the same work-set and side rules as chat.
    condition.date = Date(); _ = migrated.confirmTrainingRecovery(condition)
    for count in [0, 1, 3] {
      var d = WorkoutDraft(); let item = PlannedExercise("row", sets: 3); d.planned = [item]
      d.sets = (0..<count).map { _ in var s = SetEntry(exercise: "坐姿器械划船", kg: 10, reps: 10); s.exerciseID = "row"; s.setKind = "工作组"; return s }
      let ids = d.sets.map(\.id)
      _ = migrated.change { $0.draft = d }
      migrated.substituteExercise(itemID: item.id, exerciseID: "dbrow")
      check(migrated.data.draft?.sets.map(\.id) == ids && migrated.data.draft?.planned?.first?.sets == (count == 3 ? 3 : 3 - count) && migrated.data.draft?.planned?.first?.exerciseID == (count == 3 ? "row" : "dbrow"), "F2 native substitution retains IDs and remaining volume for \(count) completed sets")
    }
    var d = WorkoutDraft(); let item = PlannedExercise("row", sets: 3); d.planned = [item]
    var warmup = SetEntry(exercise: "坐姿器械划船", kg: 5, reps: 10); warmup.exerciseID = "row"; warmup.setKind = "热身组"; d.sets = [warmup]
    _ = migrated.change { $0.draft = d }
    migrated.substituteExercise(itemID: item.id, exerciseID: "dbrow")
    check(migrated.data.draft?.planned?.first?.sets == 3 && migrated.data.draft?.sets.first?.id == warmup.id, "F2/F3 native substitution does not consume a warmup as work")
    for phase in ["恢复适应", "稳定训练"] {
      var bday = WorkoutDraft(); bday.programID = StrengthProgram.id; bday.sequenceSlot = 1
      let originalPlan = StrengthProgram.session(1, phase: phase, minutes: 60)
      bday.planned = originalPlan
      let pull = originalPlan.first { $0.exerciseID == "pulldown" }!
      for item in originalPlan where item.exerciseID != "pulldown" {
        for _ in 0..<item.sets {
          var s = SetEntry(exercise: TrainingLibrary.guide(item.exerciseID)!.name, kg: 10, reps: 10)
          s.exerciseID = item.exerciseID; s.setKind = "工作组"; s.form = "标准完成"
          if item.exerciseID == "row" { s.profileID = profile.id; s.profileRevision = profile.revision }
          bday.sets.append(s)
        }
      }
      _ = migrated.change { $0.workouts = []; $0.draft = bday; $0.training?.sequenceIndex = 1 }
      let actualIDs = bday.sets.map(\.id), planIDs = originalPlan.map(\.id)
      migrated.substituteExercise(itemID: pull.id, exerciseID: "row")
      check(migrated.data.draft?.planned?.map(\.id) == planIDs && migrated.data.draft?.sets.map(\.id) == actualIDs && migrated.alert?.contains("重复") == true,
        "F2/F3 native B-day rejects a second row while retaining actual records for \(phase)")
      check(TrainingWorkload.alternatives(for: pull, draft: migrated.data.draft!, state: migrated.data.training, equipment: "器械与哑铃", context: "健身房").isEmpty,
        "F2/F3 native B-day button candidates omit the existing row for \(phase)")
      let pullIndex = bday.planned!.firstIndex { $0.id == pull.id }!
      bday.planned?[pullIndex] = PlannedExercise("row", sets: pull.sets, reps: pull.reps)
      _ = migrated.change { $0.draft = bday }
      let legacyStore = AppStore()
      let target = TrainingProgression.proposal(legacyStore.data, profileID: profile.id)
      check(target.target == nil && target.reason.contains("核对计划") && !TrainingProgression.planCompleted(legacyStore.data.draft!, state: legacyStore.data.training),
        "F2/F3 actual restart of a duplicate B-day blocks ability targets and automatic completion for \(phase)")
      check(legacyStore.finishWorkout(effort: "适中", actualMinutes: 30) && legacyStore.data.workouts.last?.sets.map(\.id) == actualIDs && legacyStore.data.training?.sequenceIndex == 1,
        "F2/F3 native finish preserves duplicate-plan history without advancing sequence for \(phase)")
    }
    print("\(passed) review training store checks passed")
    return passed
  }

  @MainActor static func reviewStorageRegressions(parentDirectory: String) throws -> Int {
    var passed = 0
    func check(_ ok: Bool, _ label: String) { precondition(ok, label); passed += 1; print("PASS: " + label) }
    let root = URL(fileURLWithPath: parentDirectory).appendingPathComponent("review-storage")
    setenv("XUXU_DATA_DIR", root.path, 1)
    defer { setenv("XUXU_DATA_DIR", parentDirectory, 1) }
    let store = AppStore()
    let calendar = Calendar.current
    let now = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!

    // F4: interrupted wall-clock time is not actual exercise duration.
    var draft = WorkoutDraft()
    draft.started = now.addingTimeInterval(-2 * 86400)
    var set = SetEntry(exercise: "合成推胸", kg: 10, reps: 8); set.date = draft.started.addingTimeInterval(300)
    draft.sets = [set]
    _ = store.change { $0.draft = draft }
    check(store.workoutNeedsDurationConfirmation(now: now) && !store.finishWorkout(effort: "适中", now: now), "F4: two-day interrupted draft requires an explicit actual duration")
    check(AppStore().data.draft?.sets.first?.id == set.id && store.data.workouts.isEmpty, "F4: asking for duration preserves the original draft across restart")
    check(!store.finishWorkout(effort: "适中", actualMinutes: 0, now: now) && !store.finishWorkout(effort: "适中", actualMinutes: 1441, now: now), "F4: out-of-range duration cannot become a workout")
    check(store.finishWorkout(effort: "适中", actualMinutes: 40, now: now), "F4: confirmed actual duration saves an interrupted workout")
    let saved = store.data.workouts[0]
    check(saved.minutes == 40 && saved.date == draft.started && saved.sets[0].id == set.id && store.data.draft == nil, "F4: duration confirmation retains actual workout date and set identity")
    check(try BackupCodec.decode(store.backupBytes()).records.workouts.first?.minutes == 40, "F4: saved interrupted workout exports successfully")
    draft = WorkoutDraft(); draft.started = now.addingTimeInterval(-25 * 60); draft.sets = [SetEntry(exercise: "合成划船", kg: 10, reps: 8)]
    _ = store.change { $0.draft = draft }
    check(!store.workoutNeedsDurationConfirmation(now: now) && store.finishWorkout(effort: "轻松", now: now) && store.data.workouts.last?.minutes == 25, "F4: short same-day workout still finishes in one action")
    draft = WorkoutDraft(); draft.started = now.addingTimeInterval(-3 * 3600); draft.sets = [SetEntry(exercise: "合成深蹲", kg: 0, reps: 8)]
    _ = store.change { $0.draft = draft }
    check(store.workoutNeedsDurationConfirmation(now: now) && !store.finishWorkout(effort: "适中", now: now), "F4: abnormal same-day long timer also requires actual minutes")
    let midnight = calendar.startOfDay(for: now)
    _ = store.change { $0.draft?.started = midnight.addingTimeInterval(-5 * 60) }
    check(store.workoutNeedsDurationConfirmation(now: midnight.addingTimeInterval(5 * 60)), "F4: a short cross-midnight draft still asks for actual duration")
    _ = store.change { $0.draft = nil; $0.workouts[0].minutes = 2880 }
    do { _ = try store.backupBytes(); preconditionFailure("Invalid legacy duration exported") }
    catch { check(true, "F4: legacy invalid duration remains explicit instead of silently clamped") }
    _ = store.change { $0.workouts[0].minutes = 35 }
    let repairedBackup = try BackupCodec.decode(store.backupBytes())
    check(store.restore(repairedBackup) && AppStore().data.workouts[0].minutes == 35, "F4: correcting a legacy duration restores both export and full restore")

    // F5: the form's save transaction owns confirmation, not local text editing.
    let beforeProfile = store.data.profile
    var edited = beforeProfile; edited.age = 35; edited.heightCM = 178; edited.initialWeightKG = 92
    check(AppStore().data.profile == beforeProfile && store.data.profile.confirmedAt == nil, "F5: cancelling unsaved profile edits does not confirm defaults")
    check(store.saveProfile(edited), "F5: explicit profile save succeeds")
    let persisted = AppStore().data
    check(persisted.profile.age == 35 && persisted.profile.heightCM == 178 && persisted.profile.confirmedAt != nil, "F5: profile values and confirmation persist together")
    let context = AssistantContext.build(persisted, text: "结合记录给我建议", includeHealth: true)
    let profileFact = context.snapshot.facts.first { $0.id == "profile" }
    check(profileFact?.summary.contains("35") == true && profileFact?.summary.contains("178") == true && profileFact?.quality == "用户确认", "F5: authorized summary includes the confirmed age and height")
    check(persisted.weights.isEmpty && profileFact?.summary.contains("档案起点不是当前测量") == true, "F5: initial profile weight never becomes a measured weight record")
    var invalid = edited; invalid.age = 0
    check(!store.saveProfile(invalid) && store.data.profile == persisted.profile, "F5: invalid profile save leaves prior confirmation unchanged")

    // F8: use the same staged operation, atomic commit, backup and undo as the app.
    let photo = Data([41, 42, 43])
    var nutrition = MealNutrition(); nutrition.energyValue = 320
    check(store.addMeal(title: "合成原餐", note: "原备注", photo: photo, nutrition: nutrition), "F8: source meal saves with a photo and nutrition")
    let originalMeal = store.data.meals[0]
    func correction(_ content: String) throws -> UUID {
      let turn = CoachTurn(text: "更正为" + content, reply: "请核对", actions: [.records])
      precondition(store.addConversation(turn))
      var input = AgentOperationInput(kind: "correctMeal", sourceText: turn.text)
      input.target_id = "meal." + originalMeal.id.uuidString; input.content = content
      let op = try AgentOperations.stage(input, turn: turn, data: store.data)
      precondition(store.change { if $0.personalAgent == nil { $0.personalAgent = PersonalAgentState() }; $0.personalAgent?.operations.append(op) })
      precondition(store.commitAgentOperation(op.id))
      return op.id
    }
    let firstCorrection = try correction("合成更正餐一")
    let correctedBackup = try BackupCodec.decode(store.backupBytes())
    check(store.restore(correctedBackup), "F8: corrected photo meal restores through the real file-renaming path")
    let restoredName = store.data.meals[0].photoName!
    check(restoredName != originalMeal.photoName && store.data.personalAgent?.receipts.last?.before.meals?.first?.photoName == restoredName && store.photo(restoredName) == photo, "F8: current meal and undo snapshot share a readable relocated photo")
    check(store.undoAgentOperation(firstCorrection), "F8: photo meal correction can be undone after full restore")
    let undone = AppStore().data.meals[0]
    check(undone.title == originalMeal.title && undone.note == originalMeal.note && undone.nutrition == originalMeal.nutrition && undone.photoName == restoredName && store.photo(undone.photoName!) == photo, "F8: undo restores prior text and nutrition while retaining readable new photo")
    check(store.restore(correctedBackup), "F8: restore prepares a separate post-restore edit case")
    _ = store.change { $0.meals[0].note = "恢复后真实修改" }
    check(!store.undoAgentOperation(firstCorrection) && store.data.meals[0].note == "恢复后真实修改", "F8: a real edit after restore still blocks undo overwrite")
    let conflictDigest = store.data.personalAgent!.receipts.last!.afterDigest
    let conflictBackup = try BackupCodec.decode(store.backupBytes())
    check(store.restore(conflictBackup) && store.data.personalAgent!.receipts.last!.afterDigest == conflictDigest && !store.undoAgentOperation(firstCorrection), "F8: restoring an already-conflicted receipt does not grant it undo permission")
    check(store.restore(correctedBackup), "F8: restore prepares successive correction receipts")
    let secondCorrection = try correction("合成更正餐二")
    let chainBackup = try BackupCodec.decode(store.backupBytes())
    check(store.restore(chainBackup) && store.undoAgentOperation(secondCorrection) && store.undoAgentOperation(firstCorrection), "F8: verified successive receipt digests stay valid through photo relocation")
    check(store.data.meals[0].title == originalMeal.title && store.photo(store.data.meals[0].photoName!) == photo, "F8: successive undo keeps the original meal and readable photo")
    let receiptOnlyName = store.data.meals[0].photoName!
    _ = store.change { $0.meals[0].photoName = nil }
    check(try BackupCodec.decode(store.backupBytes()).photos[receiptOnlyName] == photo, "F8: full backup includes photos retained only in undo snapshots")
    let receiptOnlyBackup = try BackupCodec.decode(store.backupBytes())
    check(store.restore(receiptOnlyBackup) && store.data.personalAgent!.receipts.allSatisfy { receipt in (receipt.before.meals ?? []).allSatisfy { $0.photoName.map { store.photo($0) == photo } ?? true } }, "F8: receipt-only photo references also relocate to readable files")

    // Make the atomic destination fail without relying on permissions under root.
    draft = WorkoutDraft(); draft.started = Date().addingTimeInterval(-30 * 60); draft.sets = [SetEntry(exercise: "保存失败合成组", kg: 0, reps: 8)]
    _ = store.change { $0.draft = draft; $0.profile.confirmedAt = nil }
    let beforeFailure = store.data
    let path = root.appendingPathComponent("records-v1.json"), preserved = path.appendingPathExtension("preserved")
    try FileManager.default.moveItem(at: path, to: preserved)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    check(!store.finishWorkout(effort: "适中", actualMinutes: 30) && store.data.draft?.sets.first?.id == draft.sets.first?.id && store.data.workouts.count == beforeFailure.workouts.count, "F4: failed atomic finish preserves draft and does not append a workout")
    var failedProfile = edited; failedProfile.age = 36
    check(!store.saveProfile(failedProfile) && store.data.profile.confirmedAt == nil && store.data.profile == beforeFailure.profile, "F5: failed atomic save does not mark the profile confirmed")
    let unchanged = try JSONDecoder().decode(AppData.self, from: Data(contentsOf: preserved))
    check(unchanged.profile.confirmedAt == nil && unchanged.draft?.sets.first?.id == draft.sets.first?.id, "F4/F5: failed saves leave the prior on-disk draft and unconfirmed profile intact")
    try FileManager.default.removeItem(at: path)
    try FileManager.default.moveItem(at: preserved, to: path)
    check(AppStore().data.draft?.sets.first?.id == draft.sets.first?.id && AppStore().data.profile.confirmedAt == nil, "F4/F5: relaunch restores the preserved state after a write failure")
    print("\(passed) review storage regression checks passed")
    return passed
  }
}
