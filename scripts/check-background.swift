import Foundation
import FitnessCore

@main struct BackgroundChecks {
 @MainActor static func main() throws {
  guard let dir = ProcessInfo.processInfo.environment["XUXU_DATA_DIR"], dir.contains("mateo-background-check-") else { fatalError("isolated records required") }
  let store = AppStore(); store.prepareCoachThreads()
  let transport = MealAgentTransport(endpoint: URL(string:"https://synthetic.example")!, token:String(repeating:"x", count:40))
  var passed = 0
  func check(_ ok: Bool, _ name: String) { precondition(ok,name); passed += 1; print("PASS: " + name) }
  func pending(_ text: String = "你好", photo: Bool = false, now: Date = Date()) throws -> CoachTurn {
    var turn = CoachTurn(text:text,reply:"",actions:[]); turn.deliveryState="sending";turn.attemptID=UUID();turn.model="deepseek-flash";turn.generation = .init(); turn.threadID=store.data.activeCoachThreadID
    let bundle = photo ? nil : PersonalAgentContext.build(store.data,text:text,health:false,memory:false,now:now)
    turn.photo = photo ? Data([0xff,0xd8,0xff,1]) : nil
    turn.remoteJob = try transport.prepareJob(id:turn.attemptID!,threadID:turn.threadID!,deviceID:UUID(),text:text,jpeg:turn.photo,bundle:bundle,history:[],health:false,memory:false,learning:true,model:turn.model!,generation:.init())
    precondition(store.beginCoachRequest(turn)); return turn
  }
  func response(_ turn: CoachTurn, operations: [[String:Any]] = []) throws -> CoachAssistantResponse {
    let snap = turn.remoteJob!.bundle!.snapshot
    let obj:[String:Any] = ["contract_version":2,"request_id":turn.attemptID!.uuidString,"snapshot_id":snap.snapshot_id,"expected_plan_version":snap.expected_plan_version,"status":"proposal","message":"合成回复","questions":[String](),"cards":[[String:String]](),"operations":operations]
    return try JSONDecoder().decode(CoachAssistantResponse.self,from:JSONSerialization.data(withJSONObject:obj))
  }
  let first = try pending()
  check(first.valid && !String(data:first.remoteJob!.body,encoding:.utf8)!.contains(transport.token),"Outbox valid; no connection credential in stored payload")
  let wrapper = try JSONSerialization.jsonObject(with:first.remoteJob!.body) as! [String:Any], request=wrapper["request"] as! [String:Any]
  check((request["consent_scope"] as! [String:Any])["health_summary"] as? Bool == false,"Health consent preserved in exact durable request")
  check(AppStore().data.conversation?.first?.deliveryState == "sending","App relaunch preserves remote job instead of stopping it")
  check(store.acceptRemoteJob(first.attemptID!),"Acceptance is durable")
  check(AppStore().data.conversation?.first?.remoteJob?.accepted == true,"Restart does not resubmit an accepted job")
  let owner=first.threadID!; _=store.newCoachThread(); _=store.saveComposer(text:"另一段未发送草稿",photo:nil)
  let answer=try response(first)
  check(store.finishPersonalRequest(turnID:first.id,attemptID:first.attemptID!,bundle:first.remoteJob!.bundle!,response:answer),"Inactive thread accepts its own background result")
  check(store.data.homeComposer?.text == "另一段未发送草稿" && store.data.activeCoachThreadID != owner,"Completion preserves current thread and next input")
  check(store.data.coachJobCleanup?.first?.action == "ack" && store.data.conversation?.first?.remoteJob == nil,"Reply and cleanup receipt commit atomically")
  check(!store.finishPersonalRequest(turnID:first.id,attemptID:first.attemptID!,bundle:first.remoteJob!.bundle!,response:answer),"Repeated completion is rejected")
  let second=try pending();let late=try response(second)
  check(store.stopCoachRequest(attemptID:second.attemptID!) && store.data.coachJobCleanup?.last?.action == "cancel","Stop durably queues server cancellation")
  check(!store.finishPersonalRequest(turnID:second.id,attemptID:second.attemptID!,bundle:second.remoteJob!.bundle!,response:late),"Cancelled result cannot reappear")
  let third=try pending();store.clearCurrentCoachConversation()
  check(store.data.coachJobCleanup?.contains(where:{$0.id == third.attemptID && $0.action == "cancel"}) == true,"Clear chat retains a cancellation outbox")
  let picture=try pending("合成照片",photo:true); let photoOwner=picture.threadID!; _=store.newCoachThread()
  let obj:[String:Any] = ["request_id":picture.attemptID!.uuidString,"title":"合成餐食","summary":"仅测试","questions":[String](),"limitations":[String](),"items":[[String:String]](),"totals":["energyKcal":NSNull(),"proteinG":NSNull(),"carbsG":NSNull(),"fatG":NSNull()],"requires_confirmation":true,"source":"AI 估计","catalog_version":"synthetic"]
  let meal=try JSONDecoder().decode(MealAgentResult.self,from:JSONSerialization.data(withJSONObject:obj))
  check(store.finishCoachMeal(turnID:picture.id,attemptID:picture.attemptID!,result:meal),"Photo analysis completes in its inactive thread")
  check(store.data.pendingHomeMeal == nil && store.data.meals.isEmpty,"Background photo is not an eaten meal and does not enter active thread")
  _=store.selectCoachThread(photoOwner)
  check(store.data.pendingHomeMeal?.photo == picture.photo,"Returning to source thread restores photo and pending estimate")
  _=store.newCoachThread()
  let memory=try pending("以后回答简短点")
  let operation:[String:Any] = ["kind":"remember","source_text":memory.text,"content":memory.text,"topic":"reply_style","evidence_ids":[String]()]
  check(store.finishPersonalRequest(turnID:memory.id,attemptID:memory.attemptID!,bundle:memory.remoteJob!.bundle!,response:try response(memory,operations:[operation])),"Background ordinary preference completes")
  check(store.data.personalAgent?.memories.contains(where:{$0.content == memory.text && $0.active()}) == true,"Cleanup receipt does not invalidate automatic preference save")
  let rememberedBundle=PersonalAgentContext.build(store.data,text:"今天怎么训练",health:false,memory:true)
  let rememberedJob=try transport.prepareJob(id:UUID(),threadID:store.data.activeCoachThreadID!,deviceID:UUID(),text:"今天怎么训练",jpeg:nil,bundle:rememberedBundle,history:[],health:false,memory:true,learning:false,model:"deepseek-flash",generation:.init())
  check(rememberedBundle.snapshot.facts.contains(where:{$0.id.hasPrefix("memory.")}) && rememberedJob.memoryStillCurrent(store.data),"Relevant memory revisions are bound to the background request")
  var forgotten=store.data;forgotten.personalAgent?.memories=[]
  check(!rememberedJob.memoryStillCurrent(forgotten),"Forgetting memory invalidates in-flight context immediately")
  var corrected=store.data;corrected.personalAgent?.memories[0].content="以后详细回答"
  check(!rememberedJob.memoryStillCurrent(corrected),"Corrected memory rejects a reply using its previous revision")
  let stale=try pending("我喜欢早上训练",now:Date().addingTimeInterval(-90000))
  let staleOp:[String:Any] = ["kind":"remember","source_text":stale.text,"content":stale.text,"topic":"general_preference","evidence_ids":[String]()]
  check(store.finishPersonalRequest(turnID:stale.id,attemptID:stale.attemptID!,bundle:stale.remoteJob!.bundle!,response:try response(stale,operations:[staleOp])),"Expired context can display its answer with a stale-context explanation")
  check(store.data.conversation?.last?.agentOperationIDs?.isEmpty == true && store.data.personalAgent?.memories.contains(where:{$0.content == stale.text}) == false,"Delayed result cannot renew old proposals or write memory")
  let failed=try pending()
  let path=URL(fileURLWithPath:store.storagePath).appendingPathComponent("records-v1.json"), preserved=path.appendingPathExtension("preserved")
  try FileManager.default.moveItem(at:path,to:preserved);try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false)
  check(!store.finishPersonalRequest(turnID:failed.id,attemptID:failed.attemptID!,bundle:failed.remoteJob!.bundle!,response:try response(failed)),"Atomic disk failure rejects result save")
  check(store.data.conversation?.last?.remoteJob != nil && store.data.coachJobCleanup?.contains(where:{$0.id == failed.attemptID}) != true,"Save failure retains pending job and never acknowledges server result")
  try FileManager.default.removeItem(at:path);try FileManager.default.moveItem(at:preserved,to:path)
  check(AppStore().data.conversation?.last?.remoteJob?.id == failed.attemptID,"Pending result recoverable after disk failure and restart")
  var restored=store.data;CoachBackgroundJobs.prepareRestore(&restored,current:store.data)
  check(restored.conversation?.last?.remoteJob == nil && restored.coachJobCleanup?.last?.action == "cancel","Backup restore cannot re-upload old health requests")
  let backup=try BackupCodec.decode(store.backupBytes())
  check(backup.records.conversation?.last?.remoteJob?.id == failed.attemptID,"Backup validator covers durable remote jobs")
  print("\(passed) background checks passed")
 }
}
