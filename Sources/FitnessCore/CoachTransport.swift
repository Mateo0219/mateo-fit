import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Optional proposal transport. The shipping local UI does not instantiate this client.
/// Keep the short-lived client token in Keychain when wiring device configuration.
public struct CoachTransport {
  public let endpoint: URL
  public let clientToken: String
  public init(endpoint: URL, clientToken: String) {
    self.endpoint = endpoint
    self.clientToken = clientToken
  }
  public struct Evidence: Codable {
    public let id: String
    public let summary: String
    public let source: String
    public let observedAt: Date
    public init(id: String, summary: String, source: String, observedAt: Date) {
      self.id = id
      self.summary = summary
      self.source = source
      self.observedAt = observedAt
    }
  }
  private struct Payload: Encodable {
    let mode: String
    let consent: Bool
    let snapshot_id: String
    let expected_plan_version: String?
    let question: String
    let evidence: [Evidence]
  }
  public func propose(
    mode: String, snapshotID: String, planVersion: String?, question: String,
    evidence: [Evidence], consent: Bool
  ) async throws -> CoachReply {
    guard consent else { throw CoachError.noConsent }
    guard endpoint.scheme == "https", !clientToken.isEmpty else { throw CoachError.notConfigured }
    let payload = Payload(
      mode: mode, consent: consent, snapshot_id: snapshotID,
      expected_plan_version: planVersion, question: question, evidence: evidence)
    var request = URLRequest(url: endpoint.appendingPathComponent("coach"))
    request.httpMethod = "POST"
    request.setValue("Bearer " + clientToken, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 45
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    request.httpBody = try encoder.encode(payload)
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    let (bytes, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      bytes.count <= 256_000
    else { throw CoachError.invalid }
    let reply = try JSONDecoder().decode(CoachReply.self, from: bytes)
    try reply.validate(expectedSnapshot: snapshotID, allowedEvidence: Set(evidence.map(\.id)))
    guard reply.expected_plan_version == planVersion, reply.mode == mode else {
      throw CoachError.stale
    }
    return reply
  }
}
