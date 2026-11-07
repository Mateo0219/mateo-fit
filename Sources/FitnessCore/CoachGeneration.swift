import Foundation

public struct CoachGenerationOptions: Codable, Equatable, Sendable {
  public var effort = "none"
  public var web_mode = "off"
  public init(effort: String = "none", webMode: String = "off") { self.effort = effort; self.web_mode = webMode }
  public static let efforts = ["none", "low", "high", "max"]
  public static let webModes = ["off", "search", "research"]
  public var valid: Bool { Self.efforts.contains(effort) && Self.webModes.contains(web_mode) }
  public var effortTitle: String { ["none":"快速", "low":"思考 · 低", "high":"思考 · 高", "max":"思考 · 最大"][effort] ?? "快速" }
  public var webTitle: String { ["off":"不联网", "search":"联网搜索", "research":"Deep Research"][web_mode] ?? "不联网" }
}
public struct CoachCapabilities: Codable {
  public let background_jobs: Bool?
  public let job_retention_hours: Int?
  public let completion_notifications: Bool?
  public let streaming: Bool
  public let thinking_efforts: [String]
  public let web_modes: [String]
  public let citations: Bool
}
public struct CoachWebSource: Codable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let url: String
  public let read: Bool
  public var valid: Bool {
    guard id.range(of: #"^S[1-9][0-9]?$"#, options: .regularExpression) != nil, !title.isEmpty, title.count <= 200,
      url.count <= 2048, let parsed = URL(string: url), parsed.scheme == "https", let host = parsed.host,
      host.contains("."), parsed.user == nil, parsed.password == nil, parsed.port == nil || parsed.port == 443,
      ![".local", ".internal", ".localhost", ".test", ".invalid"].contains(where: host.hasSuffix),
      host.range(of: #"^[\d.:]+$"#, options: .regularExpression) == nil else { return false }
    return true
  }
}
public struct CoachGenerationResult: Codable, Equatable {
  public let effort: String
  public let web_mode: String
  public let model: String
  public let model_calls: Int
  public let search_calls: Int
  public let fetch_calls: Int
  public let prompt_tokens: Int?
  public let completion_tokens: Int?
  public let cache_hit_tokens: Int?
  public let reasoning_tokens: Int?
  public let elapsed_ms: Int
  public let reasoning_present: Bool
  public var valid: Bool {
    CoachGenerationOptions(effort: effort, webMode: web_mode).valid && model.count <= 100 && !model.isEmpty &&
      (1...8).contains(model_calls) && (0...6).contains(search_calls) && (0...6).contains(fetch_calls) &&
      [prompt_tokens, completion_tokens, cache_hit_tokens, reasoning_tokens].compactMap { $0 }.allSatisfy { (0...16_000_000).contains($0) } &&
      (cache_hit_tokens == nil || prompt_tokens == nil || cache_hit_tokens! <= prompt_tokens!) && (reasoning_tokens == nil || completion_tokens == nil || reasoning_tokens! <= completion_tokens!) && (0...360_000).contains(elapsed_ms)
  }
}
public enum CoachStreamUpdate: Sendable { case status(String), message(String) }
public struct CoachStreamEvent<Output: Decodable>: Decodable {
  public let request_id: String
  public let sequence: Int
  public let type: String
  public let stage: String?
  public let text: String?
  public let response: Output?
  public let code: String?
}
public enum CoachStreamError: LocalizedError {
  case failed(String)
  public var errorDescription: String? {
    guard case .failed(let code) = self else { return nil }
    switch code {
    case "budget_exhausted": return "今天的模型与检索额度已用完，内容尚未保存。"
    case "timeout": return "本次处理超时，未执行操作。可以缩小问题后重试。"
    case "incomplete_response": return "回复未完成，未执行操作。可以缩小问题后重试。"
    case "uncommitted_write_claim": return "回复没有真实保存依据，内容尚未保存。"
    case "web_provider_unavailable": return "联网检索暂不可用，未生成研究结论。"
    default: return "本次回复未完成或未通过校验，未执行操作。"
    }
  }
}
public struct CoachStreamDecoder<Output: Decodable> {
  private let requestID: String
  private var sequence = 0
  private var finished = false
  public init(requestID: String) { self.requestID = requestID }
  public mutating func decode(_ bytes: Data) throws -> CoachStreamEvent<Output> {
    guard !finished, bytes.count <= 256_000 else { throw MealAgentError.invalid }
    let event = try JSONDecoder().decode(CoachStreamEvent<Output>.self, from: bytes)
    guard event.request_id == requestID, event.sequence == sequence + 1 else { throw MealAgentError.invalid }
    sequence = event.sequence
    switch event.type {
    case "status": guard ["thinking", "responding", "searching", "reading", "summarizing"].contains(event.stage ?? "") else { throw MealAgentError.invalid }
    case "message": guard let text = event.text, text.count <= 1800, !CoachReplyText.claimsUncommittedWrite(text) else { throw MealAgentError.invalid }
    case "result": guard event.response != nil else { throw MealAgentError.invalid }; finished = true
    case "error": finished = true; throw CoachStreamError.failed(event.code ?? "unknown")
    default: throw MealAgentError.invalid
    }
    return event
  }
}
extension MealAgentTransport {
  public func respondStream(id: String, text: String, history: [RouterHistory], snapshot: CoachSnapshot, health: Bool, memory: Bool, learning: Bool, model: String, generation: CoachGenerationOptions, onUpdate: @escaping @MainActor (CoachStreamUpdate) -> Void) async throws -> CoachAssistantResponse {
    guard generation.valid else { throw MealAgentError.input }
    let body = try assistantBody(id: id, text: text, history: history, snapshot: snapshot, health: health, memory: memory, learning: learning, model: model, generation: generation)
    let response: CoachAssistantResponse = try await stream(path: "assistant/stream", body: body, id: id, onUpdate: onUpdate)
    try response.validate(requestID: id, snapshot: snapshot)
    guard response.contract_version == 2, let actual = response.generation, actual.effort == generation.effort, actual.web_mode == generation.web_mode, actual.model == model else { throw MealAgentError.invalid }
    return response
  }
  public func analyzeStream(id: String, description: String, jpeg: Data?, consent: Bool, model: String, generation: CoachGenerationOptions, onUpdate: @escaping @MainActor (CoachStreamUpdate) -> Void) async throws -> MealAgentResult {
    guard consent, generation.valid, generation.web_mode == "off", description.count <= 3000,
      !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || jpeg != nil,
      jpeg.map({ $0.count <= 1_500_000 && $0.starts(with: [0xff, 0xd8, 0xff]) }) ?? true else { throw MealAgentError.input }
    struct Payload: Encodable { let request_id: String; let description: String; let image_jpeg_base64: String?; let consent = true; let model: String; let generation: CoachGenerationOptions }
    let body = try JSONEncoder().encode(Payload(request_id: id, description: description, image_jpeg_base64: jpeg?.base64EncodedString(), model: model, generation: generation))
    let response: MealAgentResult = try await stream(path: "meal/stream", body: body, id: id, onUpdate: onUpdate)
    try response.validate(expectedID: id)
    guard let actual = response.generation, actual.valid, actual.effort == generation.effort, actual.model == model, actual.web_mode == "off" else { throw MealAgentError.invalid }
    return response
  }
  private func stream<Output: Decodable>(path: String, body: Data, id: String, onUpdate: @escaping @MainActor (CoachStreamUpdate) -> Void) async throws -> Output {
    guard Self.validEndpoint(endpoint), token.count >= 32 else { throw MealAgentError.configuration }
    var request = URLRequest(url: endpoint.appendingPathComponent(path)); request.httpMethod = "POST"; request.httpBody = body
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept"); request.timeoutInterval = 45
    let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 320; config.httpShouldSetCookies = false; config.urlCache = nil
    let session = URLSession(configuration: config, delegate: MealNoRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw MealAgentError.invalid }
    if http.statusCode == 401 || http.statusCode == 403 { throw MealAgentError.unauthorized }
    if http.statusCode == 429 { throw MealAgentError.busy }
    guard http.statusCode == 200, http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true else { throw MealAgentError.unavailable }
    var decoder = CoachStreamDecoder<Output>(requestID: id), line = Data(), eventData = Data(), total = 0
    for try await byte in bytes {
      try Task.checkCancellation(); total += 1
      guard total <= 1_000_000, line.count < 256_000 else { throw MealAgentError.invalid }
      if byte != 10 { line.append(byte); continue }
      if line.last == 13 { line.removeLast() }
      guard let text = String(data: line, encoding: .utf8) else { throw MealAgentError.invalid }; line.removeAll(keepingCapacity: true)
      if text.isEmpty, !eventData.isEmpty {
        let event = try decoder.decode(eventData); eventData.removeAll(keepingCapacity: true)
        if let result = event.response, event.type == "result" { return result }
        if event.type == "status", let stage = event.stage { await onUpdate(.status(stage)) }
        if event.type == "message", let value = event.text { await onUpdate(.message(value)) }
      } else if text.hasPrefix("data:") {
        if !eventData.isEmpty { eventData.append(10) }
        eventData.append(contentsOf: text.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
        guard eventData.count <= 256_000 else { throw MealAgentError.invalid }
      }
    }
    throw CoachStreamError.failed("incomplete_response")
  }
}
