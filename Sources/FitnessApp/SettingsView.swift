import FitnessCore
import SwiftUI
import UniformTypeIdentifiers

struct BackupDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var bytes: Data
  init(bytes: Data) { self.bytes = bytes }
  init(configuration: ReadConfiguration) throws {
    bytes = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: bytes)
  }
}
struct SettingsView: View {
  @EnvironmentObject var store: AppStore
  @AppStorage("coach.includeHealthSummary") private var includeHealthSummary = false
  @AppStorage("coach.includeMemorySummary") private var includeMemorySummary = false
  @State private var tool: HomeDestination?
  @State private var exporting = false
  @State private var editing = false
  @State private var agent = false
  @State private var setup = false
  @State private var records = false
  @State private var importing = false
  @State private var confirmingRestore = false
  @State private var undoPlan = false
  @State private var bytes = Data()
  @State private var pending: FitnessBackup?
  private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.6.0" }
  private func weekdays(_ values: Set<Int>) -> String {
    let labels = [1: "日", 2: "一", 3: "二", 4: "三", 5: "四", 6: "五", 7: "六"]
    return [2,3,4,5,6,7,1].filter(values.contains).compactMap { labels[$0] }.joined(separator: "、")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Surface {
        Text("聊天").font(.headline)
        Toggle("结合我的健康记录", isOn: $includeHealthSummary).tint(Color.ink)
        Toggle("在 AI 回复中使用记忆", isOn: $includeMemorySummary).tint(Color.ink)
        Text("开启后，仅把相关且有效的记忆摘要随消息发送到私人服务及 DeepSeek。关闭后仍可在本机查看、更正或忘记；记忆库保存在手机。此选择持续生效。").font(.caption).foregroundStyle(Color.secondaryInk)
        Text("开启后，发送消息时附带必要的档案、训练、饮食、体重和睡眠摘要给私人服务及 DeepSeek。此选择保留到你关闭；原始健康样本不上传。关闭时仍可正常聊天。").font(.caption).foregroundStyle(Color.secondaryInk)
        Text("点击发送会提交输入的文字或所选图片。模型服务商可能保留输入。").font(.caption).foregroundStyle(Color.secondaryInk)
        Text("消息提交成功后，切出 App 仍由服务器继续处理；返回后自动接上结果。服务器加密暂存任务及结果，取回并保存后即清理，最长保留 24 小时。本版暂不提供系统完成通知。点击停止会取消任务；断网时取消会在重新连接后送达。").font(.caption).foregroundStyle(Color.secondaryInk)
        Button("模型与连接") { agent = true }
      }
      DisclosureGroup("记录与工具") {
        ForEach([CoachAction.training, .foodIdeas, .weight, .review, .records]) { action in
          Button(action.title) { tool = HomeDestination(action: action) }.padding(.vertical, 8)
        }
      }
      Surface {
        HStack { Text("你的起点").font(.title2.bold()); Spacer(); Button("编辑") { editing = true } }
        Text("\(store.data.profile.age) 岁 · 男 · \(store.data.profile.heightCM, specifier: "%.0f") cm")
        Text("初始体重 \(store.data.profile.initialWeightKG, specifier: "%.1f") kg")
        Text(store.data.profile.goal).font(.subheadline).foregroundStyle(Color.secondaryInk)
        Button("训练条件、训练日与做饭时间") { setup = true }
        Button("记录管理 · 编辑 / 移除 / 恢复") { records = true }
      }
      Surface {
        Text("完整备份与恢复").font(.title2.bold())
        Text("备份包含教练对话、未发送输入、待确认餐食草稿、档案、健康记录、餐食照片、训练、计划历史和已移除记录。文件未加密，请保存在你信任的位置；Agent 连接令牌不包含在备份中。照片合计上限 80 MB。").font(.caption).foregroundStyle(Color.secondaryInk)
        MainButton(title: "导出完整备份（含照片）", symbol: "square.and.arrow.up") {
          do { bytes = try store.backupBytes(); exporting = true } catch { store.alert = error.localizedDescription }
        }
        Button("从完整备份恢复…") { importing = true }
        Text("恢复将替换当前记录，执行前先另存一份本机备份。Apple 健康中的原记录不会被修改或删除。卸载 App 会丢失本机记录，请先导出。").font(.caption).foregroundStyle(Color.secondaryInk)
        if !store.recoveryFiles.isEmpty {
          DisclosureGroup("恢复前的本机备份") {
            ForEach(store.recoveryFiles, id: \.path) { file in
              let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
              Button("恢复到 " + date.formatted()) {
                do { pending = try store.recoveryBackup(file); confirmingRestore = true } catch { store.alert = "这份保留文件无法作为完整备份恢复：" + error.localizedDescription }
              }
            }
          }
        }
      }
      Surface {
        Text("调整历史").font(.title2.bold())
        if let state = store.data.coach, !state.changes.isEmpty {
          Text("当前计划版本 \(state.revision)").font(.caption)
          Button("撤回最近一次调整…") { undoPlan = true }
          ForEach(state.changes.reversed()) { change in
            VStack(alignment: .leading, spacing: 4) {
              Text("v\(change.revision) · " + change.reason).font(.subheadline)
              Text("训练时间 \(change.before.workoutMinutes) → \(change.after.workoutMinutes) 分钟 · \(change.date.formatted())").font(.caption).foregroundStyle(Color.secondaryInk)
              Text("器械：" + change.before.equipment + " → " + change.after.equipment).font(.caption)
              Text("训练日：" + weekdays(change.before.trainingWeekdays) + " → " + weekdays(change.after.trainingWeekdays)).font(.caption)
              Text("限制：" + change.before.restrictions + " → " + change.after.restrictions).font(.caption)
              if !change.evidence.isEmpty { Text("依据：\(change.evidence.count) 条关联反馈 / 历史记录").font(.caption) }
            }
          }
        } else { Text("确认训练条件或接受周复盘调整后，会在这里留下版本记录。").font(.subheadline) }
      }
      Surface {
        Text("安装与数据连接").font(.headline)
        Text("当前为个人开发签名，需要定期连接 Mac 续签安装；不要先卸载。长期分发仍需确认开发者会员资格与分发方式。").font(.subheadline)
        Text("健康数据自动更新受 iOS 调度与锁屏保护影响，不保证秒级同步。首页选图后点击发送即可分析；精确营养目标和 Watch 独立 App 尚未接入。").font(.caption).foregroundStyle(Color.secondaryInk)
      }
    }.sheet(isPresented: $editing) { ProfileSheet() }
      .sheet(item: $tool) { HomeModuleSheet(destination: $0) }
      .sheet(isPresented: $agent) { AgentSettingsSheet() }
      .sheet(isPresented: $setup) { CoachSetupSheet() }
      .sheet(isPresented: $records) { RecordManager() }
      .fileExporter(isPresented: $exporting, document: BackupDocument(bytes: bytes), contentType: .json, defaultFilename: "Mateo-Fit-Backup-" + Date().formatted(.iso8601.year().month().day())) { result in
        if case .failure(let error) = result { store.alert = "导出失败：" + error.localizedDescription }
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
        do {
          let file = try result.get(), access = file.startAccessingSecurityScopedResource()
          defer { if access { file.stopAccessingSecurityScopedResource() } }
          let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          guard size <= 150_000_000 else { throw BackupError.invalid("文件过大，暂不支持。") }
          pending = try BackupCodec.decode(Data(contentsOf: file)); confirmingRestore = true
        } catch { store.alert = "未导入：" + error.localizedDescription }
      }
      .alert("确认用备份替换当前记录？", isPresented: $confirmingRestore) {
        Button("取消", role: .cancel) { pending = nil }
        Button("备份当前数据并恢复", role: .destructive) { if let pending { _ = store.restore(pending) }; pending = nil }
      } message: {
        if let pending { Text("备份日期：\(pending.createdAt.formatted())\n餐食 \(pending.records.meals.count) · 训练 \(pending.records.workouts.count) · 体重 \(pending.records.weights.count) · 照片 \(pending.photos.count)\n确认后替换，不与当前记录合并。") }
      }
      .alert("撤回最近一次计划调整？", isPresented: $undoPlan) {
        Button("取消", role: .cancel) {}
        Button("确认撤回") { store.undoLatestPlan() }
      } message: { Text("恢复上一版训练条件，并保留新的撤回记录。已完成的训练与餐食不会改变。") }
  }
}
struct ProfileSheet: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var age = "24"
  @State private var height = "183"
  @State private var weight = "119"
  @State private var days = 3
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("编辑档案").font(.title.bold())
        Spacer()
        Button("取消") { dismiss() }
      }
      FieldLabel(title: "年龄")
      TextField("年龄", text: $age).entryField()
      FieldLabel(title: "身高 cm")
      TextField("身高", text: $height).entryField()
      FieldLabel(title: "初始体重 kg")
      TextField("初始体重", text: $weight).entryField()
      Text("训练日请在“训练条件”中调整。").font(.caption)
      MainButton(title: "保存档案", symbol: "checkmark") {
        guard let a = Int(age), (18...100).contains(a), let h = Double(height),
          (100...250).contains(h), let w = Double(weight), DataMath.validWeight(w)
        else {
          store.alert = "请检查年龄、身高和体重。"
          return
        }
        var p = store.data.profile
        p.age = a
        p.heightCM = h
        p.initialWeightKG = w
        if store.saveProfile(p) { dismiss() }
      }
    }.padding(26).frame(minWidth: 340).background(Color.canvas).onAppear {
      age = String(store.data.profile.age)
      height = String(store.data.profile.heightCM)
      weight = String(store.data.profile.initialWeightKG)
      days = store.data.profile.weeklyGymDays
    }
  }
}
