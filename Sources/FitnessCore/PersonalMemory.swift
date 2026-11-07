import Foundation

public struct PersonalMemory: Codable, Identifiable {
  public var id = UUID()
  public var content: String
  public var topic: String
  public var sourceText: String
  public var sourceTurnID: UUID?
  public var createdAt = Date()
  public var updatedAt = Date()
  public var expiresAt: Date?
  public var revision = 1
  public var confirmation = "用户明确表达"
  public init(content: String, topic: String, sourceText: String, sourceTurnID: UUID?) {
    self.content = content; self.topic = topic; self.sourceText = sourceText; self.sourceTurnID = sourceTurnID
  }
  public func active(at now: Date = Date()) -> Bool { expiresAt.map { $0 > now } ?? true }
  public var valid: Bool {
    !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && content.count <= 500 && sourceText.count <= 3000 &&
      MemoryRules.topics.contains(topic) && revision > 0 && updatedAt >= createdAt &&
      (expiresAt.map { $0 > createdAt } ?? true) && ["用户明确表达", "用户核对"].contains(confirmation)
  }
}
public struct MemoryTombstone: Codable {
  public let id: UUID
  public let sourceTurnID: UUID?
  public let date: Date
}
public struct PersonalAgentState: Codable {
  public var revision: Int?
  public var memories: [PersonalMemory] = []
  public var forgotten: [MemoryTombstone] = []
  // Conservatively excludes old conversation echoes after a correction/forget.
  public var historyAfter: Date?
  public var operations: [AgentOperation] = []
  public var receipts: [AgentReceipt] = []
  public init() {}
}
public enum MemoryRules {
  public static let topics = ["reply_style", "training_schedule", "food_preference", "general_preference", "health_constraint", "temporary"]
  public static func sensitive(_ text: String) -> Bool {
    ["过敏", "忌口", "疼", "痛", "伤", "病", "药", "血", "孕", "手术", "禁忌", "医生", "限制", "头晕", "困倦", "心慌", "不适"].contains { text.contains($0) }
  }
  public static func ordinaryExplicit(_ text: String) -> Bool {
    guard !["体重", "身高", "心率", "睡眠", "体脂", "年龄", "目标", "公斤", "千克", "kg", "做了", "吃了", "喝了"].contains(where: text.lowercased().contains) else { return false }
    guard !sensitive(text), !["“", "”", "\"", "他说", "她说", "比如", "例如", "假设", "如果", "不要记", "别记", "不记", "忘记", "忘掉", "取消", "？", "?"].contains(where: text.contains) else { return false }
    return ["记住", "我通常", "我习惯", "我喜欢", "我不喜欢", "我不爱", "以后回答", "以后回复"].contains(where: text.contains)
  }
  public static func topic(_ text: String) -> String {
    if sensitive(text) { return "health_constraint" }
    if ["今天", "这周", "本周", "出差", "临时"].contains(where: text.contains) { return "temporary" }
    if ["回答", "回复", "简短", "啰嗦"].contains(where: text.contains) { return "reply_style" }
    if ["周一", "周二", "周三", "周四", "周五", "周六", "周日", "晚上训练", "早上训练"].contains(where: text.contains) { return "training_schedule" }
    if ["吃", "口味", "食物", "辣", "甜", "饮食"].contains(where: text.contains) { return "food_preference" }
    return "general_preference"
  }
  public static func localInput(_ text: String) -> AgentOperationInput? {
    guard text.count <= 500, ordinaryExplicit(text), topic(text) != "temporary" else { return nil }
    var input = AgentOperationInput(kind: "remember", sourceText: text)
    input.content = text; input.topic = topic(text)
    return input
  }
  public static func canAutoRemember(_ input: AgentOperationInput, data: AppData, turn: CoachTurn) -> Bool {
    guard input.kind == "remember", let content = input.content, ordinaryExplicit(turn.text),
      content == turn.text, input.topic == topic(content), input.topic != "temporary", input.expires_at == nil,
      !(data.coachThreads?.first { $0.id == turn.threadID }?.noLongTermMemory ?? false) else { return false }
    return !(data.personalAgent?.memories ?? []).contains { $0.active() && $0.topic == input.topic && $0.content != content }
  }
  public static func relevant(_ data: AppData, text: String, now: Date) -> [PersonalMemory] {
    let query = contextText(data, text: text, now: now)
    let areas = domains(query), recall = asksAboutMemory(query)
    let forgotten = Set((data.personalAgent?.forgotten ?? []).map(\.id))
    return (data.personalAgent?.memories ?? []).filter { m in
      guard m.valid, m.active(at: now), !forgotten.contains(m.id) else { return false }
      if recall || m.topic == "reply_style" { return true }
      guard !areas.isEmpty else { return false }
      switch m.topic {
      case "training_schedule": return areas.contains("training")
      case "food_preference": return areas.contains("food")
      case "health_constraint":
        let specific = domains(m.content)
        // Unclassified health restrictions can affect any fitness task. Clearly
        // food-only or movement-only restrictions stay in their relevant task.
        return specific.isEmpty || !areas.isDisjoint(with: specific)
      case "temporary" where contains(m.content, ["出差", "旅行", "住酒店"]):
        return !areas.isDisjoint(with: ["food", "training"])
      default: return !areas.isDisjoint(with: domains(m.content))
      }
    }.sorted { a, b in
      func priority(_ m: PersonalMemory) -> Int { m.topic == "health_constraint" ? 2 : m.topic == "reply_style" ? 1 : 0 }
      return priority(a) == priority(b) ? a.updatedAt > b.updatedAt : priority(a) > priority(b)
    }.prefix(8).map { $0 }
  }
  private static func contains(_ text: String, _ words: [String]) -> Bool { words.contains(where: text.lowercased().contains) }
  private static func softwareObject(_ text: String) -> Bool {
    // One object taxonomy is used for both whole questions and command targets.
    // UI, implementation and model/API objects cannot acquire personal scope
    // merely because their names also contain a fitness-domain word.
    contains(text, ["功能", "页面", "界面", "按钮", "模块", "菜单", "入口", "开关", "设置", "应用", "软件",
      "代码", "源码", "编程", "接口", "模型", "算法", "架构", "框架", "仓库", "协议", "版本", "报错"]) ||
      text.range(of: "\\b(?:app|api|sdk|code|model|software|deepseek|xcode)\\b", options: [.regularExpression, .caseInsensitive]) != nil
  }
  private static func taskClauses(_ text: String) -> [String] {
    let separated = text.replacingOccurrences(of: "(?:并且|同时|另外|然后|以及|顺便|再|并)(?=(?:请|帮我|给我|为我|介绍|解释|说明|查看|列出|我))", with: "\n", options: .regularExpression)
    return separated.split(whereSeparator: { "，,。！？?；;\n".contains($0) }).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
  }
  private static func personalFitnessDomains(_ text: String) -> Set<String> {
    // A polite "help me analyze" is not enough: its actual object must be a
    // fitness task, not a feature. Separate clauses allow a real individual
    // request to accompany product questions without discarding its constraints.
    var result = Set<String>()
    for clause in taskClauses(text) {
      if let command = clause.range(of: "(?:帮我|给我|为我)(?:制定|安排|调整|设计|分析|评估|推荐|生成|规划|记录|修改|配餐)(?:一下)?", options: .regularExpression) {
        let target = String(clause[command.upperBound...])
        let prefix = String(clause[..<command.lowerBound])
        let capabilityQuestion = prefix.range(of: "(?:能否|是否|如何|怎样|怎么|可以|能够|能不能|可不可以|会不会|会|(?<!功)能)\\s*$", options: .regularExpression) != nil
        let individualTarget = contains(target, ["今天", "昨天", "明天", "这周", "本周", "最近", "刚才", "这次", "本次", "下次", "当前", "目前", "我的", "我刚", "这顿", "下顿", "早餐", "午餐", "晚餐", "午饭", "晚饭", "训练记录", "饮食记录", "体重记录", "睡眠记录"]) ||
          contains(String(clause[command.lowerBound...]), ["帮我配餐", "给我配餐", "为我配餐"])
        if !softwareObject(target), !capabilityQuestion, individualTarget {
          result.formUnion(fitnessDomains(String(clause[command.lowerBound...])))
        }
        continue
      }
      if let person = clause.range(of: "我") {
        let target = String(clause[person.lowerBound...])
        let prefix = String(clause[..<person.lowerBound])
        // "In the training page, how should I train?" names a location. In
        // "How does this feature use my plan?", the feature remains the subject.
        let location = ["在", "用", "使用", "通过"].contains(where: prefix.hasPrefix)
        if softwareObject(prefix) && (!location || contains(prefix, ["怎么", "如何", "怎样", "能否", "是否", "可以", "支持"])) { continue }
        if !softwareObject(target), !fitnessDomains(target).isEmpty,
          contains(target, ["安排", "调整", "分析", "评估", "推荐", "规划", "怎么练", "如何练", "练什么", "怎么做", "如何做", "能不能练", "可以练", "适合", "配餐", "搭配", "吃什么", "该吃", "补什么"]) {
          result.formUnion(fitnessDomains(target))
        }
      }
    }
    return result
  }
  private static func softwareQuestion(_ text: String) -> Bool {
    // Product/UI objects default to software context, irrespective of whether
    // the user asks for an introduction, purpose, capability, usage or navigation.
    return softwareObject(text) || contains(text, ["支持哪些", "支持什么"])
  }
  private static func asksAboutMemory(_ text: String) -> Bool {
    // A product clause mentioning "my memory feature" is not a recall request,
    // even if a separate clause asks for a real meal or training task.
    taskClauses(text).contains { clause in
      !softwareQuestion(clause) && (["记忆", "查看记忆", "列出记忆"].contains(clause) ||
        contains(clause, ["记得我", "记得关于我", "记住了什么", "你记住的", "我的记忆", "关于我的记忆", "所有记忆", "我的偏好", "了解我哪些", "what do you remember about me", "my preferences"]))
    }
  }
  private static func domains(_ text: String) -> Set<String> {
    // A real task never unlocks other clauses' domain words. For mixed software
    // requests, union only the domains of independently accepted personal targets.
    if softwareQuestion(text) { return personalFitnessDomains(text) }
    return fitnessDomains(text)
  }
  private static func fitnessDomains(_ text: String) -> Set<String> {
    if contains(text, ["今日方案", "今天怎么安排", "fit 方案", "复盘", "减脂", "减肥", "健康建议"]) { return ["food", "training", "sleep", "weight"] }
    var result = Set<String>()
    if contains(text, ["吃", "餐", "饮食", "食物", "食材", "营养", "补什么", "配餐", "忌口", "过敏", "花生", "乳糖", "海鲜", "meal", "diet", "food", "allerg"]) { result.insert("food") }
    if contains(text, ["训练", "练", "运动", "器械", "健身", "组数", "推胸", "深蹲", "跑步", "骑车", "膝", "腰", "肩", "关节", "负重", "workout", "exercise", "injur"]) { result.insert("training") }
    if contains(text, ["睡", "失眠", "作息", "sleep"]) { result.insert("sleep") }
    if contains(text, ["体重", "称重", "体脂", "weight"]) { result.formUnion(["weight", "food", "training"]) }
    return result
  }
  static func contextText(_ data: AppData, text: String, now: Date) -> String {
    func followup(_ value: String) -> Bool {
      value.count <= 80 && contains(value, ["继续", "刚才", "这样安排", "换一个", "换个", "再来一个", "为什么", "详细一点", "具体一点", "还有吗", "这个呢", "那个呢", "第二个", "第一个", "怎么做", "continue", "why"]) &&
        !contains(value, ["模型", "软件", "代码", "api", "版本", "报错", "编程", "支持", "功能", "deepseek", "xcode"])
    }
    guard domains(text).isEmpty, !asksAboutMemory(text), followup(text) else { return text }
    let cutoff = data.personalAgent?.historyAfter ?? .distantPast
    // Only follow the latest substantive question in this thread. A new software
    // topic must never inherit the earlier fitness task's personal context.
    for previous in CoachThreads.turns(data).filter({ $0.isComplete && $0.date > cutoff && $0.date <= now && $0.text != text }).suffix(4).reversed() {
      if !domains(previous.text).isEmpty { return previous.text + "\n" + text }
      if !followup(previous.text) { break }
    }
    return text
  }
  static func summary(_ m: PersonalMemory) -> String {
    "\(m.content)；类别 \(m.topic)；版本 \(m.revision)；\(m.confirmation)；有效至 \(m.expiresAt.map(ISO8601DateFormatter().string) ?? "用户更正或忘记")。偏好不代表正式计划。"
  }
}

