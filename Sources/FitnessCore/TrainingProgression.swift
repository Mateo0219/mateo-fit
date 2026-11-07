import Foundation

public struct ExerciseProfile: Codable, Identifiable, Equatable {
  public var id = UUID()
  public var exerciseID: String
  public var equipmentLabel = ""
  public var loadConvention = "器械标示重量"
  public var side = "双侧 / 不适用"
  public var availableLoads: [Double] = []
  public var lowerReps = 8
  public var upperReps = 12
  public var workSets = 1
  public var revision = 1
  public var recalibratedAfter: Date?
  public init(exerciseID: String) { self.exerciseID = exerciseID }
  public var name: String { TrainingLibrary.guide(exerciseID)?.name ?? exerciseID }
  public var valid: Bool {
    TrainingLibrary.guide(exerciseID) != nil && !equipmentLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
    ["器械标示重量", "单只哑铃", "杠铃总重", "自重（不计体重）"].contains(loadConvention) &&
    ["双侧 / 不适用", "左侧", "右侧"].contains(side) && (exerciseID != "dbrow" || side != "双侧 / 不适用") &&
    (1...3).contains(workSets) && (5...20).contains(lowerReps) && (lowerReps...30).contains(upperReps) && revision > 0 &&
    !availableLoads.isEmpty && availableLoads.count <= 100 && Set(availableLoads).count == availableLoads.count &&
    availableLoads.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1000 } &&
    (loadConvention != "自重（不计体重）" || availableLoads == [0])
  }
}
public struct TrainingTarget: Codable, Equatable, Identifiable {
  public var id = UUID()
  public var profileID: UUID
  public var kg: Double?
  public var reps: Int
  public var sets: Int
  public var reason: String
  public var evidence: [UUID]
  public var acceptedAt = Date()
  public init(profileID: UUID, kg: Double?, reps: Int, sets: Int, reason: String, evidence: [UUID]) {
    self.profileID = profileID; self.kg = kg; self.reps = reps; self.sets = sets; self.reason = reason; self.evidence = evidence
  }
}
public struct TrainingEvent: Codable, Identifiable {
  public var id = UUID()
  public var date = Date()
  public var kind: String
  public var reason: String
  public var before: TrainingTarget?
  public var after: TrainingTarget?
  public var revision: Int
  public init(kind: String, reason: String, before: TrainingTarget? = nil, after: TrainingTarget? = nil, revision: Int) {
    self.kind = kind; self.reason = reason; self.before = before; self.after = after; self.revision = revision
  }
}
public struct TrainingState: Codable {
  public var profiles: [ExerciseProfile] = []
  public var sequenceIndex = 0
  public var revision = 0
  public var events: [TrainingEvent] = []
  public init() {}
}
public struct TrainingProposal {
  public let profileID: UUID
  public let token: String
  public let action: String
  public let target: TrainingTarget?
  public let reason: String
}
public enum TrainingProgression {
  public static func planCompleted(_ draft: WorkoutDraft, state: TrainingState?) -> Bool {
    guard !TrainingWorkload.hasDuplicateExercises(draft) else { return false }
    guard let planned = draft.planned, !planned.isEmpty else { return false }
    return planned.allSatisfy { item in
      TrainingWorkload.progress(item, draft: draft, state: state, standardOnly: true).remaining == 0
    }
  }
  public static func history(_ data: AppData, profileID: UUID, now: Date = Date()) -> [SetEntry] {
    data.workouts.filter { $0.date <= now }.sorted { $0.date > $1.date }.flatMap { $0.sets.sorted { $0.date > $1.date } }
      .filter { $0.profileID == profileID && $0.date <= now }
  }
  public static func token(_ data: AppData, now: Date, calendar: Calendar) -> String {
    // All decision inputs, including edits, equipment, daily restrictions and accepted targets.
    ReviewEngine.canonical(data.training) + ReviewEngine.canonical(data.trainingSafety) + ReviewEngine.canonical(data.coach) + ReviewEngine.canonical(data.workouts) + ReviewEngine.canonical(data.draft) + String(calendar.startOfDay(for: now).timeIntervalSince1970)
  }
  public static func proposal(_ data: AppData, profileID: UUID, now: Date = Date(), calendar: Calendar = .current) -> TrainingProposal {
    let snapshot = token(data, now: now, calendar: calendar)
    func pause(_ reason: String) -> TrainingProposal { .init(profileID: profileID, token: snapshot, action: "暂停", target: nil, reason: reason) }
    guard !TrainingSafety.isPaused(data) else { return pause(TrainingSafety.message) }
    guard !TrainingWorkload.hasDuplicateExercises(data.draft) else { return pause(TrainingWorkload.duplicatePlanMessage) }
    guard var profile = data.training?.profiles.first(where: { $0.id == profileID }), profile.valid else { return pause("先完成动作与器械档案。") }
    guard let coach = data.coach, coach.preferences.confirmedAt != nil, coach.preferences.restrictions == "没有已知限制",
      let check = coach.checkIn, check.date <= now, calendar.isDate(check.date, inSameDayAs: now),
      ["状态正常", "有点疲惫"].contains(check.energy), ["健身房", "在家"].contains(check.context),
      check.confirmedFields.map({ Set(["energy", "context", "minutes"]).isSubset(of: $0) }) ?? true else { return pause("先确认今天状态和训练条件；不适、休息或打球日不生成力量递进。") }
    guard TrainingLibrary.availableIDs(equipment: coach.preferences.equipment, context: check.context).contains(profile.exerciseID),
      !(check.excludedExercises ?? []).contains(profile.exerciseID) else { return pause("今天的场地或排除条件不适合这个动作。") }
    if let planned = data.draft?.planned, !planned.contains(where: { $0.exerciseID == profile.exerciseID }) { return pause("这个动作不在当前调整后的方案中。") }
    // The accepted program determines today's volume, not an old one-set profile default.
    if let item = data.draft?.planned?.first(where: { $0.exerciseID == profile.exerciseID }) {
      profile.workSets = item.sets
      profile.lowerReps = item.lowerReps ?? profile.lowerReps
      profile.upperReps = item.upperReps ?? profile.upperReps
    }
    let after = profile.recalibratedAfter ?? .distantPast
    let all = history(data, profileID: profileID, now: now).filter { $0.date >= after }
    let current = (data.draft?.sets ?? []).filter { $0.profileID == profileID && $0.date >= after && $0.date <= now }
    if (all + current).contains(where: { $0.form == "疼痛" }) { return pause("这个动作有疼痛反馈，暂停递进。确认已无不适且可以恢复后，在能力档案里重新校准；持续不适请寻求专业帮助。") }
    func suggest(_ action: String, _ kg: Double?, _ reps: Int, _ reason: String, _ evidence: [SetEntry]) -> TrainingProposal {
      .init(profileID: profileID, token: snapshot, action: action,
        target: TrainingTarget(profileID: profileID, kg: kg, reps: reps, sets: check.energy == "有点疲惫" || check.minutes <= 20 || check.lighter == true || check.sportFatigue == true ? 1 : profile.workSets, reason: reason, evidence: evidence.map(\.id)), reason: reason)
    }
    if let last = current.last, last.form != "标准完成" || last.rir == 0 {
      return suggest("重新校准", nil, profile.lowerReps, "本次已有动作变形、未确认动作质量或接近力竭的记录。先降低难度重新校准，不继续自动加量。", [last])
    }
    // Compare completed sessions on distinct days, never duplicated sessions or warmups.
    var seenDays = Set<Date>()
    let sessions = data.workouts.filter { $0.date <= now }.sorted { $0.date > $1.date }.compactMap { workout -> [SetEntry]? in
      let sets = workout.sets.filter { $0.profileID == profileID && $0.profileRevision == profile.revision && $0.setKind == "工作组" && $0.date >= after && $0.date <= now }
      guard !sets.isEmpty, seenDays.insert(calendar.startOfDay(for: workout.date)).inserted else { return nil }
      return sets.sorted { $0.date < $1.date }
    }
    guard let previous = sessions.first, let last = previous.last else {
      return suggest("首次校准", nil, profile.lowerReps, "没有这个动作、器械和重量口径下可比较的已完成训练。先选能保持动作稳定的轻量，记录实际表现；不要求极限测试。", [])
    }
    let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: last.date), to: calendar.startOfDay(for: now)).day ?? 999
    guard age <= 14, profile.availableLoads.contains(last.kg) else {
      return suggest("重新校准", nil, profile.lowerReps, "距可比较记录已较久，或可用重量档位发生变化，先重新确认当前能力。", previous)
    }
    if check.energy == "有点疲惫" || check.lighter == true || check.sportFatigue == true {
      let lighter = profile.availableLoads.sorted().last { $0 < last.kg }
      return suggest("轻松版本", lighter ?? last.kg, min(last.reps, profile.lowerReps), "你今天选择了轻松版本，先用较轻可用档位或保持原档位，不增加重量与次数；按实际体感决定是否继续。", previous)
    }
    guard previous.allSatisfy({ $0.form == "标准完成" && $0.reps >= profile.lowerReps }), last.rir != 0 else {
      return suggest("重新校准", nil, profile.lowerReps, "上次存在动作质量不确定、未达到次数下限或余力为零的记录，先重新校准。", previous)
    }
    let evidence = Array(sessions.prefix(2)).flatMap { $0 }
    let trainedToday = calendar.isDate(last.date, inSameDayAs: now)
    let readyToIncrease = sessions.count >= 2 && sessions.prefix(2).allSatisfy { sets in
      sets.count >= profile.workSets && sets.allSatisfy { $0.kg == last.kg && $0.reps >= profile.upperReps && $0.form == "标准完成" && ($0.rir ?? -1) >= 2 }
    }
    if current.isEmpty && !trainedToday && readyToIncrease, let next = profile.availableLoads.sorted().first(where: { $0 > last.kg }) {
      if last.kg > 0 && next <= last.kg * 1.05 + 0.00001 {
        return suggest("考虑小幅加重", next, profile.lowerReps, "两个不同训练日都以标准动作完成该档位的次数上限，并反馈至少还可做 2 次。建议尝试下一档（本地规则上限 5%），次数回到下限，组数不增加。", evidence)
      }
      return suggest("保持档位", last.kg, profile.upperReps, "已完成上限，但下一可用重量的跨幅超过本地规则上限，暂不自动跨档。可先保持或请教练协助选择更细的档位。", evidence)
    }
    if current.isEmpty && !trainedToday && previous.count >= profile.workSets && previous.allSatisfy({ ($0.rir ?? -1) >= 2 }) && last.reps < profile.upperReps {
      return suggest("先增加一次", last.kg, min(profile.upperReps, previous.map(\.reps).min()! + 1), "上次工作组动作稳定，且反馈仍有余力。先在同一重量下尝试多 1 次，组数不增加；完成后记录实际结果。", previous)
    }
    let accepted = data.draft?.targets?.first { $0.profileID == profileID }
    return suggest("保持并观察", current.isEmpty ? last.kg : (accepted?.kg ?? current.last?.kg ?? last.kg),
      current.isEmpty ? min(last.reps, profile.upperReps) : (accepted?.reps ?? min(last.reps, profile.upperReps)),
      "当前证据不足以继续加量，或本次训练已经开始。先保持可比较目标；未填余力不按轻松处理。", previous)
  }
  public static func accept(_ proposal: TrainingProposal, into data: inout AppData, now: Date = Date(), calendar: Calendar = .current) throws {
    let fresh = self.proposal(data, profileID: proposal.profileID, now: now, calendar: calendar)
    guard data.draft != nil, fresh.token == proposal.token, let target = fresh.target, let proposed = proposal.target,
      target.kg == proposed.kg, target.reps == proposed.reps, target.sets == proposed.sets, fresh.action == proposal.action else { throw CoachError.stale }
    var state = data.training ?? TrainingState()
    let old = data.draft?.targets?.first { $0.profileID == proposal.profileID }
    state.revision += 1
    state.events.append(TrainingEvent(kind: "确认建议", reason: target.reason, before: old, after: target, revision: state.revision))
    data.training = state
    let targets = (data.draft?.targets ?? []).filter { $0.profileID != proposal.profileID } + [target]
    data.draft?.targets = targets
    if let profile = state.profiles.first(where: { $0.id == proposal.profileID }), let i = data.draft?.planned?.firstIndex(where: { $0.exerciseID == profile.exerciseID }) {
      data.draft?.planned?[i].sets = target.sets
      data.draft?.planned?[i].reps = "\(target.reps) 次"
    }
  }
}
