import FitnessCore
import SwiftUI
import Security
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

struct AgentConnection: Codable {
  var address = ""
  var token = ""
  var endpoint: URL? { URL(string: address).flatMap { MealAgentTransport.validEndpoint($0) ? $0 : nil } }
  var transport: MealAgentTransport? { guard let endpoint, token.count >= 32 else { return nil }; return MealAgentTransport(endpoint: endpoint, token: token) }
  static func load() -> AgentConnection {
    let pending = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("mateo-agent-pairing.json")
    if let bytes = try? Data(contentsOf: pending), bytes.count < 4096,
       let imported = try? JSONDecoder().decode(Self.self, from: bytes), imported.transport != nil,
       (try? imported.save()) != nil { try? FileManager.default.removeItem(at: pending) }

    let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.personal.xuxu.meal-agent",kSecAttrAccount as String:"connection",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
    var value: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let bytes = value as? Data, let config = try? JSONDecoder().decode(Self.self, from: bytes) else { return Self() }
    return config
  }
  func save() throws {
    guard transport != nil else { throw MealAgentError.configuration }
    let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.personal.xuxu.meal-agent",kSecAttrAccount as String:"connection"]
    let bytes = try JSONEncoder().encode(self)
    let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String:bytes] as CFDictionary)
    if update == errSecItemNotFound {
      var create = query; create[kSecValueData as String] = bytes
      create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      guard SecItemAdd(create as CFDictionary, nil) == errSecSuccess else { throw MealAgentError.configuration }
    } else if update != errSecSuccess { throw MealAgentError.configuration }
  }
  static func remove() -> Bool {
    let code = SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.personal.xuxu.meal-agent",kSecAttrAccount as String:"connection"] as CFDictionary)
    return code == errSecSuccess || code == errSecItemNotFound
  }
}
struct AgentSettingsSheet: View {
  @Environment(\.dismiss) var dismiss
  @State private var config = AgentConnection()
  @State private var message = "尚未检查连接"
  @State private var busy = false
  @State private var task: Task<Void, Never>?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack { Text("教练 Agent 连接").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() } }
        Text("连接你的私人 Agent 服务。模型服务商密钥只放在服务端，手机使用单独的连接令牌。").font(.subheadline)
        TextField("HTTPS Agent 地址", text: $config.address).entryField().autocorrectionDisabled()
        SecureField("Agent 连接令牌（不是模型 API Key）", text: $config.token).entryField()
        Text("地址与令牌保存在此设备钥匙串，不进入健康记录或导出备份。只接受 HTTPS，不会随跳转发送令牌。").font(.caption).foregroundStyle(Color.secondaryInk)
        MainButton(title: busy ? "正在检查…" : "检查服务配置", symbol: "network") {
          let current = config
          guard let transport = current.transport else { message = MealAgentError.configuration.localizedDescription; return }
          busy = true
          task = Task { @MainActor in
            defer { busy = false }
            do {
              let result = try await transport.status(); try Task.checkCancellation()
              guard config.address == current.address && config.token == current.token else { return }
              message = result.status == "ready" ? "服务已配置：\(result.provider) / \(result.model)。这只是配置检查，需分析一餐才算实际模型调用验证。" : "已连到 Agent，但服务端尚未配置模型。"
            } catch { if !Task.isCancelled { message = "检查未完成：" + friendlyAgentError(error) } }
          }
        }.disabled(busy)
        Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        MainButton(title: "保存连接", symbol: "checkmark") {
          do { try config.save(); message = "连接已保存。" } catch { message = friendlyAgentError(error) }
        }.disabled(busy)
        Button("移除此设备的连接", role: .destructive) {
          task?.cancel(); busy = false
          if AgentConnection.remove() { config = AgentConnection(); message = "已移除本机连接，餐食记录保留。服务端令牌如需撤销，应在服务端轮换。" }
          else { message = "连接暂未移除，请稍后重试。" }
        }
        Text("检查配置不会上传照片或健康数据。真实分析会将你选择的这餐照片和描述发给该 Agent 及其配置的模型服务商；服务商的数据政策与费用取决于你的选择。聊天账号登录状态不能当作 API 已连接。").font(.caption).foregroundStyle(Color.secondaryInk)
        Link("DeepSeek 隐私政策与删除请求方式", destination: URL(string: "https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html")!).font(.caption)
      }.padding(24)
    }.frame(minWidth: 340, minHeight: 540).background(Color.canvas)
      .onAppear { config = AgentConnection.load() }
      .onDisappear { task?.cancel() }
  }
}
private func friendlyAgentError(_ error: Error) -> String {
  if let known = error as? MealAgentError { return known.localizedDescription }
  if error is CancellationError { return "已取消" }
  return "网络或模型响应未完成，请检查连接后重试。没有保存任何分析结果。"
}
func mealUploadJPEG(_ data: Data) throws -> Data {
  guard data.count <= 20_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
    let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:1280] as CFDictionary) else { throw MealAgentError.input }
  let bytes = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { throw MealAgentError.input }
  CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality:0.75] as CFDictionary)
  guard CGImageDestinationFinalize(destination), bytes.length <= 1_500_000 else { throw MealAgentError.input }
  return bytes as Data
}

