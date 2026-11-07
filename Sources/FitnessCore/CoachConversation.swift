import Foundation

public enum CoachAction: String, Codable, CaseIterable, Identifiable {
  case daily, training, adjustToday, meal, foodIdeas, weight, forecast, sleep, review, records, settings, recordWeight
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .daily: return "今日 Fit 方案"
    case .training: return "训练计划与记录"
    case .adjustToday: return "调整今天的训练"
    case .meal: return "分析 / 记录这一餐"
    case .foodIdeas: return "下一餐怎么搭配"
    case .weight: return "体重趋势"
    case .forecast: return "预计体重"
    case .sleep: return "睡眠分析"
    case .review: return "本周复盘"
    case .records: return "分模块记录"
    case .settings: return "我的设置"
    case .recordWeight: return "确认体重记录"
    }
  }
  public var symbol: String {
    switch self {
    case .daily:return "sun.max"
    case .training,.adjustToday:return "dumbbell"
    case .meal,.foodIdeas:return "fork.knife"
    case .weight,.recordWeight:return "scalemass"
    case .forecast:return "chart.xyaxis.line"
    case .sleep:return "moon.zzz"
    case .review:return "calendar"
    case .records:return "square.grid.2x2"
    case .settings:return "slider.horizontal.3"
    }
  }
}
public struct CoachTurn: Codable, Identifiable {
  public var id = UUID()
  public var threadID: UUID?
  public var deliveryState: String?
  public var attemptID: UUID?
  public var deliveryError: String?
  public var model: String?
  public var generation: CoachGenerationOptions?
  public var photo: Data?
  public var relatedMealID: UUID?
  public var remoteJob: CoachRemoteJob?
  public var date = Date()
  public var text: String
  public var reply: String
  public var actions: [CoachAction]
  public var origin: String
  public var exchange: CoachExchange?
  public var outcome: String?
  public var requiresSummaryConsent: Bool?
  public var requiresMemoryConsent: Bool?
  public var agentOperationIDs: [UUID]?
  public init(text: String, reply: String, actions: [CoachAction], origin: String = "本地教练") {
    self.text=text; self.reply=reply; self.actions=actions; self.origin=origin
  }
  public var isComplete: Bool { deliveryState == nil }
  public var valid: Bool {
    guard remoteJob.map({ $0.valid && $0.id == attemptID && deliveryState == "sending" }) ?? true else { return false }
    guard deliveryState.map({ ["sending", "failed", "stopped"].contains($0) }) ?? true,
      deliveryState == nil || (attemptID != nil && exchange == nil),
      generation?.valid ?? true, (deliveryError?.count ?? 0) <= 500, (model?.count ?? 0) <= 100,
      photo.map({ !$0.isEmpty && $0.count <= 20_000_000 }) ?? true else { return false }
    guard !text.isEmpty, text.count <= 3000, reply.count <= 3000, actions.count <= 4,
      (outcome?.count ?? 0) <= 1000 else { return false }
    if let exchange {
      guard (try? exchange.response.validate(requestID: exchange.response.request_id, snapshot: exchange.snapshot)) != nil,
        exchange.fingerprint.count == 64, exchange.snapshot.facts.count <= (exchange.response.contract_version == 2 ? 64 : 24),
        exchange.snapshot.candidates.count <= 4,
        Set(exchange.proposals.map(\.id)) == Set(exchange.snapshot.candidates.map(\.id)),
        exchange.appliedIDs.allSatisfy({ id in exchange.proposals.contains { $0.id == id } }) else { return false }
    }
    return true
  }
}

