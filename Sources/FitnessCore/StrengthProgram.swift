import Foundation

/// Transparent local programming choices; not a clinically validated prescription.
public enum StrengthProgram {
  public static let id = "return-gym-abc-v1"
  public static let phases = ["恢复适应", "稳定训练"]
  public static let names = ["A · 下肢与水平推拉", "B · 后侧与垂直推拉", "C · 全身巩固"]
  public static let warmup = "热身 8–10 分钟：单车或平地走 5 分钟，再活动肩、髋、踝；前两个器械各做 1–2 组轻重量热身。热身不计入工作组。"
  public static let effort = "恢复适应：每组保留约 3–4 次余力；稳定训练：约 2–3 次。全程可控、不憋气，不追求力竭；第一次用轻量校准。"
  public static let cardio = "力量后可选 10–15 分钟单车、椭圆机或平地走，以还能说完整句子为准。当天打球较累时省略；最后慢走放松 3–5 分钟。"
  public static let optionalDay = "第 4 次可选：轻松单车、椭圆机或平地走 20–30 分钟 + 肩髋踝活动 5–10 分钟。不是第四次高强度力量课；疲惫、腿酸或本周打球较累就休息。实际时长在其他活动中记录，不推进 A/B/C。"
  public static let weeklyExample = "示例（可调整）：周一 A · 周二乒乓球 · 周三 B · 周四乒乓球 · 周五 C · 周六可选恢复 · 周日休息。若打球强度大，增加休息，别为了凑次数补课。"
  public static func validDays(_ days: Set<Int>) -> Bool {
    days.count == 3 && days.allSatisfy { (1...7).contains($0) && !days.contains($0 == 7 ? 1 : $0 + 1) }
  }
  public static func session(_ slot: Int, phase: String = "恢复适应", minutes: Int = 60, light: Bool = false, excluded: Set<String> = []) -> [PlannedExercise] {
    let ids = [["leg", "press", "row", "curl", "calf", "deadbug"],
               ["bridge", "pulldown", "shoulder", "leg", "row", "deadbug"],
               ["leg", "press", "pulldown", "curl", "lateral", "deadbug"]][max(0, slot) % 3]
    // Filter first so a short plan can still choose enough permitted movements.
    let available = ids.filter { !excluded.contains($0) }
    let chosen = Array(available.prefix(minutes <= 20 ? 3 : minutes < 60 ? 4 : 6))
    return chosen.map { exercise in
      let accessory = ["calf", "lateral", "deadbug", "bridge", "curl"].contains(exercise)
      let range = exercise == "deadbug" ? (6, 10) : accessory ? (10, 15) : (8, 12)
      var item = PlannedExercise(exercise, sets: light || minutes <= 20 ? 1 : phase == "稳定训练" && !accessory ? 3 : 2,
        reps: "\(range.0)–\(range.1) 次" + (exercise == "deadbug" ? " / 每侧" : ""))
      item.lowerReps = range.0; item.upperReps = range.1
      item.restSeconds = accessory ? 90 : 120
      return item
    }
  }
  public static func duration(minutes: Int, light: Bool) -> String {
    minutes <= 20 ? "约 20 分钟 · 保底版" : minutes < 60 ? "约 35–45 分钟 · 缩短版" : light ? "约 40–55 分钟 · 轻松版" : "约 55–75 分钟"
  }
}