struct MealAISection: View {
  @Binding var title: String
  @Binding var note: String
  var photo: Data?
  @Binding var facts: MealNutrition
  @Binding var showFacts: Bool
  @State private var settings = false
  @State private var consent = false
  @State private var confirmed = false
  @State private var result: MealAgentResult?
  @State private var resultInput: String?
  @State private var appliedInput: String?
  @State private var message: String?
  @State private var busy = false
  @State private var task: Task<Void, Never>?
  @State private var activeID: UUID?
  @State private var connection = AgentConnection.load()
  private var fingerprint: String {
    var digest = SHA256(); digest.update(data: Data(title.utf8)); digest.update(data: Data([0])); digest.update(data: Data(note.utf8)); digest.update(data: Data([0])); digest.update(data: photo ?? Data())
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private func invalidate() {
    task?.cancel(); activeID = nil; busy = false; result = nil; resultInput = nil; confirmed = false; consent = false
    if let appliedInput, appliedInput != fingerprint, facts.source == "AI 估计" {
      facts = MealNutrition(); self.appliedInput = nil; message = "餐食内容已更改，旧的 AI 营养估计已清除；请重新分析或手动填写。"
    }
  }
  var body: some View {
    Surface {
      HStack { Text("饮食 Agent 自动分析").font(.headline); Spacer(); Button("连接设置") { settings = true } }
      if connection.transport == nil {
        Text("先连接模型服务，再分析照片或文字。尚未配置时仍可正常手动记录。").font(.subheadline)
        Button("配置我的 Agent") { settings = true }
      } else {
        Text("发送至：\(connection.endpoint?.host ?? "")。仅包含这餐照片及下方文字；照片压缩重编码，移除附带位置元数据。画面本身仍会上传。").font(.caption)
        Text("本页分析不在私人服务保存内容；首页后台任务会加密暂存，取回后清理，最长 24 小时。模型服务商仍可能保留输入；删除本地餐食不会删除服务商副本。").font(.caption).foregroundStyle(Color.secondaryInk)
        Toggle("同意本次上传给 Agent 及其模型服务商", isOn: $consent).font(.caption)
        MainButton(title: busy ? "正在分析这餐…" : "分析照片与描述", symbol: "sparkles") { analyze() }.disabled(busy || !consent || (photo == nil && title.isEmpty && note.isEmpty))
        if busy { Button("取消分析") { invalidate(); message = "已取消等待；已发出的请求可能仍由服务商处理并计费，不会自动重试。" } }
      }
      if let message { Text(message).font(.caption).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true) }
      if let result {
        MealAnalysisPreview(result: result)
        if !result.questions.isEmpty { Text("把答案补在上面的份量说明里，再点分析。修改后旧结果会失效。").font(.caption) }
        if result.totals.hasNumbers {
          Toggle("我已核对食物、吃下的份量与估计范围", isOn: $confirmed).font(.caption)
          MainButton(title: "将估计填入表单，继续核对", symbol: "checkmark") {
            guard resultInput == fingerprint, confirmed else { message = "内容已变化，请重新分析。"; return }
            facts = result.estimatedNutrition
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = result.title }
            note += (note.isEmpty ? "" : "\n") + result.reviewNote
            appliedInput = fingerprint; showFacts = true
            self.result = nil; resultInput = nil; consent = false; confirmed = false
            message = "已填入区间中点，来源标为 AI 估计。还未保存餐食，请核对后点“确认吃过并保存”。"
          }.disabled(!confirmed)
        }
      }
    }
    .onChange(of: fingerprint) { _, _ in invalidate() }
    .onChange(of: consent) { _, allowed in if !allowed && busy { invalidate() } }
    .sheet(isPresented: $settings, onDismiss: { invalidate(); connection = AgentConnection.load() }) { AgentSettingsSheet() }
    .onDisappear { task?.cancel(); activeID = nil }
  }
  private func analyze() {
    guard let transport = connection.transport, consent else { return }
    let input = fingerprint, id = UUID(), text = title + "\n" + note, selectedPhoto = photo
    activeID = id; busy = true; result = nil; confirmed = false; message = nil
    task = Task { @MainActor in
      defer { if activeID == id { busy = false } }
      do {
        let jpeg = try selectedPhoto.map(mealUploadJPEG)
        let reply = try await transport.analyze(id: id.uuidString, description: text, jpeg: jpeg, consent: true)
        try Task.checkCancellation()
        guard activeID == id, fingerprint == input else { return }
        result = reply; resultInput = input
      } catch { if activeID == id && !Task.isCancelled { message = friendlyAgentError(error) } }
    }
  }
}
struct MealAnalysisPreview: View {
  let result: MealAgentResult
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("识别结果 · 尚未保存").font(.headline)
      Text(result.title).font(.title3.bold()); Text(result.summary).font(.subheadline)
      ForEach(Array(result.items.enumerated()), id: \.offset) { _, item in
        VStack(alignment: .leading, spacing: 3) {
          Text(item.name).font(.headline)
          if let low = item.grams_low, let high = item.grams_high { Text("估计 \(low, specifier: "%.0f")–\(high, specifier: "%.0f") g").font(.subheadline) }
          else { Text("份量待确认").font(.subheadline) }
          Text(item.source + " · " + item.note).font(.caption).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
        }
      }
      range("能量", result.totals.energyKcal, "kcal"); range("蛋白质", result.totals.proteinG, "g")
      range("碳水", result.totals.carbsG, "g"); range("脂肪", result.totals.fatG, "g")
      ForEach(Array(result.questions.enumerated()), id: \.offset) { _, question in Text("待确认：" + question).font(.subheadline) }
      ForEach(Array(result.limitations.enumerated()), id: \.offset) { _, limit in Text(limit).font(.caption).foregroundStyle(Color.secondaryInk) }
      Text("采用后用区间中点参与当天汇总，仍是估计；未给出数值的项目保持未知。").font(.caption)
    }
  }
  private func range(_ title: String, _ range: NutritionRange?, _ unit: String) -> some View {
    HStack { Text(title); Spacer(); Text(range.map { value in
      let format = unit == "kcal" ? "%.0f" : "%.1f"
      let low = String(format: format, value.low), high = String(format: format, value.high)
      return (low == high ? low : low + "–" + high) + " " + unit
    } ?? "未知") }.font(.subheadline)
  }
}
