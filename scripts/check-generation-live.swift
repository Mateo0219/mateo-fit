import Foundation
import FitnessCore
@main struct GenerationLiveCheck {
  @MainActor static func main() async throws {
    guard CommandLine.arguments.contains("--synthetic-only") else { fatalError("Synthetic tests only") }
    let mode = CommandLine.arguments.last ?? "quick"
    let token=String(decoding:FileHandle.standardInput.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
    let transport=MealAgentTransport(endpoint:URL(string:"https://39.96.23.222")!,token:token)
    let status=try await transport.status()
    guard status.assistant_features?.streaming == true else { throw CoachStreamError.failed("capability_unavailable") }
    var data=AppData();CoachThreads.prepare(&data)
    let settings: CoachGenerationOptions
    let text: String
    switch mode {
    case "search": settings = .init(effort:"low",webMode:"search");text="软件合成测试：联网核实 DeepSeek 官方 Thinking 目前支持哪些思考强度，给出官方来源，不保存任何内容。"
    case "research": settings = .init(effort:"high",webMode:"research");text="软件合成测试：对照 DeepSeek 官方 Thinking 和 Search/Fetch 文档，研究如何给健身助理选择思考与联网模式。阅读原文后给出主要结论和来源，不修改计划，不写记忆。"
    case "cancel": settings = .init(effort:"max");text="软件合成测试：比较三种长期训练安排的适用情况，只讨论原则，不写记录。"
    case "photo": settings = .init(effort:"low");text="软件合成标签，实际吃了100g，请识读；未确认前不要保存。"
    default: settings = .init(effort:mode == "pro" ? "low" : mode);text="软件合成测试：只说一句你好，不记录或记住任何内容。"
    }
    let model=mode == "pro" ? "deepseek-v4-pro" : "deepseek-flash"
    var stages=[String](), previews=0
    let update: @MainActor (CoachStreamUpdate)->Void = { event in
      switch event {
      case .status(let stage): if stages.last != stage { stages.append(stage);print("STAGE",stage) }
      case .message: previews += 1
      }
    }
    if mode == "photo" {
      let jpeg=try Data(contentsOf:URL(fileURLWithPath:"../../work/v010-label.jpg"))
      let result=try await transport.analyzeStream(id:UUID().uuidString,description:text,jpeg:jpeg,consent:true,model:model,generation:settings,onUpdate:update)
      guard result.requires_confirmation,result.generation?.reasoning_present == true else { throw CoachStreamError.failed("missing_thinking") }
      print("PASS: actual vision + thinking; meal remains an unconfirmed estimate; model calls",result.generation!.model_calls)
      return
    }
    let bundle=PersonalAgentContext.build(data,text:text,health:false,memory:false)
    if mode == "cancel" {
      let task=Task { try await transport.respondStream(id:UUID().uuidString,text:text,history:[],snapshot:bundle.snapshot,health:false,memory:false,learning:false,model:model,generation:settings,onUpdate:update) }
      for _ in 0..<100 { if !stages.isEmpty { break }; try await Task.sleep(nanoseconds:100_000_000) }
      task.cancel()
      do { _ = try await task.value;throw CoachStreamError.failed("cancel_did_not_stop") }
      catch is CancellationError { print("PASS: in-flight stream cancelled; no final result or operation") }
      catch let error as URLError where error.code == .cancelled { print("PASS: URLSession cancelled in-flight request") }
      return
    }
    let result=try await transport.respondStream(id:UUID().uuidString,text:text,history:[],snapshot:bundle.snapshot,health:false,memory:false,learning:false,model:model,generation:settings,onUpdate:update)
    guard let actual=result.generation,(result.operations ?? []).isEmpty else { throw CoachStreamError.failed("unexpected_write") }
    guard settings.effort == "none" || actual.reasoning_present else { throw CoachStreamError.failed("missing_actual_thinking") }
    if settings.web_mode != "off" {
      guard actual.search_calls>0, !(result.sources ?? []).isEmpty else { throw CoachStreamError.failed("missing_actual_search") }
      if settings.web_mode == "research" { guard actual.fetch_calls>0, result.sources?.contains(where: { $0.read }) == true else { throw CoachStreamError.failed("missing_actual_read") } }
      print("ANSWER",result.message)
      print("SOURCES",(result.sources ?? []).map(\.url).joined(separator:" "))
    }
    if CommandLine.arguments.contains("--write-qa-fixture"), mode == "research" {
      var turn=CoachTurn(text:text,reply:result.message,actions:[],origin:"AI · 合成测试")
      turn.model=model;turn.generation=settings;turn.exchange=CoachExchange(bundle:bundle,response:result)
      data.conversation=[turn];CoachThreads.prepare(&data)
      try JSONEncoder().encode(data).write(to:URL(fileURLWithPath:"../../work/v010-live-research-fixture.json"),options:.atomic)
    }
    print("PASS: \(mode), model \(model), thinking \(actual.reasoning_present), streamed previews \(previews), model/search/fetch \(actual.model_calls)/\(actual.search_calls)/\(actual.fetch_calls)")
  }
}
