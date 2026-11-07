import FitnessCore
import Foundation
import SwiftUI

@MainActor final class AppStore: ObservableObject {
  static let shared = AppStore()
  @Published var healthStatus = "打开 App 自动更新"
  @Published private(set) var data: AppData
  @Published var alert: String?
  @Published var healthBusy = false
  private var loadFailed = false
  private let directory: URL
  private let url: URL
  var storagePath: String { directory.path }
  init() {
    if let override = ProcessInfo.processInfo.environment["XUXU_DATA_DIR"] ?? Bundle.main.object(
      forInfoDictionaryKey: "XuXuDataDirectory") as? String
    {
      directory = URL(fileURLWithPath: override)
    } else {
      directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
        0
      ].appendingPathComponent("XuXu", isDirectory: true)
    }
    url = directory.appendingPathComponent("records-v1.json")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: url.path) {
        data = try JSONDecoder().decode(AppData.self, from: Data(contentsOf: url))
      } else {
        data = AppData()
      }
      let migratedSafety = TrainingSafety.migrateLegacy(&data)
      let interrupted = CoachThreads.interruptUnfinished(&data)
      if migratedSafety || interrupted {
        let restored = try JSONEncoder().encode(data)
        #if os(iOS)
        try restored.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try restored.write(to: url, options: .atomic)
        #endif
      }
    } catch {
      data = AppData()
      loadFailed = true
      alert = "记录暂时无法读取，原文件已保留：\(error.localizedDescription)"
    }
  }
  func retryProtectedLoad() {
    guard loadFailed else { return }
    do {
      var next = try JSONDecoder().decode(AppData.self, from: Data(contentsOf: url))
      let migratedSafety = TrainingSafety.migrateLegacy(&next)
      let interrupted = CoachThreads.interruptUnfinished(&next)
      if migratedSafety || interrupted { try protectedWrite(try JSONEncoder().encode(next), to: url) }
      data = next
      loadFailed = false
      alert = nil
    } catch { return }
  }
  @discardableResult func change(_ edit: (inout AppData) -> Void) -> Bool {
    guard !loadFailed else {
      alert = "原始记录无法读取，为保护数据已暂停写入。请先恢复备份。"
      return false
    }
    var next = data
    _ = TrainingSafety.migrateLegacy(&next)
    edit(&next)
    // Any change to today's meal evidence invalidates the previous completeness confirmation.
    let oldMeals = data.meals.filter { Calendar.current.isDateInToday($0.date) }
    let newMeals = next.meals.filter { Calendar.current.isDateInToday($0.date) }
    if oldMeals != newMeals { next.foodDiaryCompleteAt = nil }
    do {
      let bytes = try JSONEncoder().encode(next)
      #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
      #else
        try bytes.write(to: url, options: .atomic)
      #endif
      data = next
      return true
    } catch {
      alert = "保存失败，未覆盖已有记录：\(error.localizedDescription)"
      return false
    }
  }
  @discardableResult func addConversation(_ turn: CoachTurn) -> Bool {
    guard turn.valid else { return false }
    return change { CoachThreads.record(turn, into: &$0) }
  }
  func prepareCoachThreads() {
    if data.coachThreads == nil { _ = change { CoachThreads.prepare(&$0) } }
  }
  @discardableResult func newCoachThread() -> Bool {
    let emptyCurrent = !CoachThreads.hasHistory(data, in: data.activeCoachThreadID ?? CoachThreads.legacyID)
    if emptyCurrent {
      return change { data in
        CoachThreads.prepare(&data)
        if let index = data.coachThreads?.firstIndex(where: { $0.id == data.activeCoachThreadID }) {
          // Unsent input remains a draft on the new-chat surface, outside history.
          data.coachThreads?[index].title = "新对话"
        }
      }
    }
    // Returning from an existing conversation resumes the unsent new-chat draft.
    // Reuse a blank slot as well, so repeated navigation cannot fill the thread limit.
    let reusable = (data.coachThreads ?? []).filter { !$0.archived && !CoachThreads.hasHistory(data, in: $0.id) }.sorted {
      let leftHasDraft = !($0.composer?.text.isEmpty ?? true) || $0.composer?.photo != nil
      let rightHasDraft = !($1.composer?.text.isEmpty ?? true) || $1.composer?.photo != nil
      return leftHasDraft != rightHasDraft ? leftHasDraft : $0.updatedAt > $1.updatedAt
    }.first
    if let reusable { return change { _ = CoachThreads.switchTo(reusable.id, data: &$0) } }
    guard (data.coachThreads?.count ?? 0) < 100 else { alert = "已保存 100 段对话。可先导出备份，再打开并清空一段不需要的对话，继续使用。"; return false }
    return change {
      CoachThreads.prepare(&$0)
      let thread = CoachThread(); $0.coachThreads?.append(thread)
      _ = CoachThreads.switchTo(thread.id, data: &$0)
    }
  }
  @discardableResult func selectCoachThread(_ id: UUID) -> Bool {
    guard data.coachThreads?.contains(where: { $0.id == id }) == true else { return false }
    return change {
      _ = CoachThreads.switchTo(id, data: &$0)
      if let index = $0.coachThreads?.firstIndex(where: { $0.id == id }) { $0.coachThreads?[index].archived = false }
    }
  }
  func renameCoachThread(_ id: UUID, title: String) {
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 120 else { return }
    _ = change { if let index = $0.coachThreads?.firstIndex(where: { $0.id == id }) { $0.coachThreads?[index].title = name } }
  }
  func pinCoachThread(_ id: UUID) {
    _ = change { if let index = $0.coachThreads?.firstIndex(where: { $0.id == id }) { $0.coachThreads?[index].pinned.toggle() } }
  }
  func archiveCoachThread(_ id: UUID) {
    guard id != data.activeCoachThreadID || (data.coachThreads?.count ?? 0) < 100 else { alert = "对话数量已达上限，请先导出备份。"; return }
    _ = change {
      if let index = $0.coachThreads?.firstIndex(where: { $0.id == id }) { $0.coachThreads?[index].archived = true }
      if $0.activeCoachThreadID == id {
        let next = CoachThread(); $0.coachThreads?.append(next)
        _ = CoachThreads.switchTo(next.id, data: &$0)
      }
    }
  }
  func clearCurrentCoachConversation() {
    _ = change { data in
      let id = data.activeCoachThreadID ?? CoachThreads.legacyID
      for turn in CoachThreads.turns(data, in: id) {
        if let job = turn.remoteJob { CoachBackgroundJobs.enqueue(job, action: "cancel", data: &data) }
      }
      data.conversation = data.conversation?.filter { ($0.threadID ?? CoachThreads.legacyID) != id }
    }
  }
  @discardableResult func saveProfile(_ p: Profile) -> Bool {
    guard (18...100).contains(p.age), p.heightCM.isFinite, (100...250).contains(p.heightCM), DataMath.validWeight(p.initialWeightKG) else {
      alert = "请检查年龄、身高和体重。"; return false
    }
    return change { $0.profile = p; $0.profile.confirmedAt = Date() }
  }
  @discardableResult func saveComposer(text: String, photo: Data?, state: String = "editing") -> Bool {
    guard text.count <= 3000, photo.map({ !$0.isEmpty && $0.count <= 20_000_000 }) ?? true,
      ["editing", "sending", "interrupted"].contains(state) else { return false }
    return change { var draft = HomeComposerDraft(); draft.text = text; draft.photo = photo; draft.state = state; $0.homeComposer = draft }
  }
  @discardableResult func confirmAssistant(turnID: UUID, candidateID: String) -> Bool {
    var next = data
    do { try AssistantTransactions.confirm(turnID: turnID, candidateID: candidateID, data: &next) }
    catch { alert = "记录、当天状态或计划已经变化，或该调整已采用。请重新让教练评估。"; return false }
    return change { $0 = next }
  }
  @discardableResult func setHomeMeal(_ draft: HomeMealDraft) -> Bool {
    guard draft.valid,
      !(data.homeCommitIDs ?? []).contains(draft.id.uuidString),
      !data.meals.contains(where: { $0.id == draft.id }) else { return false }
    return change { $0.pendingHomeMeal = draft }
  }
  @discardableResult func confirmHomeMeal(_ draft: HomeMealDraft) -> Bool {
    guard data.pendingHomeMeal?.id == draft.id, draft.valid,
      draft.date <= Date(),
      !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !(data.homeCommitIDs ?? []).contains(draft.id.uuidString),
      !data.meals.contains(where: { $0.id == draft.id }),
      draft.result == nil || draft.analysisInput == draft.description else {
      alert = "餐食已保存或内容已经变化，请重新核对。"; return false
    }
    let name = draft.photo == nil ? nil : draft.id.uuidString + ".image"
    do { if let photo = draft.photo, let name { try protectedWrite(photo, to: directory.appendingPathComponent(name)) } }
    catch { alert = "照片保存失败，草稿已保留。"; return false }
    let saved = change { data in
      data.meals.append(MealEntry(id: draft.id, date: draft.date, title: draft.title, note: draft.description + (draft.result.map { "\n" + $0.reviewNote } ?? ""), photoName: name, nutrition: draft.nutrition))
      data.pendingHomeMeal = nil
      data.homeCommitIDs = Array(((data.homeCommitIDs ?? []) + [draft.id.uuidString]).suffix(2000))
      if let source = draft.sourceTurnID, let index = data.conversation?.firstIndex(where: { $0.id == source }) {
        data.conversation?[index].reply = "已保存这餐并更新当日汇总。"
        data.conversation?[index].outcome = "已保存：" + String(draft.title.prefix(150))
        data.conversation?[index].requiresSummaryConsent = true
      } else {
      var turn = CoachTurn(text: String((draft.description.isEmpty ? "记录餐食照片" : draft.description).prefix(3000)), reply: "已保存这餐并更新当日汇总。", actions: [.meal, .records], origin: "本机确认结果")
      turn.requiresSummaryConsent = true
      turn.outcome = "已确认吃过：" + String(draft.title.prefix(150))
      CoachThreads.record(turn, into: &data)
      }
    }
    if !saved, let name { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    return saved
  }
  func toggleFood(_ id: String) {
    _ = change {
      if $0.pantry.contains(id) { $0.pantry.remove(id) } else { $0.pantry.insert(id) }
      $0.pantryConfirmedAt = nil
    }
  }
  func confirmPantry() { _ = change { $0.pantryConfirmedAt = Date() } }
  func addWeight(_ value: Double) -> Bool {
    guard DataMath.validWeight(value) else {
      alert = "请输入有效的体重（kg）。"
      return false
    }
    return change { $0.weights.append(WeightEntry(kg: value)) }
  }
  func addMeal(title: String, note: String, photo: Data?, nutrition: MealNutrition? = nil) -> Bool {
    guard nutrition?.valid ?? true else { alert = "请检查营养数据；按每 100 克填写时，还需要实际吃下的克数。"; return false }
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      alert = "先写一下这餐吃了什么。"
      return false
    }
    let id = UUID()
    var photoName: String?
    if let photo {
      guard !photo.isEmpty, photo.count <= 20_000_000 else { alert = "照片需为 20 MB 以内的非空图片。"; return false }
      photoName = id.uuidString + ".image"
      do {
        #if os(iOS)
          try photo.write(
            to: directory.appendingPathComponent(photoName!),
            options: [.atomic, .completeFileProtection])
        #else
          try photo.write(to: directory.appendingPathComponent(photoName!), options: .atomic)
        #endif
      } catch {
        alert = "照片保存失败：\(error.localizedDescription)"
        return false
      }
    }
    let saved = change {
      $0.meals.append(MealEntry(id: id, title: name, note: note, photoName: photoName, nutrition: nutrition))
    }
    if !saved, let photoName { try? FileManager.default.removeItem(at: directory.appendingPathComponent(photoName)) }
    return saved
  }
  func photo(_ name: String) -> Data? {
    guard BackupCodec.safePhotoName(name) else { return nil }
    return try? Data(contentsOf: directory.appendingPathComponent(name))
  }
  func beginWorkout(name: String) {
    guard data.draft == nil, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    _ = change {
      var draft = WorkoutDraft()
      draft.name = name
      $0.draft = draft
    }
  }
  func addSet(exercise: String, kg: Double, reps: Int) {
    guard !exercise.trimmingCharacters(in: .whitespaces).isEmpty, kg.isFinite, kg >= 0, kg <= 1000,
      reps > 0, reps <= 500
    else {
      alert = "请检查动作、重量和次数。"
      return
    }
    _ = change {
      guard $0.draft != nil else { return }
      $0.draft?.sets.append(SetEntry(exercise: exercise, kg: kg, reps: reps))
      $0.draft?.restUntil = Date().addingTimeInterval(90)
    }
  }
  func workoutNeedsDurationConfirmation(now: Date = Date()) -> Bool {
    guard let draft = data.draft else { return false }
    let elapsed = now.timeIntervalSince(draft.started)
    return !elapsed.isFinite || elapsed < 0 || elapsed > 120 * 60 || !Calendar.current.isDate(draft.started, inSameDayAs: now)
  }
  @discardableResult func finishWorkout(effort: String, actualMinutes: Int? = nil, now: Date = Date()) -> Bool {
    guard let draft = data.draft else { return false }
    guard !draft.sets.isEmpty else { alert = "还没有完成的组数；可取消空草稿，或用活动记录保存乒乓球等运动。"; return false }
    guard draft.started.timeIntervalSince1970.isFinite, draft.started <= now else {
      alert = "训练开始时间异常，请核对后再保存。草稿已保留。"; return false
    }
    guard !workoutNeedsDurationConfirmation(now: now) || actualMinutes != nil else {
      alert = "这次训练跨日或计时较长，请核对实际训练分钟数后保存。草稿已保留。"; return false
    }
    let minutes = actualMinutes ?? max(1, Int(now.timeIntervalSince(draft.started) / 60))
    guard (1...1440).contains(minutes) else { alert = "请输入 1–1440 分钟的实际训练时长。草稿已保留。"; return false }
    let entry = WorkoutEntry(
      date: draft.started, name: draft.name, sets: draft.sets, effort: effort, minutes: minutes)
    return change {
      $0.workouts.append(entry)
      if let slot = draft.sequenceSlot, TrainingProgression.planCompleted(draft, state: $0.training) {
        if $0.training == nil { $0.training = TrainingState() }
        if ($0.training!.sequenceIndex % 3) == slot { $0.training?.sequenceIndex += 1 }
      }
      $0.draft = nil
    }
  }
  func endRest() { _ = change { $0.draft?.restUntil = nil } }
  var todayMeals: [MealEntry] { data.meals.filter { Calendar.current.isDateInToday($0.date) && $0.date <= Date() && $0.confirmed } }
  var recentWorkouts: [WorkoutEntry] { data.workouts.sorted { $0.date > $1.date } }
  var latestWeight: WeightEntry? { data.weights.max { $0.date < $1.date } }
}

