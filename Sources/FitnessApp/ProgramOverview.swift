import FitnessCore
import SwiftUI

struct ProgramOverview: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var phase = "恢复适应"
  @State private var setup = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack { Text("你的完整周计划").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() } }
        Surface(dark: true) {
          Pill(text: "每周 3 次力量 + 第 4 次可选恢复", dark: true)
          Text("恢复训练，逐步减脂").font(.title.bold())
          Text("根据你提供的 \(store.data.profile.age) 岁、\(Int(store.data.profile.heightCM)) cm、起点 \(store.data.profile.initialWeightKG, specifier: "%.1f") kg，以及每周约两次乒乓球安排。起点体重不是今天测量，也不用于推算负重。").font(.subheadline)
          Text("每次预留约 60–75 分钟；有 90 分钟也不必用满。先建立动作和恢复节奏。").font(.subheadline)
        }
        Surface {
          Text("一周怎么放").font(.headline)
          Text(StrengthProgram.weeklyExample).font(.subheadline)
          Text("力量训练间隔至少一个非力量日，每周留一个完整休息日。这里是周安排示例，实际日期以你确认的训练日为准；乒乓球不等于力量工作组。").font(.caption).foregroundStyle(Color.secondaryInk)
        }
        Surface {
          Text("先选要预览的阶段").font(.headline)
          Picker("阶段预览", selection: $phase) { ForEach(StrengthProgram.phases, id: \.self) { Text($0) } }.pickerStyle(.segmented)
          Text(phase == "恢复适应" ? "前 1–2 周先用这一阶段：每个动作 2 组，保留 3–4 次余力。若生疏或较累，选当天轻松版减至 1 组。" : "连续训练后动作稳定、日常恢复良好，再考虑主要动作 3 组，辅助动作仍 2 组；保留约 2–3 次余力。")
          Text("日期不会自动触发加组。切换这里仅改变预览，下面确认保存才生效。加组时先保持负重，重新积累完整组数的表现。").font(.caption).foregroundStyle(Color.secondaryInk)
        }
        Surface { Text("每次先热身").font(.headline); Text(StrengthProgram.warmup); Text(StrengthProgram.effort).font(.subheadline) }
        ForEach(0..<3, id: \.self) { slot in ProgramSessionCard(slot: slot, phase: phase) }
        Surface { Text("力量后：可选有氧与放松").font(.headline); Text(StrengthProgram.cardio) }
        Surface { Text("第 4 次：有余力再来").font(.headline); Text(StrengthProgram.optionalDay) }
        Surface {
          Text("当天怎么调整").font(.headline)
          Text("只有 20 分钟：取前 3 个可用动作，各 1 组，留出热身时间；45 分钟：前 4 个动作。打球后腿部较累、一般疲惫或选择轻松版：减为 1 组，保持或降低负重，不加练。").font(.subheadline)
          Text("有疼痛、头晕、明显困倦或动作不稳时暂停。劳拉西泮可能影响清醒与协调状态；这里不修改用药。器械不熟悉时请场馆教练协助调节。").font(.caption).foregroundStyle(Color.secondaryInk)
        }
        Surface {
          Text("让这份计划用于今天").font(.headline)
          if store.data.coach?.preferences.programID == StrengthProgram.id {
            Text("已采用：" + (store.data.coach?.preferences.trainingPhase ?? "恢复适应") + "。保存后关闭本页，在训练首页确认今天状态即可开始。").font(.subheadline).foregroundStyle(Color.pine)
          }
          Text("先确认三个力量训练日、器械和当前阶段，再确认当天状态。器械缺少可替换；改在家时使用徒手备用方案。").font(.subheadline)
          MainButton(title: "确认采用「\(phase)」计划", symbol: "checkmark.circle") { setup = true }
          Text("如果有进行中的训练，先保存或取消草稿再切换方案。已有实际记录保留。").font(.caption)
        }
        DisclosureGroup("依据与使用边界") {
          Text("这是根据你的目标与时间安排的本地方案，不是个体医学处方。具体动作、组次和阶段由本项目设计，尚未经过个体专业评估；身体反应和动作技术需要实际观察。").font(.caption)
          Link("ACSM 2026 抗阻训练指南", destination: URL(string: "https://acsm.org/resistance-training-guidelines-update-2026/")!)
          Link("NHS：劳拉西泮与困倦、头晕", destination: URL(string: "https://www.nhs.uk/medicines/lorazepam/")!)
        }
      }.padding(22)
    }.frame(minWidth: 340, minHeight: 560).background(Color.canvas)
      .onAppear { phase = store.data.coach?.preferences.trainingPhase ?? "恢复适应" }
      .sheet(isPresented: $setup) { CoachSetupSheet(proposedProgram: true, proposedPhase: phase) }
  }
}

struct ProgramSessionCard: View {
  let slot: Int
  let phase: String
  var body: some View {
    Surface {
      Text(StrengthProgram.names[slot]).font(.title3.bold())
      Text(phase + " · 约 55–75 分钟，含热身与可选有氧").font(.caption).foregroundStyle(Color.secondaryInk)
      ForEach(StrengthProgram.session(slot, phase: phase)) { item in
        VStack(alignment: .leading, spacing: 5) {
          Text(TrainingLibrary.guide(item.exerciseID)?.name ?? item.exerciseID).font(.headline)
          Text("\(item.sets) 组 × \(item.reps) · 组间休息 \(item.restSeconds ?? 90) 秒").font(.subheadline)
          if let guide = TrainingLibrary.guide(item.exerciseID) {
            DisclosureGroup("动作要点与替代") {
              Text(guide.cue); Text(guide.avoid).foregroundStyle(Color.secondaryInk)
              if let alternative = guide.alternativeID, let other = TrainingLibrary.guide(alternative) {
                Text("器械不可用时可换：" + other.name + "；独立校准，不沿用原动作重量。")
              } else { Text("没有合适器械或做起来不舒服时，在当天调整中排除，不强行完成。") }
            }.font(.caption)
          }
        }.padding(.vertical, 6)
      }
    }
  }
}