public struct CoachThread: Codable, Identifiable {
  public var id = UUID()
  public var title = "新对话"
  public var createdAt = Date()
  public var updatedAt = Date()
  public var pinned = false
  public var archived = false
  public var noLongTermMemory: Bool?
  // Inactive threads keep their unfinished input here. The active thread uses the
  // original top-level fields, preserving v0.7 storage and confirmation behavior.
  public var composer: HomeComposerDraft?
  public var pendingMeal: HomeMealDraft?
  public init() {}
}
public enum CoachThreads {
  @discardableResult public static func interruptUnfinished(_ data: inout AppData) -> Bool {
    guard data.conversation?.contains(where: { $0.deliveryState == "sending" && $0.remoteJob == nil }) == true else { return false }
    for index in data.conversation!.indices where data.conversation?[index].deliveryState == "sending" && data.conversation?[index].remoteJob == nil {
      data.conversation?[index].deliveryState = "stopped"
    }
    return true
  }
  public static let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
  public static func turns(_ data: AppData, in id: UUID? = nil) -> [CoachTurn] {
    let selected = id ?? data.activeCoachThreadID ?? legacyID
    return (data.conversation ?? []).filter { ($0.threadID ?? legacyID) == selected }
  }
  public static func hasHistory(_ data: AppData, in id: UUID) -> Bool {
    if (data.conversation ?? []).contains(where: { ($0.threadID ?? legacyID) == id }) { return true }
    // Older versions could retain a completed photo analysis without a chat turn.
    // Keep those pending results reachable; unsent composer input is not history.
    if id == (data.activeCoachThreadID ?? legacyID) { return data.pendingHomeMeal != nil }
    return data.coachThreads?.first(where: { $0.id == id })?.pendingMeal != nil
  }
  public static func historyThreads(_ data: AppData) -> [CoachThread] {
    (data.coachThreads ?? []).filter { hasHistory(data, in: $0.id) }
  }
  public static func prepare(_ data: inout AppData) {
    guard data.coachThreads == nil else { return }
    var thread = CoachThread(); thread.id = legacyID
    if let first = data.conversation?.first {
      thread.title = String(first.text.replacingOccurrences(of: "\n", with: " ").prefix(36))
      thread.createdAt = first.date
      thread.updatedAt = data.conversation?.last?.date ?? first.date
    }
    data.coachThreads = [thread]; data.activeCoachThreadID = thread.id
  }
  public static func record(_ source: CoachTurn, into data: inout AppData) {
    TrainingSafety.migrateLegacy(&data)
    TrainingSafety.observe(source, in: &data)
    prepare(&data)
    var turn = source; turn.threadID = turn.threadID ?? data.activeCoachThreadID ?? legacyID
    var turns = (data.conversation ?? []) + [turn]
    while turns.count > 200, let i = turns.firstIndex(where: { $0.remoteJob == nil }) { turns.remove(at: i) }
    data.conversation = turns
    if let index = data.coachThreads?.firstIndex(where: { $0.id == turn.threadID }) {
      data.coachThreads?[index].updatedAt = turn.date
      if data.coachThreads?[index].title == "新对话" {
        data.coachThreads?[index].title = String(turn.text.replacingOccurrences(of: "\n", with: " ").prefix(36))
      }
    }
  }
  public static func switchTo(_ id: UUID, data: inout AppData) -> Bool {
    prepare(&data)
    guard let target = data.coachThreads?.firstIndex(where: { $0.id == id }) else { return false }
    if data.activeCoachThreadID == id { return true }
    if let current = data.coachThreads?.firstIndex(where: { $0.id == data.activeCoachThreadID }) {
      data.coachThreads?[current].composer = data.homeComposer
      data.coachThreads?[current].pendingMeal = data.pendingHomeMeal
    }
    data.homeComposer = data.coachThreads?[target].composer
    data.pendingHomeMeal = data.coachThreads?[target].pendingMeal
    data.coachThreads?[target].composer = nil; data.coachThreads?[target].pendingMeal = nil
    data.activeCoachThreadID = id
    return true
  }
}
public struct RouterHistory: Codable {
  public let role: String
  public let content: String
  public init(role: String, content: String) { self.role=role; self.content=content }
}
public struct AssistantRoute: Codable {
  public var request_id: String
  public var reply: String
  public var status: String
  public var actions: [CoachAction]
  public func validate(id: String) throws {
    guard request_id == id, !reply.isEmpty, reply.count <= 1200, actions.count <= 4, ["ready","needs_input","safety_pause"].contains(status), (status != "safety_pause" || actions.isEmpty), Set(actions).count == actions.count else { throw MealAgentError.invalid }
  }
}
public enum HomeCoach {
  // Exact common requests work offline. Free text uses the explicit cloud route.
  public static func localActions(_ input: String) -> [CoachAction]? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let exact: [String:[CoachAction]] = ["今天怎么安排":[.daily],"给我今天的 Fit 方案":[.daily],"今天练什么":[.training],"记录一餐":[.meal],"下一餐吃什么":[.foodIdeas],"看看我的体重":[.weight],"预计体重":[.forecast],"我最近睡得怎么样":[.sleep],"这周怎么样":[.review],"查看所有记录":[.records],"打开设置":[.settings]]
    return exact[text]
  }
  public static func minutes(in text: String) -> Int? {
    let regex = try! NSRegularExpression(pattern: "(?<![0-9.])(\\d{1,3})\\s*分钟")
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text), let value = Int(text[range]), (1...120).contains(value) else { return nil }
    return value
  }
}

