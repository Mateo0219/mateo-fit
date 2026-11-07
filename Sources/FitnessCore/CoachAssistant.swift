import Foundation
import CryptoKit

public struct CoachFact: Codable, Identifiable {
  public let id: String
  public let summary: String
  public let unit: String
  public let observed_at: String?
  public let source_id: String
  public let revision: String
  public let quality: String
  enum CodingKeys: String, CodingKey { case id, summary, unit, observed_at, source_id, revision, quality }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id); try c.encode(summary, forKey: .summary); try c.encode(unit, forKey: .unit)
    try c.encode(observed_at, forKey: .observed_at)
    try c.encode(source_id, forKey: .source_id); try c.encode(revision, forKey: .revision); try c.encode(quality, forKey: .quality)
  }
}
public struct CoachCandidate: Codable, Identifiable {
  public let id: String
  public let action: CoachAction
  public let title: String
  public let detail: String
  public let evidence_ids: [String]
}
public struct CoachSnapshot: Codable {
  public let snapshot_id: String
  public let generated_at: String
  public let timezone: String
  public let expected_plan_version: String
  public let facts: [CoachFact]
  public let candidates: [CoachCandidate]
}
public struct CoachConsent: Codable {
  public let text: Bool
  public let health_summary: Bool
  public init(text: Bool, healthSummary: Bool) { self.text = text; self.health_summary = healthSummary }
}
public struct CoachResponseCard: Codable, Identifiable {
  public var id: String { action.rawValue + (candidate_id ?? "") }
  public let action: CoachAction
  public let title: String
  public let detail: String
  public let evidence_ids: [String]
  public let candidate_id: String?
}
public struct CoachAssistantResponse: Codable {
  public var contract_version: Int? = nil
  public var operations: [AgentOperationInput]? = nil
  public var sources: [CoachWebSource]? = nil
  public var citation_ids: [String]? = nil
  public var generation: CoachGenerationResult? = nil
  public let request_id: String
  public let snapshot_id: String
  public let expected_plan_version: String
  public let status: String
  public let message: String
  public let questions: [String]
  public let cards: [CoachResponseCard]
  public func validate(requestID: String, snapshot: CoachSnapshot) throws {
    guard contract_version == nil || contract_version == 2,
      operations == nil || contract_version == 2,
      (operations?.count ?? 0) <= 4,
      status != "safety_pause" || (operations ?? []).isEmpty else { throw CoachError.invalid }
    for operation in operations ?? [] {
      guard operation.valid, Set(operation.evidence_ids).isSubset(of: Set(snapshot.facts.map(\.id))) else { throw CoachError.invalid }
    }
    guard request_id == requestID, snapshot_id == snapshot.snapshot_id,
      expected_plan_version == snapshot.expected_plan_version,
      ["proposal", "needs_input", "insufficient_data", "safety_pause"].contains(status),
      !message.isEmpty, message.count <= 1800, questions.count <= 1,
      questions.allSatisfy({ !$0.isEmpty && $0.count <= 300 }),
      status != "needs_input" || !questions.isEmpty,
      cards.count <= 4, Set(cards.map(\.id)).count == cards.count,
      status != "safety_pause" || cards.isEmpty else { throw CoachError.invalid }
    let webSources = sources ?? [], citations = citation_ids ?? []
    guard webSources.count <= 8, webSources.allSatisfy(\.valid), Set(webSources.map(\.id)).count == webSources.count,
      citations.count <= 8, Set(citations).count == citations.count, Set(citations) == Set(webSources.map(\.id)),
      generation?.valid ?? true else { throw CoachError.invalid }
    let evidence = Set(snapshot.facts.map(\.id))
    for card in cards {
      guard !card.title.isEmpty, card.title.count <= 100, card.detail.count <= 600,
        Set(card.evidence_ids).isSubset(of: evidence) else { throw CoachError.invalid }
      if let id = card.candidate_id {
        guard snapshot.candidates.contains(where: { $0.id == id && $0.action == card.action }) else { throw CoachError.invalid }
      }
    }
  }
}
public struct CoachLocalProposal: Codable, Identifiable {
  public let id: String
  public let kind: String
  public let checkIn: DailyCheckIn?
  public let preferences: CoachPreferences?
}
public struct CoachExchange: Codable {
  public let snapshot: CoachSnapshot
  public let fingerprint: String
  public let proposals: [CoachLocalProposal]
  public let response: CoachAssistantResponse
  public var appliedIDs: [String] = []
  public init(bundle: CoachContextBundle, response: CoachAssistantResponse) {
    self.snapshot = bundle.snapshot; self.fingerprint = bundle.fingerprint
    self.proposals = bundle.proposals; self.response = response
  }
}
public struct CoachContextBundle: Codable {
  public let snapshot: CoachSnapshot
  public let fingerprint: String
  public let proposals: [CoachLocalProposal]
}
public struct HomeMealDraft: Codable, Identifiable {
  public var id = UUID()
  public var date = Date()
  public var description: String
  public var photo: Data?
  public var result: MealAgentResult?
  public var title: String
  public var nutrition: MealNutrition?
  public var analysisInput: String?
  public var sourceTurnID: UUID?
  public init(description: String, photo: Data?, result: MealAgentResult? = nil) {
    self.description = description; self.photo = photo; self.result = result
    self.title = result?.title ?? description
    self.nutrition = result?.totals.hasNumbers == true ? result?.estimatedNutrition : nil
    self.analysisInput = result == nil ? nil : description
  }
  public var valid: Bool {
    description.count <= 3000 && title.count <= 3000 && date.timeIntervalSince1970.isFinite && (photo.map { !$0.isEmpty && $0.count <= 20_000_000 } ?? true) && (nutrition?.valid ?? true)
  }
  public mutating func invalidateEstimate() {
    result = nil; analysisInput = nil
    if nutrition?.source == "AI 估计" { nutrition = nil }
  }
}
public struct HomeComposerDraft: Codable {
  public var text = ""
  public var photo: Data?
  public var state = "editing"
  public init() {}
}

