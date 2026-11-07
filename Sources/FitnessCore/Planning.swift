import Foundation

public struct CoachPreferences: Codable, Equatable {
  public var programID: String?
  public var trainingPhase: String?
  public var experience = "未确认"
  public var equipment = "未确认"
  public var restrictions = "未确认"
  public var restrictionNote = ""
  public var workoutMinutes = 45
  public var cookingMinutes = 30
  public var trainingWeekdays: Set<Int> = [2, 4, 6]
  public var confirmedAt: Date?
  public init() {}
}
public struct DailyCheckIn: Codable {
  // nil is a legacy full-form confirmation; new chat patches name only known fields.
  public var confirmedFields: Set<String>?
  public var date = Date()
  public var energy = "未确认"
  public var context = "健身房"
  public var sportFatigue: Bool?
  public var lighter: Bool?
  public var excludedExercises: Set<String>?
  public var minutes = 45
  public init() {}
}
public struct CoachFeedback: Codable, Identifiable {
  public var id = UUID()
  public var date = Date()
  public var kind: String
  public var reason: String
  public init(kind: String, reason: String, date: Date = Date()) { self.kind = kind; self.reason = reason; self.date = date }
}
public struct PlanChange: Codable, Identifiable {
  public var id = UUID()
  public var date = Date()
  public var before: CoachPreferences
  public var after: CoachPreferences
  public var reason: String
  public var evidence: [String]
  public var revision: Int
  public init(before: CoachPreferences, after: CoachPreferences, reason: String, evidence: [String], revision: Int) {
    self.before = before; self.after = after; self.reason = reason; self.evidence = evidence; self.revision = revision
  }
}
public struct CoachState: Codable {
  public var preferences = CoachPreferences()
  public var checkIn: DailyCheckIn?
  public var feedback: [CoachFeedback] = []
  public var revision = 0
  public var changes: [PlanChange] = []
  public init() {}
}
public struct ExerciseGuide: Identifiable, Codable {
  public let id: String
  public let name: String
  public let equipment: String
  public let cue: String
  public let avoid: String
  public let alternativeID: String?
}
public struct PlannedExercise: Codable, Identifiable {
  public var id = UUID()
  public var exerciseID: String
  public var restSeconds: Int?
  public var lowerReps: Int?
  public var upperReps: Int?
  public var priorSetIDs: Set<UUID>?
  public var sets: Int
  public var reps: String
  public init(_ exerciseID: String, sets: Int = 1, reps: String = "8–12 次") {
    self.exerciseID = exerciseID; self.sets = sets; self.reps = reps
  }
}
public struct DailyWorkoutPlan {
  public let title: String
  public let reason: String
  public let exercises: [PlannedExercise]
  public let status: String
}
public enum TrainingLibrary {
  public static func availableIDs(equipment: String, context: String) -> [String] {
    if context == "在家" || equipment == "徒手" { return ["sit", "wall", "calf", "bridge", "deadbug"] }
    if equipment == "只有哑铃" { return ["sit", "wall", "calf", "dbrow", "bridge", "deadbug", "lateral"] }
    if equipment == "器械与哑铃" { return guides.map(\.id) }
    return []
  }
  public static let guides: [ExerciseGuide] = [
    .init(id: "sit", name: "椅子坐站", equipment: "稳固椅子", cue: "椅子靠墙固定。双脚踩实，身体略前倾站起，再缓慢坐下。", avoid: "不要用带轮椅子；膝、腰不舒服时停止。", alternativeID: nil),
    .init(id: "wall", name: "墙壁俯卧撑", equipment: "墙壁", cue: "双手约肩高撑墙，身体保持一条线；屈肘靠近，再推离墙面。", avoid: "不塌腰、不耸肩；站近一点可降低难度。", alternativeID: nil),
    .init(id: "calf", name: "扶稳提踵", equipment: "稳固支撑", cue: "扶稳椅背或墙，缓慢抬起脚跟，再放回地面。", avoid: "不弹跳；脚踝疼痛或失去平衡时停止。", alternativeID: nil),
    .init(id: "press", name: "坐姿器械推胸", equipment: "推胸器械", cue: "请场馆教练协助调座椅，让握把约在胸口高度；背贴靠垫，平稳推回。", avoid: "不要耸肩或锁死肘部；第一次先学习器械设置。", alternativeID: "wall"),
    .init(id: "row", name: "坐姿器械划船", equipment: "划船器械", cue: "调好胸垫或坐姿，躯干稳定，将握把拉向身体，再缓慢还原。", avoid: "不借腰猛拉；不会调器械时先请场馆教练示范。", alternativeID: "dbrow"),
    .init(id: "dbrow", name: "支撑式哑铃划船", equipment: "哑铃与训练凳", cue: "单手支撑稳固训练凳，背部保持自然；另一手将轻哑铃拉向腰侧。", avoid: "躯干不扭转，不用甩动完成；左右侧分别记录。", alternativeID: "row"),
    .init(id: "pulldown", name: "高位下拉", equipment: "高位下拉器械", cue: "调整腿垫固定大腿，握距舒适。胸部自然抬起，握把拉向上胸，再缓慢回放。", avoid: "不拉到颈后，不后仰甩动；肩部不适时停止。", alternativeID: "row"),
    .init(id: "curl", name: "坐姿腿弯举", equipment: "腿弯举器械", cue: "请教练调好转轴和腿垫，膝关节对齐器械转轴；背贴垫，缓慢屈膝再还原。", avoid: "不抬臀借力，不猛甩重量；膝部不适时停止。", alternativeID: "bridge"),
    .init(id: "shoulder", name: "坐姿器械推肩", equipment: "推肩器械", cue: "调节座椅到握把约肩高，背贴垫，在舒适范围内向上推，再缓慢下降。", avoid: "不挺腰借力、不锁死肘部；不会调整或肩部不适时先请教练评估。", alternativeID: "wall"),
    .init(id: "bridge", name: "自重臀桥", equipment: "训练垫", cue: "仰卧屈膝、双脚踩实；收紧臀部抬髋至躯干与大腿近一条线，再慢慢落下。", avoid: "不用腰向上顶；腰痛则停止。上下地面困难时请教练协助选择替代。", alternativeID: "curl"),
    .init(id: "lateral", name: "坐姿哑铃侧平举", equipment: "轻哑铃与稳固训练凳", cue: "坐稳，手肘微屈，轻哑铃向两侧抬至舒适高度，再控制下降。两侧一起完成，重量记单只。", avoid: "不耸肩、不甩动，不强求抬到肩高；肩部不适时停止。", alternativeID: nil),
    .init(id: "deadbug", name: "仰卧交替抬脚（核心）", equipment: "训练垫", cue: "仰卧屈膝双脚着地，腹部轻收紧，交替缓慢抬起一只脚再落地；呼吸保持自然。左右各做规定次数，一组做完两侧后记录每侧次数。", avoid: "腰部保持舒适，不憋气、不拱腰；腰痛或上下地面不适时停止。", alternativeID: nil),
    .init(id: "leg", name: "坐姿腿举", equipment: "腿举器械", cue: "请场馆教练调好座椅和安全挡位，背臀贴垫；在无不适范围内平稳推回。", avoid: "不锁死膝盖、不让腰离开靠垫、不追求过深幅度。", alternativeID: "sit")
  ]
  public static func guide(_ id: String) -> ExerciseGuide? { guides.first { $0.id == id } }
  public static func alternatives(for id: String, equipment: String, context: String) -> [ExerciseGuide] {
    guard let alternative = guide(id)?.alternativeID, let result = guide(alternative) else { return [] }
    let available = availableIDs(equipment: equipment, context: context)
    return available.contains(result.id) ? [result] : []
  }
}
public enum DailyPlanner {
  public static func plan(_ data: AppData, now: Date = Date(), calendar: Calendar = .current) -> DailyWorkoutPlan {
    let state = data.coach ?? CoachState(), prefs = state.preferences
    func message(_ title: String, _ reason: String, _ status: String) -> DailyWorkoutPlan { .init(title: title, reason: reason, exercises: [], status: status) }
    guard !TrainingSafety.isPaused(data) else { return message("训练建议已暂停", TrainingSafety.message, "pause") }
    guard prefs.confirmedAt != nil, prefs.experience != "未确认", prefs.equipment != "未确认", !prefs.trainingWeekdays.isEmpty else { return message("先确认训练条件", "告诉我熟悉程度、可用器械与训练日，再安排今天。", "setup") }
    guard let check = state.checkIn, check.date <= now, calendar.isDate(check.date, inSameDayAs: now) else { return message("今天状态怎么样？", "确认今天的感受和可用时间后生成安排。", "checkin") }
    if let fields = check.confirmedFields, !Set(["energy", "context", "minutes"]).isSubset(of: fields) { return message("还缺一点当天信息", "已保存你明确说过的条件；其余信息仍未知，可以在对话里继续补充。", "checkin") }
    guard check.energy != "不适或困倦", check.energy != "未确认" else { return message("今天先暂停训练建议", "有头晕、困倦、动作不稳或疼痛时先不做器械训练；持续或明显不适请寻求专业帮助。", "pause") }
    if check.context == "休息" { return message("今天按休息日安排", "休息不会产生欠下的训练量，下次从正常计划继续。", "rest") }
    if check.context == "乒乓球" { return message("今天以乒乓球为主", "按你今天的体感安排，不额外叠加力量训练；打完可记录时长和感受。", "sport") }
    guard prefs.restrictions == "没有已知限制" else { return message("先明确运动限制", "当前条件需要另行确认，暂不自动生成力量方案；仍可记录已由专业人员确定的训练。", "pause") }
    let finishedToday = data.workouts.contains { calendar.isDate($0.date, inSameDayAs: now) && $0.date <= now }
    if finishedToday { return message("今天已记录训练", "今天不自动追加一份训练；可以查看记录或按实际情况手动记录其他活动。", "rest") }
    let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
    if data.workouts.contains(where: { $0.date >= yesterday && $0.date < calendar.startOfDay(for: now) && !$0.sets.isEmpty }) {
      return message("今天留给恢复", "昨天有力量训练记录，今天不连续安排同类全身模板。可以按体感休息或轻松活动。", "rest")
    }
    guard prefs.trainingWeekdays.contains(calendar.component(.weekday, from: now)) else { return message("今天是计划中的休息日", "不安排补偿训练。可在训练条件中调整训练日，或记录你实际进行的活动。", "rest") }
    let light = check.minutes <= 20 || check.energy == "有点疲惫" || check.lighter == true || check.sportFatigue == true
    if prefs.programID == StrengthProgram.id && check.context == "健身房" && prefs.equipment == "器械与哑铃" {
      let slot = (data.training?.sequenceIndex ?? 0) % 3
      let exercises = StrengthProgram.session(slot, phase: prefs.trainingPhase ?? "恢复适应", minutes: check.minutes, light: light, excluded: check.excludedExercises ?? [])
      guard !exercises.isEmpty else { return message("今天先不安排力量训练", "可用动作已全部排除，请重新确认条件。", "rest") }
      return .init(title: StrengthProgram.names[slot] + " · " + StrengthProgram.duration(minutes: check.minutes, light: light), reason: "每周 3 次主训练，第 4 次可选有氧恢复。当前阶段：" + (prefs.trainingPhase ?? "恢复适应") + "。" + (light ? "今天减量，不追加高强度有氧。" : "先完成稳定动作，再根据实际记录递进。"), exercises: exercises, status: "ready")
    }
    let ids: [String]
    if check.context == "在家" || prefs.equipment == "徒手" { ids = ["sit", "wall", "calf"] }
    else if prefs.equipment == "只有哑铃" { ids = ["sit", "wall", "dbrow"] }
    else { ids = light ? ["leg", "press", "row"] : ["leg", "press", "row", "calf"] }
    let slot = (data.training?.sequenceIndex ?? 0) % 3
    let filtered = ids.filter { !(check.excludedExercises ?? []).contains($0) }
    guard !filtered.isEmpty else { return message("今天先不安排力量模板", "可用动作已全部排除；保留已完成记录，重新确认条件后再安排。", "rest") }
    let offset = slot % filtered.count
    let ordered = Array(filtered[offset...]) + Array(filtered[..<offset])
    let label = ["A", "B", "C"][slot]
    return .init(title: light ? "全身 \(label) · 精简 20 分钟" : "全身 \(label) · 约 35–45 分钟", reason: "根据你确认的训练日、器械、今天状态与可用时间选择。本地入门模板，先热身 5–10 分钟，每个动作从 1 组开始，组间休息约 90 秒；负重自行从轻量校准，不按体重猜重量。", exercises: ordered.map { PlannedExercise($0) }, status: "ready")
  }
  public static func pantryFresh(_ data: AppData, now: Date = Date(), calendar: Calendar = .current) -> Bool {
    data.pantryConfirmedAt.map { $0 <= now && calendar.isDate($0, inSameDayAs: now) } ?? false
  }
}
public struct WeeklyReview {
  public let start: Date
  public let end: Date
  public let workoutDays: Int
  public let meals: Int
  public let feedbackCount: Int
  public let weight: WeightReport
  public let token: String
  public let proposed: CoachPreferences?
  public let reason: String
  public let evidence: [String]
}
public enum ReviewEngine {
  static func canonical<T: Encodable>(_ value: T) -> String {
    func normalize(_ value: Any) -> Any {
      if let object = value as? [String: Any] { return object.mapValues(normalize) }
      if let array = value as? [Any] {
        return array.map(normalize).sorted {
          let a = (try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
          let b = (try? JSONSerialization.data(withJSONObject: $1, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
          return a.lexicographicallyPrecedes(b)
        }
      }
      return value
    }
    guard let bytes = try? JSONEncoder().encode(value), let object = try? JSONSerialization.jsonObject(with: bytes),
      let canonical = try? JSONSerialization.data(withJSONObject: normalize(object), options: [.sortedKeys]) else { return "" }
    return canonical.base64EncodedString()
  }
  public static func apply(_ proposal: WeeklyReview, to data: inout AppData, now: Date = Date(), calendar: Calendar = .current) throws {
    guard !TrainingSafety.isPaused(data) else { throw CoachError.stale }
    let current = review(data, now: now, calendar: calendar)
    guard current.token == proposal.token, let next = current.proposed, let expected = proposal.proposed, next == expected else { throw CoachError.stale }
    var state = data.coach ?? CoachState()
    state.revision += 1
    state.changes.append(PlanChange(before: state.preferences, after: next, reason: current.reason, evidence: current.evidence, revision: state.revision))
    state.preferences = next; data.coach = state
  }

  public static func review(_ data: AppData, now: Date = Date(), calendar: Calendar = .current) -> WeeklyReview {
    let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
    let state = data.coach ?? CoachState()
    let feedback = state.feedback.filter { $0.date >= start && $0.date <= now }
    let timeDays = Set(feedback.filter { $0.kind == "训练" && $0.reason == "时间不够" }.map { calendar.startOfDay(for: $0.date) })
    let workouts = data.workouts.filter { $0.date >= start && $0.date <= now }
    var proposal: CoachPreferences?
    var reason = "先保持当前安排。记录不足不代表执行失败，也不会自动减少饮食或增加训练。"
    if !TrainingSafety.isPaused(data), state.preferences.confirmedAt != nil && timeDays.count >= 2 && state.preferences.workoutMinutes > 20 {
      var prefs = state.preferences; prefs.workoutMinutes = 20; proposal = prefs
      reason = "近 7 天有 \(timeDays.count) 个不同日期反馈训练时间不够，建议先把默认可用时间改为 20 分钟，更容易安排。训练日不变，不自动增加负重。"
    }
    if TrainingSafety.isPaused(data) { reason = TrainingSafety.message }
    // Include every input used by this review. No cloud or logging of this token.
    let token = [String(state.revision), String(start.timeIntervalSince1970), canonical(state), canonical(data.trainingSafety), canonical(workouts), canonical(data.weights), canonical(data.meals)].joined(separator: "|")
    return .init(start: start, end: now, workoutDays: Set(workouts.map { calendar.startOfDay(for: $0.date) }).count, meals: data.meals.filter { $0.date >= start && $0.date <= now && $0.confirmed }.count, feedbackCount: feedback.count, weight: HealthAnalytics.weight(data.weights, days: 14, now: now, calendar: calendar), token: token, proposed: proposal, reason: reason, evidence: feedback.filter { $0.kind == "训练" && $0.reason == "时间不够" }.map { $0.id.uuidString })
  }
}