public struct WeightProjectionPoint: Identifiable {
  public var id: Int { days }
  public let days: Int
  public let date: Date
  public let kg: Double
  public let low: Double
  public let high: Double
}
public struct WeightProjection {
  public let measured: [WeightEntry]
  public let points: [WeightProjectionPoint]
  public let message: String
  public let weeklySlope: Double?
}
public enum WeightProjector {
  /// Short-horizon linear extrapolation, NOT a metabolic model or target recommendation.
  /// Range uses residual variation and grows with distance from observed data; no probability claim.
  public static func project(_ entries: [WeightEntry], now: Date = Date(), calendar: Calendar = .current) -> WeightProjection {
    let report=HealthAnalytics.weight(entries, days: 30, now: now, calendar: calendar)
    let daily=report.daily
    func unavailable(_ message: String) -> WeightProjection { .init(measured: daily, points: [], message: message, weeklySlope: nil) }
    guard let first=daily.first, let last=daily.last else { return unavailable("先积累真实称重。档案起始体重不会用于预测。") }
    let span=calendar.dateComponents([.day], from: calendar.startOfDay(for: first.date), to: calendar.startOfDay(for: last.date)).day ?? 0
    guard daily.count >= 10, span >= 13 else { return unavailable("近 30 天已有 \(daily.count) 个测量日。至少积累跨 14 天、10 个不同日期的记录后，再显示短期趋势外推。") }
    guard (calendar.dateComponents([.day], from: calendar.startOfDay(for: last.date), to: calendar.startOfDay(for: now)).day ?? 99) <= 3 else { return unavailable("最近一次测量已超过 3 天，先更新体重，再看外推。") }
    guard Set(daily.map(\.source)).count == 1 else { return unavailable("这段记录混有不同来源，先保持同一来源与称重条件；暂不把它们拼成预计体重。") }
    let xs=daily.map { Double(calendar.dateComponents([.day], from: calendar.startOfDay(for: first.date), to: calendar.startOfDay(for: $0.date)).day ?? 0) }
    let ys=daily.map(\.kg), n=Double(daily.count)
    let mx=xs.reduce(0,+)/n, my=ys.reduce(0,+)/n
    let sxx=xs.reduce(0) { $0 + pow($1-mx,2) }
    guard sxx>0 else { return unavailable("有效测量跨度不足。") }
    let slope=zip(xs,ys).reduce(0) { $0 + ($1.0-mx)*($1.1-my) }/sxx
    let residual=sqrt(zip(xs,ys).reduce(0) { $0 + pow($1.1-(my+slope*($1.0-mx)),2) }/(n-2))
    // Rapid discontinuities and unrealistic extrapolations are withheld, never clamped to a desired loss.
    guard abs(slope)*7 <= my*0.02 else { return unavailable("近期变化幅度较大，直线外推容易误导。先核对测量条件，继续观察实际趋势。") }
    let todayX=Double(calendar.dateComponents([.day], from: calendar.startOfDay(for: first.date), to: calendar.startOfDay(for: now)).day ?? 0)
    let points=[7,14].compactMap { days -> WeightProjectionPoint? in
      let x=todayX+Double(days), value=my+slope*(x-mx)
      let band=max(0.3,residual*2)*sqrt(1+1/n+pow(x-mx,2)/sxx)
      guard DataMath.validWeight(value-band), DataMath.validWeight(value+band) else { return nil }
      return .init(days: days, date: calendar.date(byAdding: .day,value: days,to: now)!, kg: value, low: value-band, high: value+band)
    }
    return .init(measured: daily, points: points, message: "假设近期趋势延续，外推未来 7 / 14 天。范围反映近期波动并设最低展示宽度，不是置信区间、目标或减重保证；不能推算脂肪变化或达标日期。", weeklySlope: slope*7)
  }
}