public enum AssistantContext {
  public static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
  // Never upload ReviewEngine.token: it contains reversible copies of raw records.
  // Canonicalize sets/arrays so mere encoding order cannot expire a proposal.
  public static func fingerprint(_ data: AppData) -> String {
    var relevant = data
    TrainingSafety.migrateLegacy(&relevant)
    relevant.conversation = nil; relevant.homeComposer = nil; relevant.pendingHomeMeal = nil
    relevant.coachThreads = nil; relevant.activeCoachThreadID = nil
    relevant.coachJobCleanup = nil
    relevant.homeCommitIDs = nil; relevant.selectedTab = 0; relevant.healthAnchors = [:]
    relevant.personalAgent?.operations = []; relevant.personalAgent?.receipts = []
    if relevant.personalAgent?.memories.isEmpty == true && relevant.personalAgent?.forgotten.isEmpty == true && relevant.personalAgent?.historyAfter == nil && (relevant.personalAgent?.revision ?? 0) == 0 { relevant.personalAgent = nil }
    relevant.healthSyncedAt = nil; relevant.lastHealthSummary = nil; relevant.healthAutoSyncEnabled = nil
    return digest(ReviewEngine.canonical(relevant))
  }
  public static func planVersion(_ data: AppData) -> String { "c\(data.coach?.revision ?? 0)-t\(data.training?.revision ?? 0)" }
  public static func isFresh(_ exchange: CoachExchange, data: AppData, now: Date = Date()) -> Bool {
    guard let date = ISO8601DateFormatter().date(from: exchange.snapshot.generated_at),
      date <= now, now.timeIntervalSince(date) < 24 * 3600,
      Calendar.current.isDate(date, inSameDayAs: now),
      exchange.snapshot.timezone == TimeZone.current.identifier else { return false }
    guard !hasUnresolvedSafetyPause(data) else { return false }
    return exchange.fingerprint == fingerprint(data) && exchange.snapshot.expected_plan_version == planVersion(data)
  }
  public static func hasUnresolvedSafetyPause(_ data: AppData) -> Bool {
    TrainingSafety.isPaused(data)
  }
  public static func history(_ turns: [CoachTurn], includeHealth: Bool) -> [RouterHistory] {
    // Withdrawing summary consent must also remove assistant replies that could quote health facts.
    turns.filter { $0.isComplete }.filter { includeHealth || ($0.requiresSummaryConsent != true && $0.exchange?.snapshot.facts.isEmpty != false) }.suffix(4).flatMap { turn in
      [RouterHistory(role: "user", content: String(turn.text.prefix(800))),
       RouterHistory(role: "assistant", content: String((turn.reply + (turn.outcome.map { "\n本机结果：" + $0 } ?? "")).prefix(800)))]
    }
  }
  public static func build(_ data: AppData, text: String, includeHealth: Bool, now: Date = Date()) -> CoachContextBundle {
    let fingerprint = fingerprint(data), iso = ISO8601DateFormatter(), calendar = Calendar.current
    var facts: [CoachFact] = [], candidates: [CoachCandidate] = [], proposals: [CoachLocalProposal] = []
    func fact(_ id: String, _ summary: String, _ unit: String = "说明", _ observed: Date? = nil, _ quality: String = "本机计算") {
      facts.append(.init(id: id, summary: String(summary.prefix(4000)), unit: unit, observed_at: observed.map(iso.string), source_id: "local:" + id, revision: fingerprint, quality: quality))
    }
    if includeHealth {
      if let confirmed = data.profile.confirmedAt {
        fact("profile", "已确认档案：年龄 \(data.profile.age)；身高 \(data.profile.heightCM) cm；目标：\(data.profile.goal)。档案起点不是当前测量。", "岁/cm", confirmed, "用户确认")
      } else { fact("profile", "基础档案未再次确认，不能把默认值当作当前事实。", "说明", nil, "未知") }
      let prefs = data.coach?.preferences
      if let date = prefs?.confirmedAt, let prefs {
        fact("training.conditions", "\(prefs.experience)；\(prefs.equipment)；\(prefs.restrictions) \(prefs.restrictionNote)；训练日 \(prefs.trainingWeekdays.sorted())；默认 \(prefs.workoutMinutes) 分钟；阶段 \(prefs.trainingPhase ?? "未确认")。", "分钟/星期", date, "用户确认")
      } else { fact("training.conditions", "训练条件尚未确认，请先确认。", "说明", nil, "未知") }
      if let check = data.coach?.checkIn, calendar.isDate(check.date, inSameDayAs: now), check.confirmedFields == nil {
        fact("today", "\(check.energy)，\(check.context)，\(check.minutes) 分钟；轻松版 \(check.lighter == true)；打球后疲劳 \(check.sportFatigue == true)。", "分钟", check.date, "用户确认")
      } else { fact("today", "今天的状态、地点和可用时间尚未确认。", "说明", nil, "未知") }
      let plan = DailyPlanner.plan(data, now: now)
      let exercises = (data.draft?.planned ?? plan.exercises).map { "\(TrainingLibrary.guide($0.exerciseID)?.name ?? $0.exerciseID)：\($0.sets) 组 × \($0.reps)，休息 \($0.restSeconds ?? 90) 秒" }.joined(separator: "；")
      fact("training.plan", "\(plan.title)；状态 \(plan.status)；\(plan.reason)；\(exercises)；当前草稿已有 \(data.draft?.sets.count ?? 0) 组实际记录。", "组/次/秒", now)
      let since = calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: now))!
      let workouts = data.workouts.filter { $0.date >= since && $0.date <= now }.sorted { $0.date < $1.date }
      let performances = workouts.suffix(4).map { workout in
        "\(iso.string(from: workout.date)) \(workout.name) \(workout.minutes) 分钟；" + workout.sets.suffix(8).map { "\($0.exercise) \($0.kg) kg × \($0.reps)，余力 \($0.rir.map(String.init) ?? "未知")" }.joined(separator: "；")
      }.joined(separator: "\n")
      fact("training.history", "近 14 天已保存 \(workouts.count) 次训练。漏记不等于没练。\n\(performances)", "次/kg/分钟", workouts.last?.date, workouts.isEmpty ? "未知" : "实际记录")
      let diary = FoodDiaryEngine.report(data, now: now)
      func nutrient(_ label: String, _ n: NutrientTotal) -> String { "\(label) \(n.value.map { String(format: "%.1f", $0) } ?? "未知")（\(n.coveredMeals)/\(n.totalMeals) 条覆盖）" }
      fact("food.today", diary.assessment + "\n" + [nutrient("能量 kcal", diary.energy), nutrient("蛋白质 g", diary.protein), nutrient("碳水 g", diary.carbs), nutrient("脂肪 g", diary.fat)].joined(separator: "；") + "；AI/自行估计 \(diary.estimatedMeals) 餐；已记录：" + diary.meals.map(\.title).joined(separator: "、"), "kcal/g/覆盖率", diary.meals.last?.date, "已确认记录的汇总，可能不完整")
      fact("food.constraints", data.profile.allergiesReviewed ? "已确认排除食材：" + data.profile.excludedFoods.sorted().map(FoodCatalog.name).joined(separator: "、") : "过敏与忌口未确认，不提供可直接执行的配餐。", "说明", data.profile.confirmedAt, data.profile.allergiesReviewed ? "用户确认" : "未知")
      let pantryFresh = DailyPlanner.pantryFresh(data, now: now)
      fact("food.pantry", pantryFresh ? "当日确认的库存：" + data.pantry.sorted().map(FoodCatalog.name).joined(separator: "、") : "库存未在今天确认，先询问目前食材。", "食材", data.pantryConfirmedAt, pantryFresh ? "用户确认" : "过期或未知")
      if pantryFresh && data.profile.allergiesReviewed {
        let meals = MealEngine.suggest(pantry: data.pantry, excluded: data.profile.excludedFoods, maxMinutes: prefs?.cookingMinutes ?? 30, reviewed: true)
        for suggestion in meals.prefix(3) {
          let recipe = suggestion.recipe
          fact("recipe." + recipe.id, "\(recipe.name)，约 \(recipe.minutes) 分钟；食材：\(recipe.ingredients.map(FoodCatalog.name).joined(separator: "、"))；需购买：\(suggestion.missing.map(FoodCatalog.name).joined(separator: "、"))；做法：\(recipe.directions.joined(separator: "；"))；\(recipe.note)。未核验份量及每日营养目标。", "分钟", now, "受控菜谱候选")
        }
      }
      let weight = HealthAnalytics.weight(data.weights, days: 30, now: now)
      fact("body.weight", "近 30 天 \(weight.daily.count) 个测量日；最新：" + (weight.latest.map { "\($0.kg) kg，\(iso.string(from: $0.date))，来源 \($0.source)" } ?? "暂无可用记录") + "；近 7 天均值 \(weight.currentMean.map { String(format: "%.2f", $0) } ?? "未知") kg，前 7 天均值 \(weight.previousMean.map { String(format: "%.2f", $0) } ?? "未知") kg。", "kg/测量日", weight.latest?.date, "实测聚合")
      let projection = WeightProjector.project(data.weights, now: now)
      fact("body.forecast", projection.message + projection.points.map { String(format: "；%d 天后 %.1f–%.1f kg", $0.days, $0.low, $0.high) }.joined(), "kg/天", now, "条件统计外推，不是目标或保证")
      let sleep = HealthAnalytics.sleep(data.sleep, days: 7, now: now)
      fact("body.sleep", "近 7 天有 \(sleep.count) 个睡眠日记录；" + (sleep.last.map { String(format: "最近睡眠 %.1f 小时，REM %.1f、核心 %.1f、深度 %.1f 小时；来源 %@。设备分期为估计；当日可能不完整。", $0.sleepSeconds / 3600, $0.seconds(.rem) / 3600, $0.seconds(.core) / 3600, $0.seconds(.deep) / 3600, $0.source) } ?? "暂无可用记录，不能判断是权限还是无数据。"), "小时/记录日", sleep.last?.end, "区间去重后的设备估计")
      let review = ReviewEngine.review(data, now: now)
      fact("review", "近 7 天已记录训练 \(review.workoutDays) 天、餐食 \(review.meals) 条、反馈 \(review.feedbackCount) 次。\(review.reason)", "天/条/次", now)
      if hasUnresolvedSafetyPause(data) { fact("safety", TrainingSafety.message, "说明", now, "需要明确核对恢复") }
      if !hasUnresolvedSafetyPause(data), let minutes = HomeCoach.minutes(in: text), var check = data.coach?.checkIn,
        calendar.isDate(check.date, inSameDayAs: now), check.energy != "未确认", check.energy != "不适或困倦" {
        let old = check.minutes; check.minutes = minutes; check.date = now
        let id = UUID().uuidString
        candidates.append(.init(id: id, action: .adjustToday, title: "今天改为 \(minutes) 分钟", detail: "\(old) → \(minutes) 分钟；保留已完成组数，剩余目标重新评估，不改变长期偏好。", evidence_ids: ["today", "training.plan"]))
        proposals.append(.init(id: id, kind: "checkIn", checkIn: check, preferences: nil))
      }
      if !hasUnresolvedSafetyPause(data), let next = review.proposed, data.draft == nil {
        let id = UUID().uuidString
        candidates.append(.init(id: id, action: .review, title: "采用本周时间调整", detail: review.reason, evidence_ids: ["review", "training.conditions"]))
        proposals.append(.init(id: id, kind: "review", checkIn: nil, preferences: next))
      }
    }
    return .init(snapshot: .init(snapshot_id: UUID().uuidString, generated_at: iso.string(from: now), timezone: TimeZone.current.identifier, expected_plan_version: includeHealth ? planVersion(data) : "withheld", facts: facts, candidates: candidates), fingerprint: fingerprint, proposals: proposals)
  }
}

