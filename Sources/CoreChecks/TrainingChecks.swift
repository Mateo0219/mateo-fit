import FitnessCore
import Foundation

func runTrainingChecks() throws {
  var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  let now = ISO8601DateFormatter().date(from: "2026-11-02T10:00:00Z")!
  var p = ExerciseProfile(exerciseID: "press"); p.equipmentLabel = "测试器械"; p.availableLoads = [10,20,21]
  var data = AppData(); var coach = CoachState()
  coach.preferences.confirmedAt = now; coach.preferences.experience = "练过，正在恢复"; coach.preferences.equipment = "器械与哑铃"; coach.preferences.restrictions = "没有已知限制"
  var checkIn = DailyCheckIn(); checkIn.date = now; checkIn.energy = "状态正常"; coach.checkIn = checkIn; data.coach = coach
  var state = TrainingState(); state.profiles = [p]; data.training = state
  func proposal(_ d: AppData) -> TrainingProposal { TrainingProgression.proposal(d, profileID: p.id, now: now, calendar: calendar) }
  func workout(_ days: Double, reps: Int = 12, rir: Int? = 2, form: String = "标准完成", profile: ExerciseProfile? = nil) -> WorkoutEntry {
    let profile = profile ?? p, date = now.addingTimeInterval(-days * 86400)
    var set = SetEntry(exercise: profile.name, kg: 20, reps: reps); set.date = date
    set.profileID = profile.id; set.profileRevision = profile.revision; set.exerciseID = profile.exerciseID
    set.rir = rir; set.form = form; set.setKind = "工作组"
    return WorkoutEntry(date: date, name: "合成测试", sets: [set], effort: "适中", minutes: 30)
  }
  check(proposal(data).action == "首次校准" && proposal(data).target?.kg == nil, "No history never invents starting load")
  data.workouts = [workout(2, reps: 10)]
  check(proposal(data).target?.reps == 11 && proposal(data).target?.kg == 20, "Clean sub-ceiling performance progresses one repetition without load change")
  data.workouts = [workout(2, reps: 10, rir: nil)]
  check(proposal(data).target?.reps == 10 && proposal(data).action == "保持并观察", "Unknown RIR is not inferred as spare capacity")
  data.workouts = [workout(2),workout(4)]
  check(proposal(data).target?.kg == 21 && proposal(data).target?.reps == 8, "Two qualifying training days permit bounded next available load")
  check(proposal(data).target?.evidence.count == 2, "Progression references exact supporting sets")
  var todayAgain = data; todayAgain.workouts = [workout(0),workout(2)]
  check(proposal(todayAgain).target?.kg == 20, "Additional same-day session cannot trigger another load increase")
  var varied = data; varied.training?.profiles[0].availableLoads = [20,25]
  check(proposal(varied).action == "保持档位" && proposal(varied).target?.kg == 20, "Large equipment increment is not forced")
  varied = data; varied.workouts = [workout(2),workout(2.01)]
  check(proposal(varied).target?.kg == 20, "Duplicate sessions on one day cannot satisfy two-day progression")
  varied = data; varied.workouts[0].sets[0].setKind = "热身组"
  check(proposal(varied).target?.kg == 20, "Warmups do not qualify for load progression")
  varied = data; varied.workouts[0].sets[0].form = "动作变形"
  check(proposal(varied).target?.kg == nil && proposal(varied).action == "重新校准", "Form breakdown blocks progression")
  varied = data; varied.workouts[1].sets[0].form = "疼痛"
  check(proposal(varied).target == nil, "Pain persists as a block even after later clean sets")
  varied.training?.profiles[0].recalibratedAfter = now
  check(proposal(varied).action == "首次校准", "Explicit recovery reset retains history but starts a fresh baseline")
  varied = data; varied.coach?.checkIn?.energy = "不适或困倦"
  check(proposal(varied).target == nil, "Current symptoms override historical ability")
  varied = data; varied.coach?.checkIn?.lighter = true
  check(proposal(varied).target?.kg == 10 && proposal(varied).action == "轻松版本", "Lighter day uses available lower load and cannot increase")
  varied = data; varied.coach?.checkIn?.context = "在家"
  check(proposal(varied).target == nil, "Home context excludes gym machine profile")
  varied = data; varied.coach?.checkIn?.excludedExercises = ["press"]
  check(proposal(varied).target == nil, "Daily exclusion prevents a profile suggestion")
  varied = data; varied.coach?.checkIn?.date = now.addingTimeInterval(-86400)
  check(proposal(varied).target == nil, "Daily readiness expires")
  varied = data; varied.workouts = [workout(20), workout(22)]
  check(proposal(varied).action == "重新校准", "Long break prompts recalibration instead of carrying old load forward")
  varied = data; varied.training?.profiles[0].revision += 1
  check(proposal(varied).action == "首次校准", "Changed profile revision cannot reuse old target assumptions")
  var another = p; another.id = UUID(); another.equipmentLabel = "另一台机器"
  varied = data; varied.workouts = [workout(2, profile: another),workout(4, profile: another)]
  check(proposal(varied).action == "首次校准", "Same exercise on another machine never shares ability automatically")
  data.draft = WorkoutDraft(); data.draft?.planned = [PlannedExercise("press")]
  let before = proposal(data)
  try TrainingProgression.accept(before, into: &data, now: now, calendar: calendar)
  check(data.draft?.targets?.first?.kg == 21 && data.draft?.sets.isEmpty == true, "Accepted target never writes completed sets")
  do { try TrainingProgression.accept(before, into: &data, now: now, calendar: calendar); fatalError("duplicate accepted") } catch { check(true, "Repeated proposal confirmation rejected") }
  let fresh = proposal(data); data.workouts[0].sets[0].reps = 6
  do { try TrainingProgression.accept(fresh, into: &data, now: now, calendar: calendar); fatalError("stale accepted") } catch { check(true, "Editing performance invalidates proposal snapshot") }
  let old = SetEntry(exercise: "坐姿器械推胸", kg: 20, reps: 12)
  var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
  for key in ["profileID","profileRevision","exerciseID","rir","form","setKind","targetID"] { encoded.removeValue(forKey: key) }
  let decoded = try JSONDecoder().decode(SetEntry.self, from: JSONSerialization.data(withJSONObject: encoded))
  check(decoded.profileID == nil && decoded.rir == nil, "Legacy set records load without guessed equipment or RIR")
  var restored = try BackupCodec.decode(BackupCodec.encode(FitnessBackup(records: data, photos: [:])))
  check(restored.records.training?.profiles[0].id == p.id && restored.records.draft?.targets?.count == 1, "Full backup preserves profiles and accepted targets")
  restored.records.training?.profiles[0].availableLoads = [-1]
  do { try BackupCodec.validate(restored); fatalError("invalid profile accepted") } catch { check(true, "Invalid imported ability profile rejected") }
  var single = ExerciseProfile(exerciseID: "dbrow"); single.equipmentLabel = "哑铃"; single.availableLoads = [5,6]
  check(!single.valid, "Unilateral row requires explicit side")
  single.side = "左侧"; check(single.valid, "Explicit unilateral side has its own valid profile")
  var daily = AppData(); daily.coach = coach; daily.training = state
  daily.coach?.checkIn?.excludedExercises = ["leg", "press", "row", "calf"]
  check(DailyPlanner.plan(daily, now: now, calendar: calendar).exercises.isEmpty, "Excluding all available exercises returns rest instead of unsafe fallback")
  daily.coach?.checkIn?.excludedExercises = []
  let a = DailyPlanner.plan(daily, now: now, calendar: calendar).exercises.map(\.exerciseID)
  daily.training?.sequenceIndex = 1
  let b = DailyPlanner.plan(daily, now: now, calendar: calendar).exercises.map(\.exerciseID)
  check(Set(a) == Set(b) && a != b, "Sequence rotates order while keeping comparable core movements")
  var unilateral = WorkoutDraft(); unilateral.planned = [PlannedExercise("dbrow")]
  var left = single; left.side = "左侧"
  var right = single; right.id = UUID(); right.side = "右侧"
  var sideState = TrainingState(); sideState.profiles = [left, right]
  var leftSet = SetEntry(exercise: "测试", kg: 5, reps: 8); leftSet.exerciseID = "dbrow"; leftSet.profileID = left.id; leftSet.setKind = "工作组"; leftSet.form = "标准完成"
  unilateral.sets = [leftSet]
  check(!TrainingProgression.planCompleted(unilateral, state: sideState), "Unilateral plan cannot finish after only one side")
  var rightSet = leftSet; rightSet.id = UUID(); rightSet.profileID = right.id; unilateral.sets.append(rightSet)
  check(TrainingProgression.planCompleted(unilateral, state: sideState), "Both sides count toward completing unilateral plan")

}
