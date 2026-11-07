import Foundation

public struct WorkSetProgress {
  public let planned: Int
  public let completed: Int
  public let left: Int?
  public let right: Int?
  public let requiresPlanReview: Bool
  public var remaining: Int { max(0, planned - completed) }
  public var hasUnevenSides: Bool { left != right }
  public var summary: String {
    if requiresPlanReview { return TrainingWorkload.duplicatePlanMessage }
    if let left, let right { return "工作组：左侧 \(left)/\(planned)，右侧 \(right)/\(planned)；剩余左侧 \(max(0, planned - left))、右侧 \(max(0, planned - right)) 组" }
    return "已完成 \(completed)/\(planned) 个工作组；剩余 \(remaining) 组"
  }
}

/// The selected equipment profile and the whole exercise plan have distinct scopes.
/// Both use the current plan's accounting boundary after a substitution.
public struct TargetWorkSetProgress {
  public let completed: Int
  public let target: Int
  public let priorCompleted: Int
  public let side: String
  public let plan: WorkSetProgress?
  public var summary: String {
    let label = side == "双侧 / 不适用" ? "本器械档案" : "本器械档案（\(side)）"
    if plan?.requiresPlanReview == true { return "\(label)的实际工作组仍保留；当前计划含重复动作，核对前不判断目标完成。" }
    return "\(label)当前已记 \(completed) / \(target) 个工作组。"
  }
  public var priorSummary: String? {
    guard priorCompleted > 0 else { return nil }
    return "本档案此前已抵扣 \(priorCompleted) 个工作组；实际记录仍保留在训练主页面，不再计入当前剩余目标。"
  }
}

public enum TrainingWorkload {
  public static let duplicatePlanMessage = "当前草稿含重复动作，无法确认各组归属。请核对计划；可先结束并保存实际记录，本次不自动推进训练顺序。"
  public static func hasDuplicateExercises(_ draft: WorkoutDraft?) -> Bool {
    let ids = draft?.planned?.map(\.exerciseID) ?? []
    return Set(ids).count != ids.count
  }
  public static func conflicts(_ exerciseID: String, replacing item: PlannedExercise, in draft: WorkoutDraft) -> Bool {
    (draft.planned ?? []).contains { $0.id != item.id && $0.exerciseID == exerciseID }
  }
  public static func alternatives(for item: PlannedExercise, draft: WorkoutDraft, state: TrainingState?, equipment: String, context: String, excluded: Set<String> = []) -> [ExerciseGuide] {
    guard !hasDuplicateExercises(draft) else { return [] }
    let progress = progress(item, draft: draft, state: state)
    guard progress.remaining > 0, !progress.hasUnevenSides else { return [] }
    return TrainingLibrary.alternatives(for: item.exerciseID, equipment: equipment, context: context).filter {
      !excluded.contains($0.id) && !conflicts($0.id, replacing: item, in: draft)
    }
  }
  public static func targetProgress(_ target: TrainingTarget, profile: ExerciseProfile, draft: WorkoutDraft?, state: TrainingState?) -> TargetWorkSetProgress {
    let item = draft?.planned?.first { $0.exerciseID == profile.exerciseID }
    let prior = item?.priorSetIDs ?? []
    let work = (draft?.sets ?? []).filter { $0.profileID == profile.id && $0.setKind == "工作组" }
    let accounted = work.filter { prior.contains($0.id) }.count
    let plan = item.flatMap { item in draft.map { progress(item, draft: $0, state: state) } }
    return .init(completed: work.count - accounted, target: target.sets, priorCompleted: accounted, side: profile.side, plan: plan)
  }
  public static func progress(_ item: PlannedExercise, draft: WorkoutDraft, state: TrainingState?, standardOnly: Bool = false) -> WorkSetProgress {
    guard !hasDuplicateExercises(draft) else {
      return .init(planned: item.sets, completed: 0, left: nil, right: nil, requiresPlanReview: true)
    }
    let prior = item.priorSetIDs ?? []
    let done = draft.sets.filter {
      !prior.contains($0.id) && $0.setKind == "工作组" && (!standardOnly || $0.form == "标准完成") &&
        ($0.exerciseID == item.exerciseID || ($0.exerciseID == nil && $0.exercise == TrainingLibrary.guide(item.exerciseID)?.name))
    }
    if item.exerciseID == "dbrow" {
      func count(_ side: String) -> Int {
        let profiles = Set((state?.profiles ?? []).filter { $0.exerciseID == item.exerciseID && $0.side == side }.map(\.id))
        return done.filter { $0.profileID.map(profiles.contains) == true }.count
      }
      let left = count("左侧"), right = count("右侧")
      return .init(planned: item.sets, completed: min(left, right), left: left, right: right, requiresPlanReview: false)
    }
    return .init(planned: item.sets, completed: done.count, left: nil, right: nil, requiresPlanReview: false)
  }
  public static func replacement(_ item: PlannedExercise, with exerciseID: String, draft: WorkoutDraft, state: TrainingState?) throws -> PlannedExercise {
    guard !hasDuplicateExercises(draft) else { throw AgentOperationError.rejected(duplicatePlanMessage) }
    guard !conflicts(exerciseID, replacing: item, in: draft) else {
      throw AgentOperationError.rejected("当前计划已包含这个替代动作，不能将同一批实际组数重复计入两项计划。请核对其他可用动作；原计划和实际记录保留。")
    }
    let progress = progress(item, draft: draft, state: state)
    guard progress.remaining > 0 else { throw AgentOperationError.rejected("这个动作的工作组已经完成，不再追加替代组。") }
    guard !progress.hasUnevenSides else { throw AgentOperationError.rejected("左右侧已完成组数不同（\(progress.summary)）。请先核对两侧记录；暂不自动换成双侧动作，避免重复已完成侧或漏掉另一侧。") }
    var next = PlannedExercise(exerciseID, sets: progress.remaining, reps: item.reps)
    next.restSeconds = item.restSeconds; next.lowerReps = item.lowerReps; next.upperReps = item.upperReps
    // Returning to an earlier exercise must not deduct its already-accounted-for sets again.
    next.priorSetIDs = Set(draft.sets.map(\.id))
    if draft.programID == StrengthProgram.id,
      let template = (0..<3).flatMap({ StrengthProgram.session($0) }).first(where: { $0.exerciseID == exerciseID }) {
      next.lowerReps = template.lowerReps; next.upperReps = template.upperReps; next.reps = template.reps
      next.restSeconds = template.restSeconds
    }
    return next
  }
}
