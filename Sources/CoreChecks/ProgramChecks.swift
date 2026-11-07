import FitnessCore
import Foundation

func runProgramChecks() throws {
  var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  let now = ISO8601DateFormatter().date(from: "2026-11-02T10:00:00Z")!
  var data = AppData(), coach = CoachState()
  coach.preferences.confirmedAt = now; coach.preferences.experience = "练过，正在恢复"; coach.preferences.equipment = "器械与哑铃"; coach.preferences.restrictions = "没有已知限制"
  coach.preferences.programID = StrengthProgram.id; coach.preferences.trainingPhase = "恢复适应"; coach.preferences.workoutMinutes = 60
  var today = DailyCheckIn(); today.date = now; today.energy = "状态正常"; today.minutes = 60; coach.checkIn = today; data.coach = coach
  let a = DailyPlanner.plan(data, now: now, calendar: calendar)
  check(a.exercises.count == 6 && a.exercises.allSatisfy { $0.sets == 2 }, "Full recovery program has six movements and two working sets")
  var state = TrainingState(); state.sequenceIndex = 1; data.training = state
  let b = DailyPlanner.plan(data, now: now, calendar: calendar)
  state.sequenceIndex = 2; data.training = state
  let c = DailyPlanner.plan(data, now: now, calendar: calendar)
  check(Set(a.exercises.map(\.exerciseID)) != Set(b.exercises.map(\.exerciseID)) && Set(b.exercises.map(\.exerciseID)) != Set(c.exercises.map(\.exerciseID)), "ABC sessions differ in exercise selection, not only order")
  check((a.exercises + b.exercises + c.exercises).allSatisfy { TrainingLibrary.guide($0.exerciseID) != nil && $0.restSeconds != nil && $0.lowerReps != nil }, "Every full-program movement has a guide, rep range and rest prescription")
  check(StrengthProgram.validDays([2,4,6]) && !StrengthProgram.validDays([1,2,4]) && !StrengthProgram.validDays([1,4,7]), "Three strength days require gaps including across week boundaries")
  data.coach?.preferences.trainingPhase = "稳定训练"
  let stable = DailyPlanner.plan(data, now: now, calendar: calendar)
  check(stable.exercises.first?.sets == 3 && stable.exercises.last?.sets == 2, "Explicit stable phase increases main lifts while retaining accessory volume")
  data.coach?.checkIn?.minutes = 90
  check(DailyPlanner.plan(data, now: now, calendar: calendar).exercises.map(\.sets) == stable.exercises.map(\.sets), "Ninety available minutes do not add unnecessary sets")
  data.coach?.checkIn?.minutes = 20
  let short = DailyPlanner.plan(data, now: now, calendar: calendar)
  check(short.exercises.count == 3 && short.exercises.allSatisfy { $0.sets == 1 }, "Twenty-minute version limits both movements and sets")
  data.coach?.checkIn?.minutes = 45
  check(DailyPlanner.plan(data, now: now, calendar: calendar).exercises.count == 4, "Forty-five-minute version limits movement count")
  data.coach?.checkIn?.minutes = 60; data.coach?.checkIn?.sportFatigue = true
  check(DailyPlanner.plan(data, now: now, calendar: calendar).exercises.allSatisfy { $0.sets == 1 }, "Reported table-tennis fatigue reduces volume")
  data.coach?.checkIn?.sportFatigue = false; data.coach?.checkIn?.excludedExercises = Set(TrainingLibrary.guides.map(\.id))
  check(DailyPlanner.plan(data, now: now, calendar: calendar).status == "rest", "Excluding all full-program exercises returns rest")
  data.coach?.checkIn?.excludedExercises = []; data.coach?.checkIn?.context = "在家"
  check(DailyPlanner.plan(data, now: now, calendar: calendar).exercises.allSatisfy { ["sit","wall","calf"].contains($0.exerciseID) }, "Home adjustment uses available fallback instead of gym machines")
  data.coach?.checkIn?.context = "健身房"; data.coach?.checkIn?.energy = "不适或困倦"
  check(DailyPlanner.plan(data, now: now, calendar: calendar).status == "pause", "Symptoms gate the full program")
  data.coach?.checkIn?.energy = "状态正常"; data.coach?.checkIn?.date = now.addingTimeInterval(60)
  check(DailyPlanner.plan(data, now: now, calendar: calendar).status == "checkin", "Future check-in does not authorize today's workout")
  data.coach?.checkIn?.date = now
  data.workouts = [WorkoutEntry(date: now.addingTimeInterval(-86400), name: "力量", sets: [SetEntry(exercise: "test", kg: 1, reps: 8)], effort: "适中", minutes: 40)]
  check(DailyPlanner.plan(data, now: now, calendar: calendar).status == "rest", "Previous-day strength still reserves recovery in full program")
  data.workouts = []
  var draft = WorkoutDraft(); draft.programID = StrengthProgram.id; draft.planned = stable.exercises; data.draft = draft
  var profile = ExerciseProfile(exerciseID: "press"); profile.equipmentLabel = "合成测试机"; profile.availableLoads = [20,21]; profile.workSets = 1
  data.training?.profiles = [profile]
  var proposal = TrainingProgression.proposal(data, profileID: profile.id, now: now, calendar: calendar)
  check(proposal.target?.sets == 3 && proposal.target?.kg == nil, "Full plan volume overrides a legacy one-set profile without inventing load")
  try TrainingProgression.accept(proposal, into: &data, now: now, calendar: calendar)
  check(data.draft?.planned?.first(where: { $0.exerciseID == "press" })?.sets == 3 && data.draft?.sets.isEmpty == true, "Adopting a target preserves full planned volume and leaves actual sets empty")
  data.workouts = [2.0,4.0].map { days in
    let date = now.addingTimeInterval(-days * 86400)
    let sets = (0..<2).map { _ -> SetEntry in
      var s = SetEntry(exercise: profile.name, kg: 20, reps: 12); s.date = date; s.profileID = profile.id; s.profileRevision = 1; s.exerciseID = "press"; s.setKind = "工作组"; s.form = "标准完成"; s.rir = 3; return s
    }
    return WorkoutEntry(date: date, name: "合成训练", sets: sets, effort: "适中", minutes: 40)
  }
  proposal = TrainingProgression.proposal(data, profileID: profile.id, now: now, calendar: calendar)
  check(proposal.target?.kg == 20 && proposal.target?.sets == 3, "Increasing volume from two to three sets cannot simultaneously trigger load progression")
  data.coach?.checkIn?.sportFatigue = true
  check(TrainingProgression.proposal(data, profileID: profile.id, now: now, calendar: calendar).target?.sets == 1, "Fatigue reaches target generation as well as plan preview")
  let backup = try BackupCodec.decode(BackupCodec.encode(FitnessBackup(records: data, photos: [:])))
  check(backup.records.draft?.programID == StrengthProgram.id && backup.records.draft?.planned?.first?.restSeconds == 120, "Full backup retains program identity and rest prescriptions")
  var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CoachPreferences())) as! [String: Any]
  legacy.removeValue(forKey: "programID"); legacy.removeValue(forKey: "trainingPhase")
  let decoded = try JSONDecoder().decode(CoachPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
  check(decoded.programID == nil, "Legacy preferences do not silently adopt the new plan")
  let oldItem = try JSONDecoder().decode(PlannedExercise.self, from: JSONEncoder().encode(PlannedExercise("press")))
  check(oldItem.restSeconds == nil && oldItem.lowerReps == nil, "Legacy plan items retain compatibility without added fields")
}
