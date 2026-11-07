import Foundation

public struct AgentOperationInput: Codable {
  public var kind: String
  public var source_text: String
  public var evidence_ids: [String] = []
  public var target_id: String?
  public var content: String?
  public var topic: String?
  public var expires_at: String?
  public var exercise: String?
  public var exercise_id: String?
  public var kg: Double?
  public var reps: Int?
  public var count: Int?
  public var minutes: Int?
  public var energy: String?
  public var context: String?
  public init(kind: String, sourceText: String) { self.kind = kind; self.source_text = sourceText }
  public static let kinds = ["remember", "updateMemory", "forgetMemory", "updateToday", "logSet", "correctSet", "finishWorkout", "logMeal", "correctMeal", "substituteExercise"]
  public var valid: Bool {
    Self.kinds.contains(kind) && !source_text.isEmpty && source_text.count <= 3000 && evidence_ids.count <= 64 &&
      (target_id?.count ?? 0) <= 100 && (content?.count ?? 0) <= 500 && (exercise?.count ?? 0) <= 100 &&
      (topic.map(MemoryRules.topics.contains) ?? true) && (kg.map { $0.isFinite && (0...1000).contains($0) } ?? true) &&
      (reps.map { (1...500).contains($0) } ?? true) && (count.map { (1...10).contains($0) } ?? true) &&
      (minutes.map { (1...120).contains($0) } ?? true) &&
      (energy.map { ["状态正常", "有点疲惫", "不适或困倦"].contains($0) } ?? true) &&
      (context.map { ["健身房", "在家", "乒乓球", "休息"].contains($0) } ?? true) &&
      (expires_at.map { ISO8601DateFormatter().date(from: $0) != nil } ?? true)
  }
}
public struct AgentOperation: Codable, Identifiable {
  public var id = UUID()
  public var turnID: UUID
  public var input: AgentOperationInput
  public var createdAt = Date()
  public var timezone = TimeZone.current.identifier
  public var fingerprint: String
  public var status = "pending"
  public var summary: String
  public var grounding: String
  public var edited = false
  public init(turnID: UUID, input: AgentOperationInput, fingerprint: String, summary: String, grounding: String) {
    self.turnID = turnID; self.input = input; self.fingerprint = fingerprint; self.summary = summary; self.grounding = grounding
  }
  public var valid: Bool { input.valid && fingerprint.count == 64 && summary.count <= 2000 && grounding.count <= 15000 && ["pending", "applied", "cancelled", "undone"].contains(status) }
}
// Undo captures only affected domains, and is accepted only while those domains
// still match the committed result. It never overwrites later edits.
public struct AgentUndo: Codable {
  public var scope: String
  public var recordIDs: [UUID]?
  public var memories: [PersonalMemory]?
  public var meals: [MealEntry]?
  public var draft: WorkoutDraft?
  public var workouts: [WorkoutEntry]?
  public var coach: CoachState?
  public var training: TrainingState?
  public var valid: Bool {
    guard ["memory", "meal", "training"].contains(scope), (memories ?? []).allSatisfy(\.valid),
      (meals ?? []).allSatisfy({ !$0.title.isEmpty && ($0.nutrition?.valid ?? true) && (recordIDs?.contains($0.id) ?? true) }),
      (workouts ?? []).allSatisfy({ !$0.name.isEmpty && (1...1440).contains($0.minutes) && (recordIDs?.contains($0.id) ?? true) }),
      (training?.profiles ?? []).allSatisfy(\.valid) else { return false }
    let sets = (draft?.sets ?? []) + (workouts ?? []).flatMap(\.sets)
    return sets.allSatisfy { !$0.exercise.isEmpty && $0.kg.isFinite && (0...1000).contains($0.kg) && (1...500).contains($0.reps) } && Set(sets.map(\.id)).count == sets.count
  }
  public static func capture(_ data: AppData, scope: String, recordIDs: [UUID]? = nil) -> AgentUndo {
    var result = AgentUndo(scope: scope)
    result.recordIDs = recordIDs
    if scope == "memory" { result.memories = data.personalAgent?.memories ?? [] }
    if scope == "meal" { result.meals = data.meals.filter { recordIDs?.contains($0.id) ?? true } }
    if scope == "training" { result.draft = data.draft; result.workouts = data.workouts.filter { recordIDs?.contains($0.id) ?? true }; result.coach = data.coach; result.training = data.training }
    return result
  }
  public var digest: String { AssistantContext.digest(ReviewEngine.canonical(self)) }
  public func restore(_ data: inout AppData) {
    if scope == "memory" { data.personalAgent?.memories = memories ?? [] }
    if scope == "meal" { data.meals = data.meals.filter { !(recordIDs?.contains($0.id) ?? true) } + (meals ?? []); data.foodDiaryCompleteAt = nil }
    if scope == "training" { data.draft = draft; data.workouts = data.workouts.filter { !(recordIDs?.contains($0.id) ?? true) } + (workouts ?? []); data.coach = coach; data.training = training }
  }
}
public struct AgentReceipt: Codable, Identifiable {
  public let id: UUID
  public let date: Date
  public var summary: String
  public let before: AgentUndo
  public let afterDigest: String
  public var undone = false
}
public enum AgentOperationError: LocalizedError {
  case rejected(String)
  public var errorDescription: String? { if case .rejected(let message) = self { return message }; return nil }
}
public enum AgentOperations {
  private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw AgentOperationError.rejected(message) } }
  public static func recordDate(text: String, now: Date) -> Date {
    let calendar = Calendar.current
    let pattern = #"\d{4}-\d{2}-\d{2}"#
    if let range = text.range(of: pattern, options: .regularExpression) {
      let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
      if let value = f.date(from: String(text[range])) { return value }
    }
    return calendar.date(byAdding: .day, value: text.contains("前天") ? -2 : text.contains("昨天") ? -1 : 0, to: now) ?? now
  }
  private static func mentioned(_ value: Double, in text: String) -> Bool {
    let pattern = #"(?<![\d.])\d+(?:\.\d+)?(?![\d.])"#
    let regex = try! NSRegularExpression(pattern: pattern)
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains { match in
      Range(match.range, in: text).flatMap { Double(text[$0]) }.map { abs($0 - value) < 0.00001 } ?? false
    } || chinese(value, in: text)
  }
  private static func chinese(_ value: Double, in text: String) -> Bool {
    guard value == value.rounded(), (1...120).contains(value) else { return false }
    let n = Int(value), digits = ["零","一","二","三","四","五","六","七","八","九"]
    let chinese = n < 10 ? digits[n] : n < 100 ? (n / 10 == 1 ? "十" : digits[n / 10] + "十") + (n % 10 == 0 ? "" : digits[n % 10]) : n == 100 ? "一百" : ""
    let forms = n == 2 ? [chinese, "两"] : [chinese]
    return forms.filter { !$0.isEmpty }.contains { text.range(of: "(?<![零一二三四五六七八九十百两])" + $0 + "(?![零一二三四五六七八九十百两])", options: .regularExpression) != nil }
  }
  public static func scope(_ kind: String) -> String {
    if ["remember", "updateMemory", "forgetMemory"].contains(kind) { return "memory" }
    return ["logMeal", "correctMeal"].contains(kind) ? "meal" : "training"
  }
  public static func stage(_ input: AgentOperationInput, turn: CoachTurn, data: AppData, allowedTargets: Set<String>? = nil, now: Date = Date()) throws -> AgentOperation {
    try require(input.valid && turn.text.contains(input.source_text), "操作缺少本次明确表达的依据，请重新说明。")
    if let target = input.target_id, let allowedTargets { try require(allowedTargets.contains(target), "目标记录未在本次授权范围中，请在记录中选择。") }
    let history = CoachThreads.turns(data, in: turn.threadID).filter { $0.date > (data.personalAgent?.historyAfter ?? .distantPast) }.suffix(4).map(\.text)
    var operation = AgentOperation(turnID: turn.id, input: input, fingerprint: AssistantContext.fingerprint(data), summary: "", grounding: String((history + [turn.text]).joined(separator: "\n").suffix(15000)))
    operation.createdAt = now
    operation.summary = try preview(operation, data: data, now: now)
    return operation
  }
  public static func fresh(_ operation: AgentOperation, data: AppData, now: Date = Date()) -> Bool {
    operation.status == "pending" && operation.createdAt <= now && now.timeIntervalSince(operation.createdAt) < 86400 &&
      Calendar.current.isDate(operation.createdAt, inSameDayAs: now) && operation.timezone == TimeZone.current.identifier &&
      operation.fingerprint == AssistantContext.fingerprint(data)
  }
  public static func preview(_ operation: AgentOperation, data: AppData, now: Date = Date()) throws -> String {
    let p = operation.input, text = operation.grounding
    try require(p.valid, "这项操作的字段无效。")
    let target = p.target_id?.split(separator: ".").last.flatMap { UUID(uuidString: String($0)) }
    if !operation.edited {
      for value in [p.kg, p.reps.map(Double.init), p.count.map(Double.init), p.minutes.map(Double.init)].compactMap({ $0 }) { try require(mentioned(value, in: text), "数值缺少你的原话依据，请补充或手动修改。") }
      if p.kg != nil { try require(["kg", "公斤", "千克"].contains { text.lowercased().contains($0) }, "请确认重量单位为 kg；单只或总重沿用你说明的口径。") }
    }
    switch p.kind {
    case "remember", "updateMemory":
      guard let content = p.content, let topic = p.topic else { throw AgentOperationError.rejected("请补充要记住的内容。") }
      try require(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "记忆不能为空。")
      try require(operation.edited || text.contains(content), "记忆必须来自你的明确原话，不能保存推断。")
      try require(!(data.coachThreads?.first { $0.id == data.conversation?.first(where: { $0.id == operation.turnID })?.threadID }?.noLongTermMemory ?? false), "这个会话不形成长期记忆。")
      if MemoryRules.sensitive(content) { try require(topic == "health_constraint" || topic == "temporary", "健康限制需要单独核对，不能归入普通偏好。") }
      if let expiry = p.expires_at.flatMap({ ISO8601DateFormatter().date(from: $0) }) { try require(expiry > now, "有效时间已经过期。") }
      if topic == "temporary" { try require(p.expires_at != nil, "临时信息需要明确有效时间。") }
      if p.kind == "updateMemory" {
        guard let old = data.personalAgent?.memories.first(where: { $0.id == target }) else { throw AgentOperationError.rejected("原记忆已不存在。") }
        return "记忆：\(old.content) → \(content)\n只修改记忆，不会改写正式记录或训练计划。"
      }
      let related = (data.personalAgent?.memories ?? []).filter { $0.active(at: now) && $0.topic == topic && $0.content != content }
      return content + (related.isEmpty ? "" : "\n已有：" + related.prefix(3).map(\.content).joined(separator: "；") + "\n新增不会覆盖其他记忆；要更正旧内容请点“修改”选择原记忆。") + (p.expires_at.map { "\n有效至：" + $0 } ?? "")
    case "forgetMemory":
      guard let memory = data.personalAgent?.memories.first(where: { $0.id == target }) else { throw AgentOperationError.rejected("这条记忆已不存在。") }
      return "忘记：\(memory.content)\n停止在后续上下文中使用；历史原文和正式记录保留。"
    case "updateToday":
      try require(p.minutes != nil || p.energy != nil || p.context != nil, "请补充今天要改的条件。")
      try require(!p.source_text.contains("明天") && !p.source_text.contains("昨天"), "这张卡只修改今天的条件，请明确日期。")
      if !operation.edited {
        if let energy = p.energy {
          let words = energy == "状态正常" ? ["正常", "状态不错", "精神不错"] : energy == "有点疲惫" ? ["累", "疲惫", "疲劳"] : ["不适", "困", "头晕", "疼", "痛"]
          try require(words.contains(where: p.source_text.contains), "状态缺少你的明确依据。")
        }
        if let context = p.context { try require(p.source_text.contains(context) || context == "在家" && p.source_text.contains("家里"), "地点缺少你的明确依据。") }
      }
      return "仅更新今天：" + [p.minutes.map { "\($0) 分钟" }, p.context, p.energy].compactMap { $0 }.joined(separator: " · ") + "\n其余未确认条件保持未知；已完成组数保留。"
    case "logSet", "correctSet":
      if p.kind == "logSet" {
        try require(operation.edited || ["做了", "完成", "练了", "记录", "刚做", "实际"].contains(where: p.source_text.contains), "这是训练意图，尚不能记作实际完成。")
        try require(operation.edited || !["想练", "打算", "准备", "明天", "计划做"].contains(where: p.source_text.contains), "计划不计为实际训练。")
        guard let exercise = p.exercise, !exercise.isEmpty, let kg = p.kg, let reps = p.reps else { throw AgentOperationError.rejected("请补充动作、实际重量（kg）和次数。") }
        try require(operation.edited || text.contains(exercise), "动作名称缺少你的原话依据。")
        let date = recordDate(text: p.source_text, now: now)
        try require(date <= now, "不能保存未来的实际训练。请核对训练日期。")
        if let draft = data.draft { try require(Calendar.current.isDate(draft.started, inSameDayAs: date), "当前训练与这条记录日期不同，请先处理当前训练。") }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = .current
        return "记录实际完成：\(exercise)，\(kg) kg × \(reps) 次，\(p.count ?? 1) 组\n日期：\(formatter.string(from: date))；加入当前训练，结束训练后归档；不推断器械重量口径。"
      }
      guard let set = findSet(target, data: data), p.kg != nil || p.reps != nil else { throw AgentOperationError.rejected("请选择要更正的那一组，并补充正确重量或次数。") }
      if let profileID = set.profileID, let kg = p.kg {
        try require(data.training?.profiles.first(where: { $0.id == profileID })?.availableLoads.contains(kg) == true, "重量不在原器械档位中；如果更换了器械，请新建对应档案，避免混用能力记录。")
      }
      return "更正 \(set.exercise)：\(set.kg) kg × \(set.reps) 次 → \(p.kg ?? set.kg) kg × \(p.reps ?? set.reps) 次\n修改原组，不新增记录。"
    case "finishWorkout":
      try require(operation.edited || ["结束", "完成", "练完"].contains(where: p.source_text.contains), "请明确是否已经结束本次训练。")
      guard let draft = data.draft, !draft.sets.isEmpty else { throw AgentOperationError.rejected("当前没有实际组数可归档，先补充完成记录。") }
      let elapsed = max(1, Int(now.timeIntervalSince(draft.started) / 60))
      try require(p.minutes != nil || Calendar.current.isDate(draft.started, inSameDayAs: now), "补记的训练请提供实际时长，不能用跨天的计时推测。")
      return "结束 \(draft.name)：保存已记录的 \(draft.sets.count) 组，\(p.minutes ?? elapsed) 分钟\(p.minutes == nil ? "（从本次开始计时）" : "（你提供的时长）")。\n未记录的计划动作不会计为完成。"
    case "logMeal", "correctMeal":
      guard let content = p.content, !content.isEmpty else { throw AgentOperationError.rejected("请补充实际吃过的食物与份量。") }
      try require(operation.edited || text.contains(content), "餐食内容缺少你的原话依据。")
      if p.kind == "logMeal" {
        try require(operation.edited || ["吃了", "喝了", "吃过", "记录", "刚吃", "实际"].contains(where: p.source_text.contains), "建议吃什么不能算作已经吃过。")
        try require(operation.edited || !["想吃", "准备", "打算", "明天"].contains(where: p.source_text.contains), "尚未吃过的餐食不能记入日志。")
        let date = recordDate(text: p.source_text, now: now)
        try require(date <= now, "不能保存未来的实际餐食。")
        return "保存实际餐食：\(content)\n日期：\(date.formatted(date: .abbreviated, time: .omitted))；未估算营养，未知不会记成零。"
      }
      guard let meal = data.meals.first(where: { $0.id == target }) else { throw AgentOperationError.rejected("请选择实际要更正的餐食。") }
      return "餐食：\(meal.title) → \(content)\n保留原照片与日期；旧营养估计失效，需要重新核对。"
    case "substituteExercise":
      try require(DailyPlanner.plan(data, now: now).status == "ready" && !AssistantContext.hasUnresolvedSafetyPause(data), "当前状态尚不支持调整训练，请先补齐条件或处理不适。")
      guard let draft = data.draft, let item = draft.planned?.first(where: { $0.id == target }), let replacement = p.exercise_id,
        let check = data.coach?.checkIn, Calendar.current.isDate(check.date, inSameDayAs: now),
        TrainingWorkload.alternatives(for: item, draft: draft, state: data.training, equipment: data.coach?.preferences.equipment ?? "未确认", context: check.context, excluded: check.excludedExercises ?? []).contains(where: { $0.id == replacement }) else { throw AgentOperationError.rejected("当前条件下没有这项受控替代，或动作与现有计划重复，请核对可用器械及计划。") }
      _ = try TrainingWorkload.replacement(item, with: replacement, draft: draft, state: data.training)
      let progress = TrainingWorkload.progress(item, draft: draft, state: data.training)
      return "\(TrainingLibrary.guide(item.exerciseID)?.name ?? item.exerciseID) → \(TrainingLibrary.guide(replacement)?.name ?? replacement)\n\(progress.summary)；仅替代剩余工作组，已完成记录保留，新器械重新校准重量。"
    default: throw AgentOperationError.rejected("不支持的操作。")
    }
  }
  public static func findSet(_ id: UUID?, data: AppData) -> SetEntry? { ((data.draft?.sets ?? []) + data.workouts.flatMap(\.sets)).first { $0.id == id } }
  public static func commit(_ id: UUID, data: inout AppData, now: Date = Date()) throws {
    guard let i = data.personalAgent?.operations.firstIndex(where: { $0.id == id }), let op = data.personalAgent?.operations[i] else { throw AgentOperationError.rejected("找不到这项待确认操作。") }
    try require(fresh(op, data: data, now: now), "记录或条件已变化，请重新生成并核对；不会重复提交。")
    let summary = try preview(op, data: data, now: now)
    let p = op.input, target = p.target_id?.split(separator: ".").last.flatMap { UUID(uuidString: String($0)) }
    let affected: [UUID]
    switch p.kind {
    case "logMeal", "finishWorkout": affected = [op.id]
    case "correctMeal": affected = target.map { [$0] } ?? []
    case "correctSet": affected = data.workouts.filter { $0.sets.contains { $0.id == target } }.map(\.id)
    default: affected = []
    }
    let before = AgentUndo.capture(data, scope: scope(p.kind), recordIDs: affected)
    switch p.kind {
    case "remember", "updateMemory":
      var memory = PersonalMemory(content: p.content!, topic: p.topic!, sourceText: p.source_text, sourceTurnID: op.turnID)
      memory.createdAt = now; memory.updatedAt = now; memory.expiresAt = p.expires_at.flatMap { ISO8601DateFormatter().date(from: $0) }; memory.confirmation = MemoryRules.canAutoRemember(p, data: data, turn: data.conversation?.first { $0.id == op.turnID } ?? CoachTurn(text: p.source_text, reply: "", actions: [])) ? "用户明确表达" : "用户核对"
      if p.kind == "updateMemory", let index = data.personalAgent?.memories.firstIndex(where: { $0.id == target }), let old = data.personalAgent?.memories[index] {
        memory.id = old.id; memory.createdAt = old.createdAt; memory.revision = old.revision + 1
        data.personalAgent?.memories[index] = memory; data.personalAgent?.historyAfter = now
      } else if !(data.personalAgent?.memories.contains { $0.content == memory.content && $0.active(at: now) } ?? false) {
        // A category is not an identity. Adding one food preference must not erase
        // every other food preference. Only updateMemory replaces an explicit target.
        data.personalAgent?.memories.append(memory)
      }
    case "forgetMemory":
      if let old = data.personalAgent?.memories.first(where: { $0.id == target }) {
        data.personalAgent?.forgotten.append(.init(id: old.id, sourceTurnID: old.sourceTurnID, date: now)); data.personalAgent?.memories.removeAll { $0.id == old.id }
        data.personalAgent?.historyAfter = now
      }
    case "updateToday":
      if data.coach == nil { data.coach = CoachState() }
      var check = data.coach?.checkIn
      if check == nil || !Calendar.current.isDate(check!.date, inSameDayAs: now) { check = DailyCheckIn(); check?.context = "未确认"; check?.confirmedFields = [] }
      var fields = check!.confirmedFields ?? Set(["minutes", "context", "energy"])
      if let minutes = p.minutes { check?.minutes = minutes; fields.insert("minutes") }
      if let context = p.context { check?.context = context; fields.insert("context") }
      if let energy = p.energy { check?.energy = energy; fields.insert("energy") }
      check?.date = now; check?.confirmedFields = fields
      data.coach?.checkIn = check
      let oldPlanned = data.draft?.planned, sets = data.draft?.sets
      AssistantTransactions.applyDailyCheck(check!, to: &data, now: now)
      // Incomplete/safety states invalidate targets but never erase the plan or completed records.
      if DailyPlanner.plan(data, now: now).status != "ready" { data.draft?.planned = oldPlanned }
      data.draft?.sets = sets ?? []
    case "logSet":
      let date = recordDate(text: p.source_text, now: now)
      try require(date <= now, "不能保存未来的实际训练。请核对训练日期。")
      if data.draft == nil { var draft = WorkoutDraft(); draft.started = date; data.draft = draft }
      try require(Calendar.current.isDate(data.draft!.started, inSameDayAs: date), "当前训练与这条记录日期不同，请先处理当前训练。")
      for _ in 0..<(p.count ?? 1) { var set = SetEntry(exercise: p.exercise!, kg: p.kg!, reps: p.reps!); set.date = date; data.draft?.sets.append(set) }
    case "correctSet":
      func edit(_ set: inout SetEntry) { if let kg = p.kg { set.kg = kg }; if let reps = p.reps { set.reps = reps } }
      if let index = data.draft?.sets.firstIndex(where: { $0.id == target }) { edit(&data.draft!.sets[index]) }
      else { for w in data.workouts.indices { if let s = data.workouts[w].sets.firstIndex(where: { $0.id == target }) { edit(&data.workouts[w].sets[s]) } } }
      data.draft?.targets = []; data.training?.revision += 1
    case "finishWorkout":
      let draft = data.draft!
      let duration = p.minutes ?? max(1, Int(now.timeIntervalSince(draft.started) / 60))
      try require((1...1440).contains(duration), "训练开始时间较早，请补充实际训练分钟数。")
      data.workouts.append(.init(id: op.id, date: draft.started, name: draft.name, sets: draft.sets, effort: "未提供", minutes: duration))
      if let slot = draft.sequenceSlot, TrainingProgression.planCompleted(draft, state: data.training), (data.training?.sequenceIndex ?? 0) % 3 == slot { data.training?.sequenceIndex += 1 }
      data.draft = nil
    case "logMeal":
      data.meals.append(.init(id: op.id, date: recordDate(text: p.source_text, now: now), title: p.content!, note: p.source_text)); data.foodDiaryCompleteAt = nil
    case "correctMeal":
      let index = data.meals.firstIndex { $0.id == target }!
      data.meals[index].title = p.content!; data.meals[index].note = p.source_text; data.meals[index].nutrition = nil; data.foodDiaryCompleteAt = nil
    case "substituteExercise":
      let index = data.draft!.planned!.firstIndex { $0.id == target }!, old = data.draft!.planned![index]
      let replacement = try TrainingWorkload.replacement(old, with: p.exercise_id!, draft: data.draft!, state: data.training)
      data.draft?.planned?[index] = replacement; data.draft?.targets = []; data.draft?.adaptationNote = summary
      if data.training == nil { data.training = TrainingState() }; data.training?.revision += 1
      let revision = data.training?.revision ?? 0
      data.training?.events.append(TrainingEvent(kind: "对话替代", reason: summary, revision: revision))
    default: throw AgentOperationError.rejected("不支持的操作。")
    }
    data.personalAgent?.operations[i].status = "applied"
    let revision = (data.personalAgent?.revision ?? 0) + 1
    data.personalAgent?.revision = revision
    let result: String
    switch p.kind {
    case "remember": result = "已记住：" + p.content!
    case "updateMemory": result = "已更新记忆：" + p.content!
    case "forgetMemory": result = "已忘记这条记忆，后续不再使用。历史原文与正式记录保留。"
    case "logMeal": result = "已保存这餐：\(data.meals.first { $0.id == op.id }!.title)。营养未知项保持未知。"
    case "correctMeal": result = "已更正原餐食：\(p.content!)。旧营养估计已失效，原照片和日期保留。"
    case "logSet": result = "已记录 \(p.exercise!)：\(p.kg!) kg × \(p.reps!) 次，\(p.count ?? 1) 组。当前训练尚未归档。"
    case "finishWorkout":
      let saved = data.workouts.first { $0.id == op.id }!
      result = "已归档 \(saved.name)：\(saved.sets.count) 组实际记录，\(saved.minutes) 分钟。"
    case "updateToday": result = "已更新今天的条件：" + [p.minutes.map { "\($0) 分钟" }, p.context, p.energy].compactMap { $0 }.joined(separator: " · ") + "。长期偏好和实际组数保留。"
    default: result = "已完成修改。\n" + summary
    }
    let receipt = AgentReceipt(id: id, date: now, summary: result, before: before, afterDigest: AgentUndo.capture(data, scope: before.scope, recordIDs: affected).digest)
    data.personalAgent?.receipts.append(receipt)
    let retained = Array((data.personalAgent?.receipts ?? []).suffix(20))
    data.personalAgent?.receipts = retained
    if let t = data.conversation?.firstIndex(where: { $0.id == op.turnID }) { data.conversation?[t].outcome = String(receipt.summary.prefix(1000)) }
  }
  public static func undo(_ id: UUID, data: inout AppData, now: Date = Date()) throws {
    guard let index = data.personalAgent?.receipts.firstIndex(where: { $0.id == id }), let receipt = data.personalAgent?.receipts[index], !receipt.undone else { throw AgentOperationError.rejected("这项操作已经撤销或没有可恢复的版本。") }
    try require(receipt.before.valid, "撤销版本无效，原记录保持不变。")
    try require(data.personalAgent?.receipts.last(where: { !$0.undone })?.id == id, "请先处理最近的一次操作，避免覆盖后续修改。")
    try require(AgentUndo.capture(data, scope: receipt.before.scope, recordIDs: receipt.before.recordIDs).digest == receipt.afterDigest, "相关数据已有后续修改，不能直接撤销覆盖。")
    receipt.before.restore(&data)
    let revision = (data.personalAgent?.revision ?? 0) + 1
    data.personalAgent?.revision = revision
    if receipt.before.scope == "memory" { data.personalAgent?.historyAfter = now }
    data.personalAgent?.receipts[index].undone = true
    data.personalAgent?.receipts[index].summary = "已撤销，恢复操作前的数据。"
    if let op = data.personalAgent?.operations.firstIndex(where: { $0.id == id }) {
      data.personalAgent?.operations[op].status = "undone"
      let turnID = data.personalAgent!.operations[op].turnID
      if let t = data.conversation?.firstIndex(where: { $0.id == turnID }) { data.conversation?[t].outcome = "该操作已撤销。" }
    }
  }
}
