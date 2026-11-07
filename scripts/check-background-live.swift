import Foundation
import FitnessCore
@main struct BackgroundLiveCheck {
 @MainActor static func main() async throws {
  guard CommandLine.arguments.contains("--synthetic-only") else { fatalError("Synthetic-only required") }
  let token=String(decoding:FileHandle.standardInput.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
  let transport=MealAgentTransport(endpoint:URL(string:"https://39.96.23.222")!,token:token)
  let status=try await transport.status();guard status.assistant_features?.background_jobs == true else { throw CoachJobError.rejected(503) }
  if let flag=CommandLine.arguments.firstIndex(of:"--status"), CommandLine.arguments.count > flag+1, let id=UUID(uuidString:CommandLine.arguments[flag+1]) {
    let result=try await transport.jobStatus(id);print("JOB",result.state,"RESULT",result.assistant != nil,"ERROR",result.error ?? "none");return
  }
  var data=AppData();CoachThreads.prepare(&data)
  let text = CommandLine.arguments.contains("--seed") ? "软件合成测试：为离线笔记软件比较五种冲突合并策略，逐一分析断网、重复提交、进程退出和乱序返回时的失败边界，最后写一张简洁对比表。只讨论软件，不写入记录或记忆。" : "软件合成测试：用三句话解释网络请求的幂等机制，不写记忆或记录，不调用工具。"
  let bundle=PersonalAgentContext.build(data,text:text,health:false,memory:false), id=UUID()
  let options=CoachGenerationOptions(effort:CommandLine.arguments.contains("--seed") ? "max" : "high")
  let job=try transport.prepareJob(id:id,threadID:data.activeCoachThreadID!,deviceID:UUID(),text:text,jpeg:nil,bundle:bundle,history:[],health:false,memory:false,learning:false,model:"deepseek-flash",generation:options)
  if let flag=CommandLine.arguments.firstIndex(of:"--seed"), CommandLine.arguments.count > flag+1 {
    var turn=CoachTurn(text:text,reply:"",actions:[],origin:"AI · 合成后台测试");turn.threadID=data.activeCoachThreadID;turn.deliveryState="sending";turn.attemptID=id;turn.model="deepseek-flash";turn.generation=options;turn.remoteJob=job
    CoachThreads.record(turn,into:&data)
    let path=URL(fileURLWithPath:CommandLine.arguments[flag+1])
    try JSONEncoder().encode(data).write(to:path,options:.atomic)
    print("SEEDED",id.uuidString);return
  }
  let submitted=try await transport.submitJob(job)
  print("ACCEPTED",submitted.state,"no socket retained after POST")
  try await Task.sleep(nanoseconds:3_000_000_000)
  let duplicate=try await transport.submitJob(job);guard duplicate.job_id == id.uuidString else { throw MealAgentError.invalid }
  print("IDEMPOTENT same job")
  var final:CoachJobStatus?
  for _ in 0..<150 {
    let current=try await transport.jobStatus(id)
    if current.state == "completed" { final=current;break }
    if !["queued","running"].contains(current.state) { throw CoachStreamError.failed(current.error ?? current.state) }
    try await Task.sleep(nanoseconds:2_000_000_000)
  }
  guard let response=final?.assistant else { throw CoachStreamError.failed("timeout") }
  try response.validate(requestID:id.uuidString,snapshot:bundle.snapshot)
  guard response.generation?.model_calls == 1,(response.operations ?? []).isEmpty else { throw MealAgentError.invalid }
  print("PASS real background result after disconnected client; model calls",response.generation!.model_calls)
  try await transport.cleanupJob(CoachJobCleanup(job:job,action:"ack"))
  let ack=try await transport.jobStatus(id);guard ack.state == "acknowledged",ack.assistant == nil else { throw MealAgentError.invalid }
  print("PASS acknowledged result deleted")
  let stopID=UUID(), stopped=try transport.prepareJob(id:stopID,threadID:data.activeCoachThreadID!,deviceID:UUID(),text:text,jpeg:nil,bundle:bundle,history:[],health:false,memory:false,learning:false,model:"deepseek-flash",generation:options)
  try await transport.cleanupJob(CoachJobCleanup(job:stopped,action:"cancel"))
  guard try await transport.submitJob(stopped).state == "cancelled" else { throw MealAgentError.invalid }
  print("PASS cancel before late submission; no second model generation")
 }
}
