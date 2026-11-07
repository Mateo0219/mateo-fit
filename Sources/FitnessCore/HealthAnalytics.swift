import Foundation

public enum SleepStage: String, Codable, CaseIterable {
  case awake, rem, core, deep, unspecified, inBed, conflict
  public var isAsleep: Bool { [.rem, .core, .deep, .unspecified].contains(self) }
  public var label: String {
    switch self {
    case .awake: return "清醒"
    case .rem: return "REM"
    case .core: return "核心"
    case .deep: return "深度"
    case .unspecified: return "未分期"
    case .inBed: return "卧床"
    case .conflict: return "冲突区间"
    }
  }
}
public struct SleepSegment: Identifiable {
  public var id: Date { start }
  public let start: Date
  public var end: Date
  public let stage: SleepStage
  public var seconds: Double { end.timeIntervalSince(start) }
}
public struct SleepReport: Identifiable {
  public var id: Date { day }
  public let day: Date
  public let source: String
  public let sourceCount: Int
  public let segments: [SleepSegment]
  public var sleepSeconds: Double { segments.filter { $0.stage.isAsleep }.reduce(0) { $0 + $1.seconds } }
  public var start: Date? { segments.first(where: { $0.stage.isAsleep })?.start }
  public var end: Date? { segments.last(where: { $0.stage.isAsleep })?.end }
  public func seconds(_ stage: SleepStage) -> Double {
    segments.filter { $0.stage == stage }.reduce(0) { $0 + $1.seconds }
  }
  public var awakenings: Int {
    guard let start, let end else { return 0 }
    return segments.filter { $0.stage == .awake && $0.start >= start && $0.end <= end }.count
  }
}
public struct WeightReport {
  public let daily: [WeightEntry]
  public let latest: WeightEntry?
  public let currentMean: Double?
  public let previousMean: Double?
  public let currentDays: Int
  public let previousDays: Int
  public var weekChange: Double? {
    guard let currentMean, let previousMean else { return nil }
    return currentMean - previousMean
  }
  public var rangeChange: Double? {
    guard daily.count >= 2, let first = daily.first, let last = daily.last else { return nil }
    return last.kg - first.kg
  }
}
public enum HealthAnalytics {
  public static func weight(_ entries: [WeightEntry], days: Int, now: Date = Date(), calendar: Calendar = .current) -> WeightReport {
    let valid = entries.filter { DataMath.validWeight($0.kg) && $0.date <= now }
    let today = calendar.startOfDay(for: now)
    let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today)!
    let currentStart = calendar.date(byAdding: .day, value: -6, to: today)!
    let previousStart = calendar.date(byAdding: .day, value: -13, to: today)!
    let daily = DataMath.dailyWeights(valid, calendar: calendar)
    let current = daily.filter { $0.date >= currentStart }
    let previous = daily.filter { $0.date >= previousStart && $0.date < currentStart }
    func mean(_ values: [WeightEntry]) -> Double? {
      values.count >= 3 ? values.reduce(0) { $0 + $1.kg } / Double(values.count) : nil
    }
    return WeightReport(daily: daily.filter { $0.date >= start }, latest: daily.last,
      currentMean: mean(current), previousMean: mean(previous), currentDays: current.count,
      previousDays: previous.count)
  }
  // A sleep day ends at local noon. Calendar arithmetic preserves DST boundaries.
  public static func sleepDay(for end: Date, calendar: Calendar = .current) -> Date {
    let date = calendar.startOfDay(for: end)
    let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date)!
    return end <= noon ? date : calendar.date(byAdding: .day, value: 1, to: date)!
  }
  public static func sleep(_ entries: [SleepEntry], days: Int, now: Date = Date(), calendar: Calendar = .current) -> [SleepReport] {
    let today = calendar.startOfDay(for: now)
    let latestEnd = entries.filter { $0.resolvedStage.isAsleep && $0.start < now && $0.end > $0.start }.map { min($0.end, now) }.max()
    let lastDay = max(today, latestEnd.map { sleepDay(for: $0, calendar: calendar) } ?? today)
    // Show a partial next sleep day only after it actually has sleep samples.
    let firstDay = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: lastDay)!
    let candidates = entries.filter { $0.end > $0.start && $0.start < now }
    var reports: [SleepReport] = []
    var day = firstDay
    while day <= lastDay {
      let end = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
      let start = calendar.date(byAdding: .day, value: -1, to: end)!
      let clipped = candidates.filter { $0.end > start && $0.start < min(end, now) }
      let groups = Dictionary(grouping: clipped, by: { $0.sourceID ?? $0.source })
      // Prefer a Watch source with actual sleep, then the greatest detailed-stage coverage.
      let ranked = groups.map { key, values -> (String, [SleepEntry], [SleepSegment], Bool, Double, Double) in
        let segments = normalized(values, from: start, to: min(end, now))
        let total = segments.filter { $0.stage.isAsleep }.reduce(0) { $0 + $1.seconds }
        let detailed = segments.filter { [.rem, .core, .deep].contains($0.stage) }.reduce(0) { $0 + $1.seconds }
        return (key, values, segments, values.contains { $0.isWatch == true }, detailed, total)
      }.filter { $0.5 > 0 }.sorted {
        if $0.3 != $1.3 { return $0.3 }
        if $0.4 != $1.4 { return $0.4 > $1.4 }
        if $0.5 != $1.5 { return $0.5 > $1.5 }
        return $0.0 < $1.0
      }
      if let best = ranked.first {
        reports.append(SleepReport(day: day, source: best.1.first!.source,
          sourceCount: ranked.count, segments: best.2))
      }
      day = calendar.date(byAdding: .day, value: 1, to: day)!
    }
    return reports
  }
  public static func normalized(_ values: [SleepEntry], from: Date, to: Date) -> [SleepSegment] {
    let values = values.filter { $0.end > from && $0.start < to && $0.end > $0.start && $0.resolvedStage != .inBed }
    let points = Set(values.flatMap { [max(from, $0.start), min(to, $0.end)] }).sorted()
    guard points.count > 1 else { return [] }
    var result: [SleepSegment] = []
    for i in 0..<(points.count - 1) {
      let start = points[i], end = points[i + 1]
      let active = Set(values.filter { $0.start < end && $0.end > start }.map(\.resolvedStage))
      guard !active.isEmpty else { continue }
      let detail = active.subtracting([.unspecified])
      let stage: SleepStage
      if detail.count == 1 { stage = detail.first! }
      else if detail.isEmpty { stage = .unspecified }
      else if detail.allSatisfy(\.isAsleep) { stage = .unspecified }
      else { stage = .conflict }
      if let last = result.last, last.stage == stage, last.end == start {
        result[result.count - 1].end = end
      } else { result.append(SleepSegment(start: start, end: end, stage: stage)) }
    }
    return result
  }
}
