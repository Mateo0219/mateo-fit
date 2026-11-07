import Foundation
import FitnessCore

@main struct PersonalAgentLiveCheck {
  static func main() async throws {
    guard CommandLine.arguments.contains("--synthetic-only") else { fatalError("Synthetic tests only") }
    let token = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let transport = MealAgentTransport(endpoint: URL(string: "https://39.96.23.222")!, token: token)
    let status = try await transport.status()
    guard status.assistant_contract_versions?.contains(2) == true else { fatalError("V2 not deployed") }
    print("PASS: HTTPS advertises V1 + V2; models: " + (status.models ?? []).map(\.name).joined(separator: " / "))
    var data = AppData(); data.personalAgent = PersonalAgentState(); CoachThreads.prepare(&data)
    var preferences = CoachPreferences(); preferences.confirmedAt = Date(); preferences.experience = "练过"; preferences.equipment = "器械与哑铃"; preferences.restrictions = "没有已知限制"; preferences.trainingWeekdays = Set(1...7)
    var coach = CoachState(); coach.preferences = preferences; var today = DailyCheckIn(); today.energy = "状态正常"; today.minutes = 60; coach.checkIn = today; data.coach = coach
    data.draft = WorkoutDraft(); data.draft?.planned = [PlannedExercise("row", sets: 3)]
    func run(_ text: String, expected: String, health: Bool = true) async throws {
      let bundle = PersonalAgentContext.build(data, text: text, health: health, memory: false)
      let response = try await transport.respondV2(id: UUID().uuidString, text: text, history: PersonalAgentContext.history(data, health: health, memory: false), snapshot: bundle.snapshot, health: health, memory: false, learning: true, model: status.model)
      guard let input = response.operations?.first(where: { $0.kind == expected }) else { throw AgentOperationError.rejected("Expected \(expected); got \(response.operations?.map(\.kind) ?? []), \(response.message), \(response.questions)") }
      var turn = CoachTurn(text: text, reply: response.message, actions: []); turn.threadID = data.activeCoachThreadID
      let operation = try AgentOperations.stage(input, turn: turn, data: data, allowedTargets: Set(bundle.snapshot.facts.map(\.id)))
      turn.agentOperationIDs = [operation.id]; CoachThreads.record(turn, into: &data); data.personalAgent?.operations.append(operation)
      try AgentOperations.commit(operation.id, data: &data)
      print("PASS: Live synthetic \(expected) validated and committed to isolated in-memory data")
    }
    try await run("软件合成测试：刚做了推胸20kg，10次，一组，帮我记录实际表现。", expected: "logSet", health: false)
    try await run("软件合成测试：刚才那组重量写错了，是22kg，帮我更正原组。", expected: "correctSet")
    try await run("软件合成测试：今天只有四十分钟，调整当天时间。", expected: "updateToday")
    // The current plan is recomputed by local rules; choose an actual remaining item.
    if let item = data.draft?.planned?.first(where: { $0.exerciseID == "row" }) {
      let label = TrainingLibrary.guide(item.exerciseID)!.name
      try await run("软件合成测试：\(label)的器械被占了，换成可用的支撑式哑铃划船。", expected: "substituteExercise")
    } else { throw AgentOperationError.rejected("Synthetic adjusted plan has no row to substitute") }
    try await run("软件合成测试：今天吃了鸡蛋两个，记录这餐。", expected: "logMeal", health: false)
    guard data.draft?.sets.count == 1, data.draft?.sets[0].kg == 22, data.meals.count == 1 else { fatalError("Wrong real result") }
    print("PASS: Actual local results preserve completed sets; official meals saved once with unknown nutrition")
  }
}