public enum PersonalAgentContext {
  public static func build(_ data: AppData, text: String, health: Bool, memory: Bool, now: Date = Date()) -> CoachContextBundle {
    let base = AssistantContext.build(data, text: text, includeHealth: health, now: now)
    var facts = base.snapshot.facts
    let iso = ISO8601DateFormatter()
    func fact(_ id: String, _ summary: String, _ unit: String, _ date: Date?, _ quality: String) {
      facts.append(.init(id: id, summary: String(summary.prefix(3000)), unit: unit, observed_at: date.map(iso.string),
        source_id: "local:" + id, revision: AssistantContext.digest(summary), quality: quality))
    }
    fact("public.clock", "当前本地日期与时间：\(iso.string(from: now))；时区：\(TimeZone.current.identifier)。日期、今天/昨天必须按此解释。", "时间", now, "设备时间")
    if memory {
      for m in MemoryRules.relevant(data, text: text, now: now) {
        fact("memory." + m.id.uuidString, MemoryRules.summary(m), "说明", m.updatedAt, m.confirmation)
      }
    }
    if health {
      if let check = data.coach?.checkIn, Calendar.current.isDate(check.date, inSameDayAs: now), let fields = check.confirmedFields {
        facts.removeAll { $0.id == "today" }
        fact("today", "当天明确条件：时间 \(fields.contains("minutes") ? "\(check.minutes) 分钟" : "未知")；地点 \(fields.contains("context") ? check.context : "未知")；状态 \(fields.contains("energy") ? check.energy : "未知")。未提供的字段不得按默认值确认。", "分钟/说明", check.date, "用户确认的部分字段")
      }
      // Stable IDs let a correction refer to one real record; bounded summaries never carry photos.
      let matchingDate = AgentOperations.recordDate(text: text, now: now)
      let meals = data.meals.filter { Calendar.current.isDate($0.date, inSameDayAs: matchingDate) }.sorted { $0.date > $1.date }.prefix(8)
      for meal in meals { fact("meal." + meal.id.uuidString, "\(meal.title)；\(String(meal.note.prefix(160)))；\(iso.string(from: meal.date))", "餐", meal.date, "已确认实际餐食") }
      let savedSets = data.workouts.filter { Calendar.current.isDate($0.date, inSameDayAs: matchingDate) }.flatMap(\.sets)
      let sets = ((data.draft?.sets ?? []) + savedSets).sorted { $0.date > $1.date }.prefix(8)
      for set in sets { fact("set." + set.id.uuidString, "\(set.exercise)：\(set.kg) kg × \(set.reps) 次；\(iso.string(from: set.date))；\(set.profileID == nil ? "重量口径未关联器械档案" : "已关联动作档案")", "kg/次", set.date, "实际记录") }
      if let draft = data.draft {
        fact("workout.current", "正在记录：\(draft.name)，开始于 \(iso.string(from: draft.started))，已记录 \(draft.sets.count) 组。结束时只保存这些实际组数。", "组", draft.started, "当前训练草稿")
        if let check = data.coach?.checkIn, Calendar.current.isDate(check.date, inSameDayAs: now), DailyPlanner.plan(data, now: now).status == "ready" {
          for item in (draft.planned ?? []).prefix(8) {
            let progress = TrainingWorkload.progress(item, draft: draft, state: data.training)
            let alternatives = TrainingWorkload.alternatives(for: item, draft: draft, state: data.training, equipment: data.coach?.preferences.equipment ?? "未确认", context: check.context, excluded: check.excludedExercises ?? [])
            fact("planned." + item.id.uuidString, "\(TrainingLibrary.guide(item.exerciseID)?.name ?? item.exerciseID)；\(progress.summary)；剩余可选替代：" + alternatives.map { "\($0.id)（\($0.name)）" }.joined(separator: "、"), "组", now, "本地规则候选")
          }
        }
      }
    }
    return .init(snapshot: .init(snapshot_id: base.snapshot.snapshot_id, generated_at: base.snapshot.generated_at,
      timezone: base.snapshot.timezone, expected_plan_version: base.snapshot.expected_plan_version, facts: Array(facts.prefix(64)), candidates: base.snapshot.candidates), fingerprint: base.fingerprint, proposals: base.proposals)
  }
  public static func history(_ data: AppData, text: String = "", health: Bool, memory: Bool, now: Date = Date()) -> [RouterHistory] {
    limitedHistory(data, text: text, health: health, memory: memory, now: now)
  }
  public static func limitedHistory(_ data: AppData, text: String, health: Bool, memory: Bool, now: Date = Date()) -> [RouterHistory] {
    let cutoff = data.personalAgent?.historyAfter ?? .distantPast
    let relevant = memory ? MemoryRules.relevant(data, text: text, now: now) : []
    let revisions = Dictionary(uniqueKeysWithValues: relevant.map { ("memory." + $0.id.uuidString, AssistantContext.digest(MemoryRules.summary($0))) })
    let omitted = (data.personalAgent?.memories ?? []).filter { revisions["memory." + $0.id.uuidString] == nil }
    let turns = CoachThreads.turns(data).filter { turn in
      guard turn.isComplete, turn.date > cutoff, turn.date <= now else { return false }
      let facts = turn.exchange?.snapshot.facts ?? []
      return health || (turn.requiresSummaryConsent != true && !facts.contains { !$0.id.hasPrefix("memory.") && !$0.id.hasPrefix("public.") })
    }
    return turns.suffix(4).flatMap { turn -> [RouterHistory] in
      // Source turns can repeat a memory even when they predate snapshot support.
      let repeatsOmitted = omitted.contains { $0.sourceTurnID == turn.id || turn.text.contains($0.content) || (!$0.sourceText.isEmpty && turn.text.contains($0.sourceText)) }
      if repeatsOmitted { return [] }
      let facts = turn.exchange?.snapshot.facts.filter { $0.id.hasPrefix("memory.") } ?? []
      let unsafeReply = facts.contains { revisions[$0.id] != $0.revision } ||
        (turn.requiresMemoryConsent == true && turn.exchange == nil)
      let answer = unsafeReply ? "上一轮回复已省略。" : CoachReplyText.body(turn) + (turn.outcome.map { "\n本机结果：" + $0 } ?? "")
      return [RouterHistory(role: "user", content: String(turn.text.prefix(800))), RouterHistory(role: "assistant", content: String(answer.prefix(800)))]
    }
  }
}