public enum AssistantTransactions {
  public static func applyDailyCheck(_ check: DailyCheckIn, to data: inout AppData, now: Date = Date()) {
    TrainingSafety.migrateLegacy(&data)
    if check.energy == "不适或困倦" { TrainingSafety.pause(&data, at: now) }
    if data.coach == nil { data.coach = CoachState() }
    data.coach?.checkIn = check
    let plan = DailyPlanner.plan(data, now: now)
    var state = data.training ?? TrainingState(); state.revision += 1
    let exclusions = (check.excludedExercises ?? []).sorted().map { TrainingLibrary.guide($0)?.name ?? $0 }.joined(separator: "、")
    let note = "\(check.context) · \(check.minutes) 分钟 · \(check.energy)" + (check.lighter == true ? " · 轻松版" : "") + (check.sportFatigue == true ? " · 打球后疲劳减量" : "") + (exclusions.isEmpty ? "" : " · 今天不做：" + exclusions)
    state.events.append(TrainingEvent(kind: "当天调整", reason: note, revision: state.revision)); data.training = state
    if data.draft != nil {
      if plan.status == "ready" { data.draft?.planned = plan.exercises }
      data.draft?.targets = []
      data.draft?.adaptationNote = note + "。已完成组数保留；剩余动作需重新确认建议。"
    }
  }
  public static func confirm(turnID: UUID, candidateID: String, data: inout AppData, now: Date = Date()) throws {
    guard let index = data.conversation?.firstIndex(where: { $0.id == turnID }),
      let turn = data.conversation?[index], let exchange = turn.exchange,
      !exchange.appliedIDs.contains(candidateID),
      !(data.homeCommitIDs ?? []).contains(candidateID),
      exchange.response.cards.contains(where: { $0.candidate_id == candidateID }),
      let saved = exchange.proposals.first(where: { $0.id == candidateID }),
      AssistantContext.isFresh(exchange, data: data, now: now) else { throw CoachError.stale }
    // Recompute current local business rules; never execute model supplied writes.
    let current = AssistantContext.build(data, text: turn.text, includeHealth: true, now: now)
    guard let fresh = current.proposals.first(where: { $0.kind == saved.kind }) else { throw CoachError.stale }
    if fresh.kind == "checkIn", let check = fresh.checkIn, check.minutes == saved.checkIn?.minutes {
      applyDailyCheck(check, to: &data)
    } else if fresh.kind == "review", fresh.preferences == saved.preferences, data.draft == nil {
      try ReviewEngine.apply(ReviewEngine.review(data, now: now), to: &data, now: now)
    } else { throw CoachError.invalid }
    data.conversation?[index].exchange?.appliedIDs.append(candidateID)
    data.conversation?[index].outcome = "已确认并应用：" + (exchange.snapshot.candidates.first { $0.id == candidateID }?.title ?? "计划调整")
    data.homeCommitIDs = Array(((data.homeCommitIDs ?? []) + [candidateID]).suffix(2000))
  }
}