extension AppStore {
  func savePreferences(_ preferences: CoachPreferences) -> Bool {
    if preferences.programID == StrengthProgram.id {
      guard StrengthProgram.validDays(preferences.trainingWeekdays), StrengthProgram.phases.contains(preferences.trainingPhase ?? "恢复适应") else {
        alert = "完整计划请选择 3 个不相邻的力量训练日（包括跨周间隔）；第 4 次恢复训练不选为力量日。"; return false
      }
    }
    if data.draft != nil && (preferences.programID != data.coach?.preferences.programID || preferences.trainingPhase != data.coach?.preferences.trainingPhase) {
      alert = "请先保存或取消当前训练，再切换训练方案或阶段；已完成记录会保留。"; return false
    }
    guard preferences.experience != "未确认", preferences.equipment != "未确认", preferences.restrictions != "未确认", !preferences.trainingWeekdays.isEmpty else {
      alert = "请确认经验、器械、限制和至少一个训练日。"; return false
    }
    return change { data in
      var state = data.coach ?? CoachState(), next = preferences
      if next.programID != state.preferences.programID || next.trainingPhase != state.preferences.trainingPhase {
        state.checkIn = nil // A new plan must not inherit an old short-session readiness check.
      }
      next.confirmedAt = Date(); state.revision += 1
      state.changes.append(PlanChange(before: state.preferences, after: next, reason: "你主动更新训练条件", evidence: [], revision: state.revision))
      state.preferences = next; data.coach = state; data.profile.weeklyGymDays = next.trainingWeekdays.count
    }
  }
  func saveCheckIn(_ check: DailyCheckIn) -> Bool {
    applyDailyCheck(check)
  }
  func feedback(_ kind: String, _ reason: String) {
    _ = change { if $0.coach == nil { $0.coach = CoachState() }; $0.coach?.feedback.append(CoachFeedback(kind: kind, reason: reason)) }
  }
  func startPlan() -> Bool {
    let plan = DailyPlanner.plan(data)
    guard plan.status == "ready", data.draft == nil else { alert = "请先确认今天状态，或完成现有训练。"; return false }
    return change { var draft = WorkoutDraft(); draft.name = plan.title; draft.programID = $0.coach?.preferences.programID; draft.planned = plan.exercises; draft.sequenceSlot = ($0.training?.sequenceIndex ?? 0) % 3; $0.draft = draft }
  }
  func repeatWorkout(_ workout: WorkoutEntry) -> Bool {
    guard data.draft == nil else { alert = "已有进行中的训练，请先完成或取消。"; return false }
    guard !TrainingSafety.isPaused(data) else { alert = TrainingSafety.message; return false }
    return change { var draft = WorkoutDraft(); draft.name = workout.name; draft.referenceSets = workout.sets; $0.draft = draft }
  }
  func applyReview(_ review: WeeklyReview) -> Bool {
    var candidate = data
    do { try ReviewEngine.apply(review, to: &candidate) }
    catch { alert = "记录或计划已经变化，请重新打开本周复盘。"; return false }
    return change { $0.coach = candidate.coach }
  }
  func undoLatestPlan() {
    guard let state = data.coach, let last = state.changes.last else { return }
    _ = change { data in
      var c = state; c.revision += 1
      c.changes.append(PlanChange(before: c.preferences, after: last.before, reason: "撤回上一项调整", evidence: [last.id.uuidString], revision: c.revision))
      c.preferences = last.before; data.coach = c
      data.profile.weeklyGymDays = c.preferences.trainingWeekdays.count
    }
  }
  func backupBytes() throws -> Data {
    guard !loadFailed else { throw BackupError.invalid("原始记录尚无法读取，请先解锁并重试。") }
    var photos: [String: Data] = [:]
    for name in BackupCodec.photoNames(data) {
      guard BackupCodec.safePhotoName(name), let bytes = photo(name) else { throw BackupError.invalid("有照片无法读取，未生成不完整备份。") }
      photos[name] = bytes
    }
    return try BackupCodec.encode(FitnessBackup(records: data, photos: photos))
  }
  func restore(_ backup: FitnessBackup) -> Bool {
    guard !healthBusy else { alert = "正在同步健康数据，请等同步结束后再恢复。"; return false }
    var created: [URL] = []
    do {
      try BackupCodec.validate(backup)
      // Preserve a complete rollback file before touching live data. It is never overwritten.
      let recovery = directory.appendingPathComponent("before-restore-\(UUID().uuidString).json")
      if loadFailed {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.copyItem(at: url, to: recovery) }
      } else { try protectedWrite(try backupBytes(), to: recovery) }
      var next = backup.records
      TrainingSafety.preservePause(from: data, in: &next)
      CoachBackgroundJobs.prepareRestore(&next, current: data)
      CoachThreads.interruptUnfinished(&next)
      var names: [String: String] = [:]
      for (old, bytes) in backup.photos {
        let name = UUID().uuidString + ".image", target = directory.appendingPathComponent(UUID().uuidString + ".staged")
        try protectedWrite(bytes, to: target); created.append(target)
        let final = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: target, to: final); created.append(final)
        names[old] = name
      }
      try BackupCodec.remapPhotos(in: &next, names: names)
      // Anchors are device-local; replay the next HealthKit query by sample UUID.
      next.healthAnchors = [:]; next.healthSyncedAt = nil; next.lastHealthSummary = nil
      next.healthAutoSyncEnabled = data.healthAutoSyncEnabled
      next.coach?.checkIn = nil; next.pantryConfirmedAt = nil; next.foodDiaryCompleteAt = nil
      next.draft?.restUntil = nil
      try protectedWrite(try JSONEncoder().encode(next), to: url)
      data = next; loadFailed = false
      alert = "恢复完成。原记录已另存恢复前备份；请重新确认今天状态与食材。"
      return true
    } catch {
      for path in created { try? FileManager.default.removeItem(at: path) }
      alert = "恢复失败，原记录未被覆盖：\(error.localizedDescription)"; return false
    }
  }
  private func protectedWrite(_ bytes: Data, to target: URL) throws {
    #if os(iOS)
    try bytes.write(to: target, options: [.atomic, .completeFileProtection])
    #else
    try bytes.write(to: target, options: .atomic)
    #endif
  }
  var recoveryFiles: [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []).filter { $0.lastPathComponent.hasPrefix("before-restore-") }.sorted {
      ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
    }
  }
  func recoveryBackup(_ file: URL) throws -> FitnessBackup { try BackupCodec.decode(Data(contentsOf: file)) }
  func deleteMeal(_ item: MealEntry) { _ = change { if $0.trash == nil { $0.trash = RecordTrash() }; $0.trash?.meals.append(item); $0.meals.removeAll { $0.id == item.id } } }
  func deleteWorkout(_ item: WorkoutEntry) { _ = change { if $0.trash == nil { $0.trash = RecordTrash() }; $0.trash?.workouts.append(item); $0.workouts.removeAll { $0.id == item.id } } }
  func deleteWeight(_ item: WeightEntry) {
    guard item.source == "手动记录" else { alert = "请在 Apple 健康或来源 App 中修改测量记录，随后会同步更新。"; return }
    _ = change { if $0.trash == nil { $0.trash = RecordTrash() }; $0.trash?.weights.append(item); $0.weights.removeAll { $0.id == item.id } }
  }
}
