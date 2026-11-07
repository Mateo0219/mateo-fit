import Foundation

public struct RecordTrash: Codable {
  public var meals: [MealEntry] = []
  public var workouts: [WorkoutEntry] = []
  public var weights: [WeightEntry] = []
  public init() {}
}
public struct FitnessBackup: Codable {
  public var format = "mateo-fit-backup"
  public var version = 1
  public var createdAt = Date()
  public var records: AppData
  public var photos: [String: Data]
  public init(records: AppData, photos: [String: Data]) { self.records = records; self.photos = photos }
}
public enum BackupError: LocalizedError {
  case invalid(String)
  public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
public enum BackupCodec {
  public static func safePhotoName(_ name: String) -> Bool {
    name.hasSuffix(".image") && UUID(uuidString: String(name.dropLast(6))) != nil
  }
  public static func photoNames(_ data: AppData) -> Set<String> {
    let undoMeals = (data.personalAgent?.receipts ?? []).flatMap { $0.before.meals ?? [] }
    return Set((data.meals + (data.trash?.meals ?? []) + undoMeals).compactMap(\.photoName))
  }
  /// Relocate files without treating a restore as a business edit. A receipt is
  /// rebased only when its original digest verifies, including successive undo
  /// states. A pre-existing conflict stops that chain and stays a conflict.
  public static func remapPhotos(in data: inout AppData, names: [String: String]) throws {
    guard photoNames(data).allSatisfy({ names[$0].map(safePhotoName) == true }) else {
      throw BackupError.invalid("撤销记录或餐食的照片缺失，未恢复不完整备份。")
    }
    func remapped(_ meals: [MealEntry]) -> [MealEntry] {
      meals.map { entry in
        var result = entry
        if let old = result.photoName { result.photoName = names[old] }
        return result
      }
    }
    let receipts = data.personalAgent?.receipts ?? []
    var replay = data, verifiedDigests: [UUID: String] = [:]
    for receipt in receipts.reversed() where !receipt.undone {
      var after = AgentUndo.capture(replay, scope: receipt.before.scope, recordIDs: receipt.before.recordIDs)
      guard receipt.before.valid, after.digest == receipt.afterDigest else { break }
      if let meals = after.meals { after.meals = remapped(meals) }
      verifiedDigests[receipt.id] = after.digest
      receipt.before.restore(&replay)
    }
    data.meals = remapped(data.meals)
    if let trash = data.trash { data.trash?.meals = remapped(trash.meals) }
    if data.personalAgent != nil {
      data.personalAgent?.receipts = receipts.map { receipt in
        var before = receipt.before
        if let meals = before.meals { before.meals = remapped(meals) }
        return AgentReceipt(id: receipt.id, date: receipt.date, summary: receipt.summary, before: before,
          afterDigest: verifiedDigests[receipt.id] ?? receipt.afterDigest, undone: receipt.undone)
      }
    }
  }
  public static func validate(_ backup: FitnessBackup) throws {
    func require(_ ok: Bool, _ message: String) throws { if !ok { throw BackupError.invalid(message) } }
    let d = backup.records
    try require(d.trainingSafety?.valid ?? true, "训练暂停状态或恢复时间无效。")
    if let agent = d.personalAgent {
      try require((agent.revision ?? 0) >= 0, "操作版本无效。")
      try require(agent.memories.count <= 1000 && Set(agent.memories.map(\.id)).count == agent.memories.count && agent.memories.allSatisfy(\.valid), "记忆内容或版本无效。")
      try require(agent.operations.count <= 5000 && Set(agent.operations.map(\.id)).count == agent.operations.count && agent.operations.allSatisfy(\.valid), "聊天操作草稿无效。")
      try require(agent.receipts.count <= 20 && Set(agent.receipts.map(\.id)).count == agent.receipts.count && agent.receipts.allSatisfy {
        $0.afterDigest.count == 64 && $0.summary.count <= 2500 && $0.before.valid &&
          ($0.before.memories ?? []).allSatisfy(\.valid) && ($0.before.meals ?? []).allSatisfy { !$0.title.isEmpty && ($0.nutrition?.valid ?? true) }
      }, "操作回执或撤销版本无效。")
      try require(agent.forgotten.allSatisfy { $0.date.timeIntervalSince1970.isFinite } && (agent.historyAfter?.timeIntervalSince1970.isFinite ?? true), "记忆失效时间无效。")
    }
    let threads = d.coachThreads ?? []
    try require(threads.count <= 100 && Set(threads.map(\.id)).count == threads.count && threads.allSatisfy {
      !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 120 && $0.createdAt.timeIntervalSince1970.isFinite && $0.updatedAt.timeIntervalSince1970.isFinite
    }, "对话列表格式无效。")
    try require(d.activeCoachThreadID.map { id in threads.contains { $0.id == id } } ?? threads.isEmpty, "当前对话不存在。")
    try require((d.conversation ?? []).allSatisfy { turn in turn.threadID.map { id in threads.contains { $0.id == id } } ?? true }, "消息缺少所属对话。")
    for thread in threads {
      if thread.id == d.activeCoachThreadID { try require(thread.composer == nil && thread.pendingMeal == nil, "当前对话草稿重复。") }
      if let composer = thread.composer {
        try require(composer.text.count <= 3000 && ["editing", "sending", "interrupted"].contains(composer.state) && (composer.photo.map { !$0.isEmpty && $0.count <= 20_000_000 } ?? true), "对话输入草稿无效。")
      }
      if let meal = thread.pendingMeal {
        try require(meal.valid, "对话餐食草稿无效。")
        if let result = meal.result {
          try result.validate(expectedID: result.request_id)
          try require(meal.analysisInput == meal.description, "对话餐食估计与内容不一致。")
        }
      }
    }
    let pendingIDs = threads.compactMap { $0.pendingMeal?.id } + (d.pendingHomeMeal.map { [$0.id] } ?? [])
    try require(Set(pendingIDs).count == pendingIDs.count && !pendingIDs.contains(where: { id in d.meals.contains { $0.id == id } }), "餐食草稿重复或已提交。")
    try require(d.pendingHomeMeal?.valid ?? true, "待确认餐食草稿无效。")
    if let result = d.pendingHomeMeal?.result {
      try result.validate(expectedID: result.request_id)
      try require(d.pendingHomeMeal?.analysisInput == d.pendingHomeMeal?.description, "餐食估计与草稿不一致。")
    }
    if let composer = d.homeComposer {
      try require(composer.text.count <= 3000 && ["editing", "sending", "interrupted"].contains(composer.state) && (composer.photo.map { !$0.isEmpty && $0.count <= 20_000_000 } ?? true), "首页输入草稿无效。")
    }
    try require((d.coachJobCleanup?.count ?? 0) <= 2000 && (d.coachJobCleanup ?? []).allSatisfy(\.valid), "后台任务清理记录无效。")
    try require((d.conversation ?? []).filter { $0.remoteJob != nil }.count <= 4, "后台任务数量无效。")
    try require((d.homeCommitIDs?.count ?? 0) <= 2000 && Set(d.homeCommitIDs ?? []).count == (d.homeCommitIDs?.count ?? 0), "确认事务记录无效。")
    try require((d.conversation?.count ?? 0) <= 200 && (d.conversation ?? []).allSatisfy(\.valid) && Set((d.conversation ?? []).map(\.id)).count == (d.conversation?.count ?? 0), "教练对话格式无效。")
    try require(backup.format == "mateo-fit-backup" && backup.version == 1 && d.version == 1, "不支持的备份版本。")
    try require((18...100).contains(d.profile.age) && (100...250).contains(d.profile.heightCM) && DataMath.validWeight(d.profile.initialWeightKG), "备份档案数值无效。")
    let weights = d.weights + (d.trash?.weights ?? [])
    let meals = d.meals + (d.trash?.meals ?? [])
    let workouts = d.workouts + (d.trash?.workouts ?? [])
    try require(Set(weights.map(\.id)).count == weights.count && weights.allSatisfy { !$0.id.isEmpty && DataMath.validWeight($0.kg) }, "体重记录无效或重复。")
    try require(Set(meals.map(\.id)).count == meals.count && meals.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "餐食记录无效或重复。")
    try require(meals.allSatisfy { $0.nutrition?.valid ?? true }, "餐食营养数据无效。")
    try require(Set(workouts.map(\.id)).count == workouts.count && workouts.allSatisfy { (1...1440).contains($0.minutes) && !$0.name.isEmpty }, "训练记录无效或重复。")
    let sets = workouts.flatMap(\.sets) + (d.draft?.sets ?? [])
    try require(Set(sets.map(\.id)).count == sets.count && sets.allSatisfy { !$0.exercise.isEmpty && $0.kg.isFinite && (0...1000).contains($0.kg) && (1...500).contains($0.reps) }, "训练组记录无效。")
    if let state = d.training {
      try require(state.revision >= 0 && state.sequenceIndex >= 0 && Set(state.profiles.map(\.id)).count == state.profiles.count && state.profiles.allSatisfy(\.valid), "动作能力档案无效或重复。")
      for item in sets where item.profileID != nil {
        try require(state.profiles.contains { $0.id == item.profileID && $0.exerciseID == item.exerciseID } && (item.profileRevision ?? 0) > 0, "训练记录缺少关联动作档案或版本。")
        try require(item.rir.map { (0...10).contains($0) } ?? true, "余力反馈无效。")
        try require(["标准完成", "动作变形", "疼痛", "不确定"].contains(item.form ?? "") && ["工作组", "热身组"].contains(item.setKind ?? ""), "动作反馈无效。")
      }
      for target in d.draft?.targets ?? [] {
        try require(state.profiles.contains { $0.id == target.profileID } && (1...3).contains(target.sets) && (1...100).contains(target.reps) && (target.kg.map { $0.isFinite && (0...1000).contains($0) } ?? true), "草稿目标无效。")
      }
    } else { try require(sets.allSatisfy { $0.profileID == nil }, "备份缺少动作档案。") }
    try require(Set(d.sleep.map(\.id)).count == d.sleep.count && d.sleep.allSatisfy { $0.end > $0.start }, "睡眠记录无效或重复。")
    if let c = d.coach {
      try require(c.revision >= 0 && (1...120).contains(c.preferences.workoutMinutes) && (1...120).contains(c.preferences.cookingMinutes) && c.preferences.trainingWeekdays.allSatisfy { (1...7).contains($0) }, "计划设置无效。")
    }
    if let c = d.coach, c.preferences.programID == StrengthProgram.id {
      try require(StrengthProgram.validDays(c.preferences.trainingWeekdays) && StrengthProgram.phases.contains(c.preferences.trainingPhase ?? "恢复适应"), "完整训练计划的阶段或训练日无效。")
    }
    for item in d.draft?.planned ?? [] {
      try require(TrainingLibrary.guide(item.exerciseID) != nil && (1...3).contains(item.sets) && (item.restSeconds.map { (30...300).contains($0) } ?? true), "计划动作或休息时间无效。")
      if let lower = item.lowerReps, let upper = item.upperReps { try require(lower >= 1 && upper >= lower && upper <= 30, "计划次数范围无效。") }
    }
    let names = photoNames(d)
    try require(names.allSatisfy(safePhotoName) && Set(backup.photos.keys) == names, "备份照片缺失或文件名无效。")
    let draftBytes = (d.conversation ?? []).reduce(0) { $0 + ($1.photo?.count ?? 0) } + (d.homeComposer?.photo?.count ?? 0) + (d.pendingHomeMeal?.photo?.count ?? 0) + threads.reduce(0) { $0 + ($1.composer?.photo?.count ?? 0) + ($1.pendingMeal?.photo?.count ?? 0) }
    try require(backup.photos.values.allSatisfy { !$0.isEmpty && $0.count <= 20_000_000 } && backup.photos.values.reduce(draftBytes) { $0 + $1.count } <= 80_000_000, "照片备份超过大小限制（单张 20 MB / 合计 80 MB）。")
  }
  public static func encode(_ backup: FitnessBackup) throws -> Data {
    try validate(backup)
    return try JSONEncoder().encode(backup)
  }
  public static func decode(_ bytes: Data) throws -> FitnessBackup {
    guard bytes.count <= 150_000_000 else { throw BackupError.invalid("备份超过 150 MB，暂不支持导入。") }
    let result = try JSONDecoder().decode(FitnessBackup.self, from: bytes)
    try validate(result)
    return result
  }
}
