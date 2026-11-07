import Foundation

public enum MealAgentError: Error, LocalizedError {
  case configuration, consent, invalid, unauthorized, unavailable, busy, input
  public var errorDescription: String? {
    switch self {
    case .configuration: return "请先配置 HTTPS Agent 服务地址和连接令牌。"
    case .consent: return "请确认本次照片和文字的上传范围。"
    case .invalid: return "回复未通过校验，请重试；尚未执行任何操作。"
    case .unauthorized: return "连接令牌未通过验证，请在 Agent 设置中检查。"
    case .unavailable: return "Agent 尚未配置模型或暂时不可用。可以先保存本地记录，稍后再分析。"
    case .busy: return "请求较频繁，请稍后再试。"
    case .input: return "请添加餐食照片或描述，照片压缩后需小于 1.5 MB。"
    }
  }
}
public struct NutritionRange: Codable, Equatable {
  public let low: Double
  public let high: Double
  public var valid: Bool { low.isFinite && high.isFinite && low >= 0 && high >= low && high <= 10000 }
  public var midpoint: Double { (low + high) / 2 }
}
public struct MealAgentTotals: Codable, Equatable {
  public let energyKcal: NutritionRange?
  public let proteinG: NutritionRange?
  public let carbsG: NutritionRange?
  public let fatG: NutritionRange?
  public var valid: Bool { [energyKcal, proteinG, carbsG, fatG].allSatisfy { $0?.valid ?? true } }
  public var hasNumbers: Bool { [energyKcal, proteinG, carbsG, fatG].contains { $0 != nil } }
}
public struct MealAgentItem: Codable, Equatable {
  public let name: String
  public let grams_low: Double?
  public let grams_high: Double?
  public let source: String
  public let note: String
}
public struct MealAgentResult: Codable, Equatable {
  public let request_id: String
  public let title: String
  public let summary: String
  public let questions: [String]
  public let limitations: [String]
  public let items: [MealAgentItem]
  public let totals: MealAgentTotals
  public let requires_confirmation: Bool
  public let source: String
  public let catalog_version: String
  public var generation: CoachGenerationResult? = nil
  public func validate(expectedID: String) throws {
    guard request_id == expectedID, requires_confirmation, source == "AI 估计", totals.valid, generation?.valid ?? true,
      title.count <= 150, summary.count <= 600, questions.count <= 3, limitations.count <= 12, items.count <= 20,
      questions.allSatisfy({ $0.count <= 200 }), limitations.allSatisfy({ $0.count <= 500 }),
      items.allSatisfy({ item in
        item.name.count <= 150 && item.source.count <= 500 && item.note.count <= 500 &&
        (item.grams_low.map { $0.isFinite && $0 > 0 && $0 <= 5000 } ?? true) &&
        (item.grams_high.map { $0.isFinite && $0 > 0 && $0 <= 5000 } ?? true) &&
        ((item.grams_low == nil || item.grams_high == nil) || item.grams_low! <= item.grams_high!)
      }) else { throw MealAgentError.invalid }
  }
  public var estimatedNutrition: MealNutrition {
    var facts = MealNutrition(); facts.source = "AI 估计"
    facts.energyValue = totals.energyKcal?.midpoint; facts.proteinG = totals.proteinG?.midpoint
    facts.carbsG = totals.carbsG?.midpoint; facts.fatG = totals.fatG?.midpoint
    return facts
  }
  public var reviewNote: String {
    func range(_ value: NutritionRange?, _ unit: String) -> String { value.map { String(format: "%.1f–%.1f %@", $0.low, $0.high, unit) } ?? "未知" }
    let lines = items.map { "\($0.name)：\($0.source)；\($0.note)" }
    return (["[AI 分析原始估计，用户确认后采用；数值使用区间中点，可人工修改]", summary,
      "能量 \(range(totals.energyKcal, "kcal"))；蛋白质 \(range(totals.proteinG, "g"))；碳水 \(range(totals.carbsG, "g"))；脂肪 \(range(totals.fatG, "g"))"] + lines + limitations + ["依据：\(catalog_version) · 分析编号 \(request_id)"]).joined(separator: "\n")
  }
}
public struct AgentModel: Codable, Identifiable, Equatable {
  public let id: String
  public let name: String
  public let supports_images: Bool
  public init(id: String, name: String, supportsImages: Bool) { self.id = id; self.name = name; self.supports_images = supportsImages }
}
public struct MealAgentStatus: Codable {
  public let status: String
  public let storage: String
  public let model: String
  public let provider: String
  public let models: [AgentModel]?
  public let assistant_contract_versions: [Int]?
  public var assistant_features: CoachCapabilities? = nil
}
final class MealNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public struct MealAgentTransport {
  public let endpoint: URL
  public let token: String
  public init(endpoint: URL, token: String) { self.endpoint = endpoint; self.token = token }
  public static func validEndpoint(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
  }
  public func status() async throws -> MealAgentStatus {
    let bytes = try await send(path: "agent/status", body: Data("{}".utf8))
    return try JSONDecoder().decode(MealAgentStatus.self, from: bytes)
  }
  public func analyze(id: String, description: String, jpeg: Data?, consent: Bool, model: String? = nil) async throws -> MealAgentResult {
    guard consent else { throw MealAgentError.consent }
    guard description.count <= 3000, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || jpeg != nil,
      jpeg.map({ $0.count <= 1_500_000 && $0.starts(with: [0xff, 0xd8, 0xff]) }) ?? true else { throw MealAgentError.input }
    struct Payload: Encodable { let request_id: String; let description: String; let image_jpeg_base64: String?; let consent: Bool; let model: String? }
    let body = try JSONEncoder().encode(Payload(request_id: id, description: description, image_jpeg_base64: jpeg?.base64EncodedString(), consent: true, model: model))
    let bytes = try await send(path: "meal/analyze", body: body)
    let result = try JSONDecoder().decode(MealAgentResult.self, from: bytes)
    try result.validate(expectedID: id)
    return result
  }
  public func route(id: String, text: String, history: [RouterHistory] = [], consent: Bool) async throws -> AssistantRoute {
    guard consent else { throw MealAgentError.consent }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 3000 else { throw MealAgentError.input }
    guard history.count <= 8, history.allSatisfy({ ["user","assistant"].contains($0.role) && $0.content.count <= 800 }) else { throw MealAgentError.input }
    struct Payload: Encodable { let request_id: String; let text: String; let history: [RouterHistory]; let consent: Bool }
    let bytes = try await send(path: "assistant/route", body: JSONEncoder().encode(Payload(request_id: id, text: text, history: history, consent: true)))
    let response = try JSONDecoder().decode(AssistantRoute.self, from: bytes)
    try response.validate(id: id)
    return response
  }
  public func respond(id: String, text: String, history: [RouterHistory], snapshot: CoachSnapshot, consent: CoachConsent, model: String? = nil) async throws -> CoachAssistantResponse {
    guard consent.text, consent.health_summary || (snapshot.facts.isEmpty && snapshot.candidates.isEmpty) else { throw MealAgentError.consent }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 3000,
      history.count <= 8, history.allSatisfy({ ["user", "assistant"].contains($0.role) && $0.content.count <= 800 }) else { throw MealAgentError.input }
    struct Payload: Encodable { let request_id: String; let text: String; let history: [RouterHistory]; let snapshot: CoachSnapshot; let consent_scope: CoachConsent; let model: String? }
    let body = try JSONEncoder().encode(Payload(request_id: id, text: text, history: history, snapshot: snapshot, consent_scope: consent, model: model))
    guard body.count <= 65536 else { throw MealAgentError.input }
    let bytes = try await send(path: "assistant/respond", body: body)
    let response = try JSONDecoder().decode(CoachAssistantResponse.self, from: bytes)
    try response.validate(requestID: id, snapshot: snapshot)
    return response
  }
  public func respondV2(id: String, text: String, history: [RouterHistory], snapshot: CoachSnapshot, health: Bool, memory: Bool, learning: Bool, model: String?) async throws -> CoachAssistantResponse {
    let bytes = try assistantBody(id: id, text: text, history: history, snapshot: snapshot, health: health, memory: memory, learning: learning, model: model)
    let response = try JSONDecoder().decode(CoachAssistantResponse.self, from: try await send(path: "assistant/respond", body: bytes))
    guard response.contract_version == 2 else { throw MealAgentError.invalid }
    try response.validate(requestID: id, snapshot: snapshot)
    return response
  }
  func assistantBody(id: String, text: String, history: [RouterHistory], snapshot: CoachSnapshot, health: Bool, memory: Bool, learning: Bool, model: String?, generation: CoachGenerationOptions? = nil) throws -> Data {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 3000, history.count <= 8,
      health || (snapshot.candidates.isEmpty && snapshot.expected_plan_version == "withheld" && snapshot.facts.allSatisfy { $0.id.hasPrefix("memory.") || $0.id == "public.clock" }),
      memory || !snapshot.facts.contains(where: { $0.id.hasPrefix("memory.") }) else { throw MealAgentError.consent }
    struct Consent: Encodable { let text = true; let health_summary: Bool; let memory_summary: Bool }
    struct Payload: Encodable { let generation: CoachGenerationOptions?; let contract_version = 2; let request_id: String; let text: String; let history: [RouterHistory]; let snapshot: CoachSnapshot; let consent_scope: Consent; let memory_learning: Bool; let model: String? }
    let bytes = try JSONEncoder().encode(Payload(generation: generation, request_id: id, text: text, history: history, snapshot: snapshot, consent_scope: Consent(health_summary: health, memory_summary: memory), memory_learning: learning, model: model))
    guard bytes.count <= 65536 else { throw MealAgentError.input }
    return bytes
  }
  private func send(path: String, body: Data) async throws -> Data {
    guard Self.validEndpoint(endpoint), token.count >= 32 else { throw MealAgentError.configuration }
    var request = URLRequest(url: endpoint.appendingPathComponent(path))
    request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 45
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForResource = 50; configuration.httpShouldSetCookies = false; configuration.urlCache = nil
    let session = URLSession(configuration: configuration, delegate: MealNoRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (stream, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw MealAgentError.invalid }
    switch http.statusCode {
    case 200: break
    case 401, 403: throw MealAgentError.unauthorized
    case 429: throw MealAgentError.busy
    case 500...599: throw MealAgentError.unavailable
    default: throw MealAgentError.invalid
    }
    var result = Data()
    for try await byte in stream {
      try Task.checkCancellation()
      guard result.count < 256_000 else { throw MealAgentError.invalid }
      result.append(byte)
    }
    return result
  }
}
