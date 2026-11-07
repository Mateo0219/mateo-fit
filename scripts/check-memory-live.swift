import Foundation
import FitnessCore
@main struct MemoryLiveCheck {
  static func main() async throws {
    guard CommandLine.arguments.contains("--synthetic-only") else { fatalError("Synthetic tests only") }
    let token = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let transport = MealAgentTransport(endpoint: URL(string: "https://39.96.23.222")!, token: token)
    let status = try await transport.status()
    for model in status.models ?? [] {
      var data = AppData(); data.personalAgent = PersonalAgentState(); CoachThreads.prepare(&data)
      let text = "软件合成测试：请记住，我对花生过敏。"
      let bundle = PersonalAgentContext.build(data, text: text, health: false, memory: false)
      let reply = try await transport.respondV2(id: UUID().uuidString, text: text, history: [], snapshot: bundle.snapshot, health: false, memory: false, learning: true, model: model.id)
      guard !CoachReplyText.claimsUncommittedWrite(reply.message), reply.message.count < 180, reply.cards.isEmpty,
        let input = reply.operations?.first(where: { $0.kind == "remember" && $0.topic == "health_constraint" }) else { throw AgentOperationError.rejected("Memory proposal or concise reply missing for " + model.name) }
      var turn = CoachTurn(text: text, reply: reply.message, actions: []); turn.threadID = data.activeCoachThreadID
      let op = try AgentOperations.stage(input, turn: turn, data: data, allowedTargets: Set(bundle.snapshot.facts.map(\.id)))
      turn.agentOperationIDs = [op.id]; CoachThreads.record(turn, into: &data); data.personalAgent?.operations.append(op)
      guard data.personalAgent!.memories.isEmpty else { fatalError("Saved before confirmation") }
      try AgentOperations.commit(op.id, data: &data)
      guard data.personalAgent!.memories.count == 1 else { fatalError("Missing confirmed memory") }
      print("PASS: \(model.name): concise \(reply.message.count)-character reply, structured memory, actual isolated confirmation")
    }
    let data = AppData(), text = "软件合成测试：你好。"
    let bundle = PersonalAgentContext.build(data, text: text, health: false, memory: false)
    let reply = try await transport.respondV2(id: UUID().uuidString, text: text, history: [], snapshot: bundle.snapshot, health: false, memory: false, learning: true, model: status.model)
    guard reply.message.count < 180, reply.cards.isEmpty, (reply.operations ?? []).isEmpty else { throw AgentOperationError.rejected("Greeting contains unnecessary action or oversized reply") }
    print("PASS: greeting has \(reply.message.count) characters and no filler cards")
  }
}
