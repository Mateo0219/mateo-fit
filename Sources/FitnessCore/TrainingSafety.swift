import Foundation

/// A temporary training gate, independent of chat retention and daily field patches.
public struct TrainingSafetyState: Codable, Equatable {
  public var pausedAt: Date
  public var sourceTurnID: UUID?
  public var resumedAt: Date?
  public init(pausedAt: Date, sourceTurnID: UUID? = nil) {
    self.pausedAt = pausedAt; self.sourceTurnID = sourceTurnID
  }
  public var isPaused: Bool { resumedAt.map { $0 < pausedAt } ?? true }
  public var valid: Bool { pausedAt.timeIntervalSince1970.isFinite && (resumedAt.map { $0.timeIntervalSince1970.isFinite && $0 >= pausedAt } ?? true) }
}

public enum TrainingSafety {
  public static let message = "训练建议已暂停。修改时间、地点或清空聊天不会解除；请在当天状态中明确核对当前无不适且适合恢复。仍可保存已经发生的运动。"

  private static func legacyPause(_ data: AppData) -> CoachTurn? {
    (data.conversation ?? []).filter { $0.exchange?.response.status == "safety_pause" }
      .filter { $0.date > (data.trainingSafety?.resumedAt ?? .distantPast) }
      .max { $0.date < $1.date }
  }
  public static func isPaused(_ data: AppData) -> Bool {
    data.trainingSafety?.isPaused == true || legacyPause(data) != nil
  }
  /// Old check-in timestamps never prove recovery: migrate before chat deletion or truncation.
  @discardableResult public static func migrateLegacy(_ data: inout AppData) -> Bool {
    guard let turn = legacyPause(data), data.trainingSafety == nil || turn.date > data.trainingSafety!.pausedAt else { return false }
    data.trainingSafety = TrainingSafetyState(pausedAt: turn.date, sourceTurnID: turn.id)
    data.draft?.targets = []
    return true
  }
  public static func pause(_ data: inout AppData, at date: Date = Date(), sourceTurnID: UUID? = nil) {
    if let sourceTurnID, data.trainingSafety?.sourceTurnID == sourceTurnID { return }
    data.trainingSafety = TrainingSafetyState(pausedAt: date, sourceTurnID: sourceTurnID)
    data.draft?.targets = []
  }
  public static func observe(_ turn: CoachTurn, in data: inout AppData, now: Date = Date()) {
    guard turn.exchange?.response.status == "safety_pause" else { return }
    pause(&data, at: max(now, turn.date), sourceTurnID: turn.id)
  }
  /// Restoring an older backup is not a current recovery confirmation.
  public static func preservePause(from current: AppData, in restored: inout AppData) {
    var previous = current
    migrateLegacy(&previous); migrateLegacy(&restored)
    guard isPaused(previous), let pause = previous.trainingSafety else { return }
    if !isPaused(restored) || (restored.trainingSafety?.pausedAt ?? .distantPast) < pause.pausedAt {
      restored.trainingSafety = pause
    }
    restored.draft?.targets = []
  }
  /// Called only by the App's explicit recovery confirmation, never by model operations.
  public static func confirmRecovery(_ check: DailyCheckIn, in data: inout AppData, now: Date = Date()) throws {
    let fields = check.confirmedFields ?? Set(["energy", "context", "minutes"])
    guard check.date <= now, Calendar.current.isDate(check.date, inSameDayAs: now),
      check.energy == "状态正常", ["健身房", "在家", "休息", "乒乓球"].contains(check.context),
      (1...120).contains(check.minutes), Set(["energy", "context", "minutes"]).isSubset(of: fields),
      data.coach?.preferences.restrictions == "没有已知限制" else {
      throw AgentOperationError.rejected("请明确核对当前无不适、适合恢复训练，并补齐今天状态、地点、时间及运动限制。")
    }
    migrateLegacy(&data)
    if data.trainingSafety != nil { data.trainingSafety?.resumedAt = now }
    AssistantTransactions.applyDailyCheck(check, to: &data, now: now)
  }
}
