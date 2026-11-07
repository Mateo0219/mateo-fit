import Foundation
import FitnessCore

func runGenerationChecks() throws {
  func rejected(_ label: String, _ action: () throws -> Void) {
    do { try action(); fatalError("Accepted: " + label) } catch { check(true, label) }
  }
  for effort in CoachGenerationOptions.efforts { check(CoachGenerationOptions(effort: effort, webMode: "research").valid, "Generation accepts supported effort " + effort) }
  check(!CoachGenerationOptions(effort: "ultra").valid && !CoachGenerationOptions(webMode: "unrestricted").valid, "Unknown reasoning and web modes cannot expand capabilities")
  struct Output: Codable { let answer: String }
  func packet(_ sequence: Int, _ type: String, _ fields: [String:Any] = [:], id: String = "synthetic") throws -> Data {
    var event: [String:Any] = ["request_id":id,"sequence":sequence,"type":type]
    for (key,value) in fields { event[key]=value }
    return try JSONSerialization.data(withJSONObject:event)
  }
  var decoder=CoachStreamDecoder<Output>(requestID:"synthetic")
  let stage=try decoder.decode(packet(1,"status",["stage":"thinking"]))
  check(stage.stage=="thinking", "Stream reports provider processing without exposing raw reasoning")
  let partial=try decoder.decode(packet(2,"message",["text":"合成回答。"]));check(partial.text=="合成回答。", "Stream preserves Chinese response text")
  let final=try decoder.decode(packet(3,"result",["response":["answer":"合成结果"]]));check(final.response?.answer=="合成结果", "Only the terminal stream packet yields a complete response")
  rejected("Late stream packets are rejected after completion") { _ = try decoder.decode(packet(4,"message",["text":"迟到。"])); }
  var wrong=CoachStreamDecoder<Output>(requestID:"synthetic")
  rejected("Different request cannot update the active reply") { _ = try wrong.decode(packet(1,"status",["stage":"thinking"],id:"other")) }
  var duplicate=CoachStreamDecoder<Output>(requestID:"synthetic")
  _ = try duplicate.decode(packet(1,"status",["stage":"thinking"]))
  rejected("Repeated or out-of-order stream packet is rejected") { _ = try duplicate.decode(packet(1,"status",["stage":"thinking"])) }
  var falseSave=CoachStreamDecoder<Output>(requestID:"synthetic")
  rejected("Provisional stream cannot claim an unsaved record is saved") { _ = try falseSave.decode(packet(1,"message",["text":"已记住。"])); }
  var budget=CoachStreamDecoder<Output>(requestID:"synthetic")
  rejected("A budget error cannot turn into a success result") { _ = try budget.decode(packet(1,"error",["code":"budget_exhausted"])) }
  func source(_ url: String) throws -> CoachWebSource {
    try JSONDecoder().decode(CoachWebSource.self,from:JSONSerialization.data(withJSONObject:["id":"S1","title":"合成官方来源","url":url,"read":true]))
  }
  let publicSource = try source("https://www.who.int/example")
  check(publicSource.valid, "Public HTTPS source is a valid citation")
  for url in ["file:///etc/passwd","https://127.0.0.1","https://localhost","https://user:pass@example.com","https://private.local"] {
    let invalidSource = try source(url)
    check(!invalidSource.valid, "Non-public or credential-bearing citation is rejected")
  }
  var turn=CoachTurn(text:"合成研究任务",reply:"",actions:[]);turn.generation = .init(effort:"max",webMode:"research")
  let restored=try JSONDecoder().decode(CoachTurn.self,from:JSONEncoder().encode(turn))
  check(restored.generation==turn.generation && restored.valid, "Reasoning and research options persist with the original request for retry")
  let usage: [String:Any] = ["effort":"low","web_mode":"off","model":"deepseek-flash","model_calls":1,"search_calls":0,"fetch_calls":0,"prompt_tokens":100,"completion_tokens":20,"cache_hit_tokens":NSNull(),"reasoning_tokens":NSNull(),"elapsed_ms":1000,"reasoning_present":true]
  let decoded=try JSONDecoder().decode(CoachGenerationResult.self,from:JSONSerialization.data(withJSONObject:usage))
  check(decoded.valid && decoded.reasoning_tokens == nil && decoded.cache_hit_tokens == nil, "Unreported usage stays unknown rather than being filled with zero")
  var data=AppData()
  let bundle=PersonalAgentContext.build(data,text:"合成研究",health:false,memory:false)
  let raw: [String:Any] = ["contract_version":2,"request_id":"synthetic","snapshot_id":bundle.snapshot.snapshot_id,"expected_plan_version":bundle.snapshot.expected_plan_version,"status":"proposal","message":"合成结论。[S1]","questions":[],"cards":[],"operations":[],"citation_ids":["S1"],"sources":[["id":"S1","title":"合成官方来源","url":"https://www.who.int/example","read":true]],"generation":usage]
  let reply=try JSONDecoder().decode(CoachAssistantResponse.self,from:JSONSerialization.data(withJSONObject:raw))
  try reply.validate(requestID:"synthetic",snapshot:bundle.snapshot)
  var complete=CoachTurn(text:"合成研究",reply:reply.message,actions:[])
  complete.generation = .init(effort:"low");complete.exchange=CoachExchange(bundle:bundle,response:reply)
  CoachThreads.record(complete,into:&data)
  let restoredData=try JSONDecoder().decode(AppData.self,from:JSONEncoder().encode(data))
  let restoredTurn=restoredData.conversation!.last!
  check(restoredTurn.valid && restoredTurn.exchange?.response.sources?.first?.url == publicSource.url && restoredTurn.exchange?.response.generation?.reasoning_present == true, "Full saved chat restores verified sources and actual generation details")
  check(CoachReplyText.body(restoredTurn).contains("[S1](<https://www.who.int/example>)") && CoachReplyText.copy(restoredTurn,data:restoredData).contains("合成官方来源"), "Rendered and copied research replies retain verified source links")
}
