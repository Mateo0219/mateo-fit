import FitnessCore
import Foundation

extension AppStore {
  func saveExerciseProfile(_ profile: ExerciseProfile) -> Bool {
    guard profile.valid else { alert = "请确认器械名称、重量口径、可用重量档位和次数范围。"; return false }
    if let old = data.training?.profiles.first(where: { $0.id == profile.id }),
      old.exerciseID != profile.exerciseID || old.equipmentLabel != profile.equipmentLabel || old.loadConvention != profile.loadConvention || old.side != profile.side {
      alert = "不同器械或重量口径需要建立新档案，避免混用能力记录。"; return false
    }
    return change { data in
      var state = data.training ?? TrainingState(), next = profile
      if let i = state.profiles.firstIndex(where: { $0.id == profile.id }) { next.revision = state.profiles[i].revision + 1; state.profiles[i] = next }
      else { state.profiles.append(next) }
      state.revision += 1
      state.events.append(TrainingEvent(kind: "动作档案", reason: "确认\(next.name) · \(next.equipmentLabel) · \(next.loadConvention)，版本 \(next.revision)", revision: state.revision))
      data.training = state
      data.draft?.targets?.removeAll { $0.profileID == profile.id }
    }
  }
  func acceptTraining(_ proposal: TrainingProposal) -> Bool {
    var candidate = data
    do { try TrainingProgression.accept(proposal, into: &candidate) }
    catch { alert = "状态、记录或目标已经变化，请重新查看建议。"; return false }
    return change { $0.training = candidate.training; $0.draft = candidate.draft }
  }
  func logTrackedSet(profileID: UUID, kg: Double, reps: Int, rir: Int?, form: String, kind: String) -> Bool {
    guard let profile = data.training?.profiles.first(where: { $0.id == profileID }), profile.valid,
      let target = data.draft?.targets?.first(where: { $0.profileID == profileID }),
      profile.availableLoads.contains(kg), kg.isFinite, (1...100).contains(reps), rir.map({ (0...10).contains($0) }) ?? true,
      ["标准完成", "动作变形", "疼痛", "不确定"].contains(form), ["工作组", "热身组"].contains(kind) else {
      alert = "请先确认动作建议，再检查实际重量、次数与反馈；重量需在这台器械的档位中。"; return false
    }
    guard TrainingProgression.proposal(data, profileID: profileID).target != nil else { alert = "当前建议已暂停，请先处理今天状态或该动作的不适反馈。"; return false }
    return change { data in
      var set = SetEntry(exercise: profile.name, kg: kg, reps: reps)
      set.profileID = profile.id; set.profileRevision = profile.revision; set.exerciseID = profile.exerciseID
      set.rir = rir; set.form = form; set.setKind = kind; set.targetID = target.id
      data.draft?.sets.append(set)
      let rest = data.draft?.planned?.first { $0.exerciseID == profile.exerciseID }?.restSeconds ?? 90
      data.draft?.restUntil = Date().addingTimeInterval(Double(rest))
    }
  }
  func applyDailyCheck(_ check: DailyCheckIn) -> Bool {
    return change { AssistantTransactions.applyDailyCheck(check, to: &$0) }
  }
  func confirmTrainingRecovery(_ check: DailyCheckIn) -> Bool {
    var next = data
    do { try TrainingSafety.confirmRecovery(check, in: &next) }
    catch { alert = error.localizedDescription; return false }
    return change { $0 = next }
  }

  func substituteExercise(itemID: UUID, exerciseID: String) {
    guard DailyPlanner.plan(data).status == "ready" else { alert = TrainingSafety.isPaused(data) ? TrainingSafety.message : "请先确认今天状态和训练条件。"; return }
    guard let draft = data.draft, let item = draft.planned?.first(where: { $0.id == itemID }),
      let check = data.coach?.checkIn,
      TrainingWorkload.alternatives(for: item, draft: draft, state: data.training, equipment: data.coach?.preferences.equipment ?? "未确认", context: check.context, excluded: check.excludedExercises ?? []).contains(where: { $0.id == exerciseID }) else { alert = "当前条件下没有这个替代动作，或它与现有计划重复，请先核对计划。"; return }
    let replacement: PlannedExercise
    do { replacement = try TrainingWorkload.replacement(item, with: exerciseID, draft: draft, state: data.training) }
    catch { alert = error.localizedDescription; return }
    let progress = TrainingWorkload.progress(item, draft: draft, state: data.training)
    _ = change { data in
      guard let i = data.draft?.planned?.firstIndex(where: { $0.id == itemID }) else { return }
      data.draft?.planned?[i] = replacement
      data.draft?.targets = []
      var state = data.training ?? TrainingState(); state.revision += 1
      let reason = "\(TrainingLibrary.guide(item.exerciseID)?.name ?? item.exerciseID) → \(TrainingLibrary.guide(exerciseID)?.name ?? exerciseID)，\(progress.summary)；仅替代剩余工作组，实际记录保留，替代动作独立校准。"
      state.events.append(TrainingEvent(kind: "替代动作", reason: reason, revision: state.revision)); data.training = state
      data.draft?.adaptationNote = reason
    }
  }
  func clearTarget(_ profileID: UUID) {
    _ = change { data in
      let old = data.draft?.targets?.first { $0.profileID == profileID }
      data.draft?.targets?.removeAll { $0.profileID == profileID }
      var state = data.training ?? TrainingState(); state.revision += 1
      state.events.append(TrainingEvent(kind: "撤回目标", reason: "撤回当前目标；已完成记录保留，需要重新确认建议。", before: old, revision: state.revision))
      data.training = state
    }
  }
  func recalibrate(_ profileID: UUID) {
    _ = change { data in
      guard let i = data.training?.profiles.firstIndex(where: { $0.id == profileID }) else { return }
      data.training?.profiles[i].recalibratedAfter = Date()
      data.training?.profiles[i].revision += 1
      data.training?.revision += 1
      let revision = data.training?.revision ?? 0
      data.training?.events.append(TrainingEvent(kind: "重新校准", reason: "用户确认目前无该动作不适且适合恢复；历史记录保留，下一次从新基线开始。", revision: revision))
      data.draft?.targets?.removeAll { $0.profileID == profileID }
    }
  }
}
