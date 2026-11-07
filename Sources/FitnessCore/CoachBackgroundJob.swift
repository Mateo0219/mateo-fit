import Foundation

/// A local outbox. Credentials stay in Keychain; only their digest is bound here.
public struct CoachRemoteJob: Codable {
  public var id: UUID
  public var createdAt = Date()
  public var endpoint: URL
  public var credentialHash: String
  public var body: Data
  public var bundle: CoachContextBundle?
  public var accepted = false
  public var health: Bool
  public var memory: Bool
  public var learning: Bool
  public var kind: String { bundle == nil ? "meal" : "assistant" }
  public var valid: Bool {
    guard MealAgentTransport.validEndpoint(endpoint), credentialHash.count == 64, body.count <= 2_110_000,
      let wrapper = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let payload = wrapper["request"] as? [String: Any], payload["request_id"] as? String == id.uuidString,
      wrapper["kind"] as? String == kind,
      UUID(uuidString: wrapper["thread_id"] as? String ?? "") != nil,
      UUID(uuidString: wrapper["device_id"] as? String ?? "") != nil else { return false }
    if let bundle {
      return bundle.fingerprint.count == 64 && bundle.snapshot.facts.count <= 64 && bundle.snapshot.candidates.count <= 4 &&
        (payload["snapshot"] as? [String: Any])?["snapshot_id"] as? String == bundle.snapshot.snapshot_id
    }
    return !health && !memory
  }
  public func memoryStillCurrent(_ data: AppData) -> Bool {
    guard let bundle else { return true }
    let facts = bundle.snapshot.facts.filter { $0.id.hasPrefix("memory.") }
    return facts.allSatisfy { fact in
      data.personalAgent?.memories.contains { memory in
        "memory." + memory.id.uuidString == fact.id && memory.active() && AssistantContext.digest(MemoryRules.summary(memory)) == fact.revision
      } == true
    } && (data.personalAgent?.historyAfter ?? .distantPast) <= createdAt
  }
  public func matches(_ transport: MealAgentTransport) -> Bool {
    endpoint == transport.endpoint && credentialHash == AssistantContext.digest(transport.token)
  }
}
public struct CoachJobCleanup: Codable, Identifiable {
  public var id: UUID
  public var endpoint: URL
  public var credentialHash: String
  public var action: String
  public var createdAt = Date()
  public init(job: CoachRemoteJob, action: String) { id = job.id; endpoint = job.endpoint; credentialHash = job.credentialHash; self.action = action }
  public var valid: Bool { MealAgentTransport.validEndpoint(endpoint) && credentialHash.count == 64 && ["ack", "cancel"].contains(action) }
  public func matches(_ transport: MealAgentTransport) -> Bool { endpoint == transport.endpoint && credentialHash == AssistantContext.digest(transport.token) }
}
public enum CoachBackgroundJobs {
  public static func enqueue(_ job: CoachRemoteJob, action: String, data: inout AppData) {
    var values = (data.coachJobCleanup ?? []).filter { $0.id != job.id && Date().timeIntervalSince($0.createdAt) < 172800 }
    values.append(CoachJobCleanup(job: job, action: action)); data.coachJobCleanup = values
  }
  public static func finish(_ turn: inout CoachTurn, data: inout AppData, action: String = "ack") {
    if let job = turn.remoteJob { enqueue(job, action: action, data: &data) }
    turn.remoteJob = nil
  }
  // Restoring a backup is not authorization to re-upload its old requests.
  public static func prepareRestore(_ next: inout AppData, current: AppData) {
    next.coachJobCleanup = current.coachJobCleanup
    for turn in (current.conversation ?? []) + (next.conversation ?? []) {
      if let job = turn.remoteJob { enqueue(job, action: "cancel", data: &next) }
    }
    for i in (next.conversation ?? []).indices where next.conversation?[i].remoteJob != nil {
      next.conversation?[i].remoteJob = nil; next.conversation?[i].deliveryState = "stopped"
    }
  }
}
public struct CoachJobStatus: Decodable {
  public let job_id: String
  public let kind: String
  public let state: String
  public let stage: String
  public let preview: String?
  public let error: String?
  public let assistant: CoachAssistantResponse?
  public let meal: MealAgentResult?
  enum CodingKeys: String, CodingKey { case job_id, kind, state, stage, preview, error, response }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    job_id = try c.decode(String.self, forKey: .job_id); kind = try c.decode(String.self, forKey: .kind)
    state = try c.decode(String.self, forKey: .state); stage = try c.decode(String.self, forKey: .stage)
    preview = try c.decodeIfPresent(String.self, forKey: .preview); error = try c.decodeIfPresent(String.self, forKey: .error)
    assistant = kind == "assistant" ? try c.decodeIfPresent(CoachAssistantResponse.self, forKey: .response) : nil
    meal = kind == "meal" ? try c.decodeIfPresent(MealAgentResult.self, forKey: .response) : nil
    guard ["assistant", "meal"].contains(kind), ["queued", "running", "completed", "failed", "cancelled", "acknowledged", "expired"].contains(state),
      (preview?.count ?? 0) <= 1800, !CoachReplyText.claimsUncommittedWrite(preview ?? "") else { throw MealAgentError.invalid }
  }
}
public enum CoachJobError: Error { case missing, rejected(Int) }
extension MealAgentTransport {
  public func prepareJob(id: UUID, threadID: UUID, deviceID: UUID, text: String, jpeg: Data?, bundle: CoachContextBundle?, history: [RouterHistory], health: Bool, memory: Bool, learning: Bool, model: String, generation: CoachGenerationOptions) throws -> CoachRemoteJob {
    guard generation.valid else { throw MealAgentError.input }
    let payload: Data
    if let bundle {
      payload = try assistantBody(id: id.uuidString, text: text, history: history, snapshot: bundle.snapshot, health: health, memory: memory, learning: learning, model: model, generation: generation)
    } else {
      guard let jpeg, jpeg.count <= 1_500_000, jpeg.starts(with: [0xff,0xd8,0xff]), text.count <= 3000, generation.web_mode == "off" else { throw MealAgentError.input }
      struct Meal: Encodable { let request_id: String; let description: String; let image_jpeg_base64: String; let consent = true; let model: String; let generation: CoachGenerationOptions }
      payload = try JSONEncoder().encode(Meal(request_id: id.uuidString, description: text, image_jpeg_base64: jpeg.base64EncodedString(), model: model, generation: generation))
    }
    let body = try JSONSerialization.data(withJSONObject: ["device_id":deviceID.uuidString, "thread_id":threadID.uuidString, "kind":bundle == nil ? "meal" : "assistant", "request":try JSONSerialization.jsonObject(with: payload)])
    let job = CoachRemoteJob(id: id, endpoint: endpoint, credentialHash: AssistantContext.digest(token), body: body, bundle: bundle, health: bundle != nil && health, memory: bundle != nil && memory, learning: learning)
    guard job.valid else { throw MealAgentError.input }; return job
  }
  public func jobStatus(_ id: UUID) async throws -> CoachJobStatus { try await jobRequest(path: "agent/jobs/" + id.uuidString, method: "GET") }
  public func submitJob(_ job: CoachRemoteJob) async throws -> CoachJobStatus {
    guard job.valid, job.matches(self) else { throw MealAgentError.configuration }
    return try await jobRequest(path: "agent/jobs", method: "POST", body: job.body)
  }
  public func cleanupJob(_ item: CoachJobCleanup) async throws {
    guard item.matches(self) else { throw MealAgentError.configuration }
    let _: CoachJobStatus = try await jobRequest(path: "agent/jobs/" + item.id.uuidString + (item.action == "ack" ? "/ack" : ""), method: item.action == "ack" ? "POST" : "DELETE")
  }
  private func jobRequest(path: String, method: String, body: Data? = nil) async throws -> CoachJobStatus {
    guard Self.validEndpoint(endpoint), token.count >= 32 else { throw MealAgentError.configuration }
    var request = URLRequest(url: endpoint.appendingPathComponent(path)); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 20
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 25; config.urlCache = nil; config.httpShouldSetCookies = false
    let session = URLSession(configuration: config, delegate: MealNoRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (stream, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw MealAgentError.invalid }
    if http.statusCode == 404 { throw CoachJobError.missing }
    guard http.statusCode == 200 else { throw CoachJobError.rejected(http.statusCode) }
    var bytes = Data()
    for try await byte in stream { try Task.checkCancellation(); guard bytes.count < 256_000 else { throw MealAgentError.invalid }; bytes.append(byte) }
    return try JSONDecoder().decode(CoachJobStatus.self, from: bytes)
  }
}
