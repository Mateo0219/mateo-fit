import Charts
import FitnessCore
import SwiftUI

struct ProgressViewScreen: View {
  @EnvironmentObject var store: AppStore
  @State private var section: Int
  init(initialSection: Int = 0) { _section = State(initialValue: initialSection) }
  var body: some View {
    Surface(dark: true) {
      Pill(text: "身体数据 · 持续了解自己", dark: true)
      Text("看见身体的节奏。").font(.system(size: 28, weight: .bold))
      HStack(spacing: 8) {
        Image(systemName: store.healthBusy ? "arrow.triangle.2.circlepath" : "heart.fill")
        Text(store.healthBusy ? "正在更新健康记录…" : store.healthStatus)
      }.font(.subheadline)
      if let date = store.data.healthSyncedAt {
        Text("上次成功更新 \(date.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption).foregroundStyle(.white.opacity(0.8))
      }
    }
    Picker("身体数据", selection: $section) {
      Text("体重趋势").tag(0)
      Text("睡眠分析").tag(1)
    }.pickerStyle(.segmented)
    if section == 0 { WeightAnalysisView(); WeightForecastCard() } else { SleepAnalysisView() }
    WeeklyReviewCard()
    Surface {
      Label("与 Apple 健康保持同步", systemImage: "heart.text.square").font(.headline)
      Text("打开 App会自动更新；健康数据发生变化时，也会请求系统在后台更新。手表、米家需先把记录同步到 Apple 健康。锁屏或系统调度可能延迟更新。")
        .font(.caption).foregroundStyle(Color.secondaryInk)
      #if os(iOS)
      if store.data.healthSyncedAt == nil && store.data.healthAutoSyncEnabled != true {
        MainButton(title: "连接 Apple 健康", symbol: "heart") {
          Task { await HealthBridge.shared.sync(into: store) }
        }.disabled(store.healthBusy)
      } else {
        HStack {
          Button("重新请求读取权限") { Task { await HealthBridge.shared.sync(into: store) } }
          Spacer()
          Button("立即检查") { Task { await HealthBridge.shared.refresh(into: store) } }
        }.font(.caption).disabled(store.healthBusy)
      }
      #else
      Text("Mac 预览不读取手机健康数据。").font(.caption)
      #endif
      if store.data.weights.isEmpty || store.data.sleep.isEmpty {
        Text("暂无记录可能是来源尚未同步，或未允许对应类型的读取。").font(.caption).foregroundStyle(Color.secondaryInk)
      }
    }
  }
}

private struct WeightAnalysisView: View {
  @EnvironmentObject var store: AppStore
  @State private var days = 30
  @State private var weight = ""
  private var report: WeightReport { HealthAnalytics.weight(store.data.weights, days: days) }
  private var yDomain: ClosedRange<Double> {
    let values = report.daily.map(\.kg)
    return ((values.min() ?? 0) - 1)...((values.max() ?? 1) + 1)
  }
  var body: some View {
    Surface {
      Text("最近一次测量").font(.subheadline).foregroundStyle(Color.secondaryInk)
      if let latest = report.latest {
        HStack(alignment: .firstTextBaseline) {
          Text(latest.kg, format: .number.precision(.fractionLength(1))).font(.system(size: 46, weight: .bold, design: .rounded))
          Text("kg").font(.title3)
        }
        Text(latest.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
        Text(latest.source).font(.caption).foregroundStyle(Color.secondaryInk)
      } else {
        EmptyHint(symbol: "scalemass", title: "等待测量记录", detail: "个人档案里的起始体重不会作为今天的测量。")
      }
      Picker("体重时间范围", selection: $days) {
        Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90)
      }.pickerStyle(.segmented)
      if !report.daily.isEmpty {
        Chart(report.daily) { item in
          LineMark(x: .value("日期", item.date), y: .value("kg", item.kg)).foregroundStyle(Color.pine)
          PointMark(x: .value("日期", item.date), y: .value("kg", item.kg)).foregroundStyle(Color.pine)
        }.chartYScale(domain: yDomain).frame(height: 190)
          .accessibilityLabel("体重趋势，\(report.daily.count) 天有测量记录")
        HStack {
          Text("\(days) 天内记录了 \(report.daily.count) 天")
          Spacer()
          if let change = report.rangeChange { Text("首末 \(signed(change)) kg") }
        }.font(.caption).foregroundStyle(Color.secondaryInk)
      } else { Text("此时间段暂无测量记录。").font(.subheadline) }
      Text("每天取最后一次测量；连线仅连接测量点，缺失日期不补值。").font(.caption).foregroundStyle(Color.secondaryInk)
    }
    Surface {
      Text("比单次数字更有用的趋势").font(.headline)
      metric("近 7 天平均", value: report.currentMean.map { String(format: "%.1f kg", $0) } ?? "待积累", detail: "\(report.currentDays)/7 天有记录")
      metric("前 7 天平均", value: report.previousMean.map { String(format: "%.1f kg", $0) } ?? "待积累", detail: "\(report.previousDays)/7 天有记录")
      if let change = report.weekChange {
        metric("两周均值变化", value: signed(change) + " kg", detail: "近 7 天均值 − 前 7 天均值")
      }
      Text("每段至少测量 3 天才计算均值。体重变化不等于脂肪变化；尽量在相近时间、相同条件下测量。").font(.caption).foregroundStyle(Color.secondaryInk)
    }
    Surface {
      Text("补记一次测量").font(.headline)
      HStack {
        TextField("今天体重（kg）", text: $weight).entryField().accessibilityLabel("今天体重")
          #if os(iOS)
          .keyboardType(.decimalPad)
          #endif
        Button { if store.addWeight(Double(weight) ?? .nan) { weight = "" } } label: {
          Text("保存").font(.subheadline.bold()).padding(13).background(Color.pine, in: Capsule()).foregroundStyle(.white)
        }.buttonStyle(.plain)
      }
    }
    if !report.daily.isEmpty {
      Surface {
        Text("最近测量").font(.headline)
        ForEach(report.daily.suffix(7).reversed()) { item in
          metric(item.date.formatted(date: .abbreviated, time: .shortened), value: String(format: "%.1f kg", item.kg), detail: item.source)
        }
      }
    }
  }
  private func signed(_ value: Double) -> String { String(format: "%+.1f", value) }
}

private struct SleepAnalysisView: View {
  @EnvironmentObject var store: AppStore
  @State private var days = 7
  @State private var selected: Date?
  private var reports: [SleepReport] { HealthAnalytics.sleep(store.data.sleep, days: days) }
  private var report: SleepReport? { reports.first { $0.day == selected } ?? reports.last }
  private let stages: [SleepStage] = [.awake, .rem, .core, .deep, .unspecified, .conflict]
  var body: some View {
    if let report {
      Surface {
        HStack {
          Text("睡眠记录").font(.headline)
          Spacer()
          Picker("查看睡眠日", selection: Binding(get: { report.day }, set: { selected = $0 })) {
            ForEach(reports.reversed()) { value in
              Text(value.day, format: .dateTime.month().day()).tag(value.day)
            }
          }.labelsHidden()
        }
        Text(duration(report.sleepSeconds)).font(.system(size: 36, weight: .bold, design: .rounded))
        Text("实际记录睡眠 · 不含清醒与卧床时长").font(.caption).foregroundStyle(Color.secondaryInk)
        if let start = report.start, let end = report.end {
          Text("\(start.formatted(date: .abbreviated, time: .shortened)) — \(end.formatted(date: .abbreviated, time: .shortened))").font(.caption)
        }
        Chart(report.segments) { segment in
          BarMark(xStart: .value("开始", segment.start), xEnd: .value("结束", segment.end), y: .value("阶段", segment.stage.label), height: .ratio(0.65))
            .foregroundStyle(stageColor(segment.stage))
        }.chartYScale(domain: stages.filter { report.seconds($0) > 0 || [.awake, .rem, .core, .deep].contains($0) }.map(\.label)).chartXAxis {
          AxisMarks(values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute())
          }
        }.frame(height: 200)
        ForEach(stages, id: \.self) { stage in
          let seconds = report.seconds(stage)
          if seconds > 0 {
            HStack {
              Circle().fill(stageColor(stage)).frame(width: 8, height: 8)
              Text(stage.label)
              Spacer()
              Text(duration(seconds)).monospacedDigit()
              if stage.isAsleep {
                Text(String(format: "%.1f%%", seconds / report.sleepSeconds * 100)).frame(width: 50, alignment: .trailing).foregroundStyle(Color.secondaryInk)
              }
            }.font(.subheadline)
          }
        }
        Text("记录到 \(report.awakenings) 段睡眠间清醒 · 来源：\(report.source)").font(.caption).foregroundStyle(Color.secondaryInk)
        if report.seconds(.conflict) > 0 {
          Text("部分清醒与睡眠记录冲突，该区间未计入睡眠总量。").font(.caption).foregroundStyle(.orange)
        }
        if report.sourceCount > 1 {
          Text("发现多个来源，优先使用 Apple Watch 的一个来源，避免重复累计。").font(.caption).foregroundStyle(Color.secondaryInk)
        }
      }
    } else {
      Surface { EmptyHint(symbol: "moon.zzz", title: "暂无可用睡眠记录", detail: "戴表睡眠后，等待记录进入 Apple 健康。App 会自动读取可用数据。") }
    }
    Surface {
      Text("睡眠时长趋势").font(.headline)
      Picker("睡眠时间范围", selection: $days) {
        Text("7 天").tag(7); Text("30 天").tag(30)
      }.pickerStyle(.segmented)
      if !reports.isEmpty {
        let average = reports.reduce(0) { $0 + $1.sleepSeconds } / Double(reports.count)
        Text("已记录日平均 \(duration(average))").font(.title3.bold())
        Chart(reports) { value in
          BarMark(x: .value("睡眠日", value.day, unit: .day), y: .value("小时", value.sleepSeconds / 3600))
            .foregroundStyle(Color.pine.gradient)
        }.frame(height: 160)
        Text("\(days) 个睡眠日中有 \(reports.count) 日记录；缺失日不算作 0 小时。").font(.caption).foregroundStyle(Color.secondaryInk)
      }
      Text("以中午 12 点划分睡眠日，归到结束日；当日记录可能尚不完整。分期来自设备估计。按来源去重与分日方式可能与 Apple 健康不同，清醒片段不等同于实际醒来次数。").font(.caption).foregroundStyle(Color.secondaryInk)
    }
  }
  private func stageColor(_ stage: SleepStage) -> Color {
    switch stage {
    case .awake: return .orange
    case .rem: return .cyan
    case .core: return .blue
    case .deep: return .indigo
    case .conflict: return .red
    default: return .gray
    }
  }
  private func duration(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "\(minutes) 分钟"
  }
}

private func metric(_ title: String, value: String, detail: String) -> some View {
  VStack(alignment: .leading, spacing: 5) {
    HStack {
      Text(title).font(.subheadline)
      Spacer()
      Text(value).font(.headline).monospacedDigit()
    }
    Text(detail).font(.caption).foregroundStyle(Color.secondaryInk)
  }.padding(.vertical, 3)
}
