import Foundation
import FitnessCore

@main struct ChatInteractionChecks {
 @MainActor static func main() async throws {
  guard let directory = ProcessInfo.processInfo.environment["XUXU_DATA_DIR"], directory.contains("mateo-chat-check-") else { fatalError("Use isolated records") }
  let store = AppStore(), composer = CoachComposerDraft(delayNanoseconds: 30_000_000)
  var passed = 0
  func check(_ ok: Bool, _ name: String) { precondition(ok,name); passed += 1; print("PASS: "+name) }
  composer.restore(nil) { store.saveComposer(text:$0,photo:$1,state:$2) }
  composer.text = "第一条消息"
  if CommandLine.arguments.contains("--legacy") {
    _ = composer.flush(state:"sending")
    guard composer.text.isEmpty else { print("EXPECTED FAIL: accepted text remains in composer while waiting"); exit(2) }
  }
  func submit(_ text: String, photo: Data? = nil) -> CoachTurn {
    composer.text = text; composer.photo = photo
    var accepted: CoachTurn?
    let ok = composer.submit { text,photo in
      var turn = CoachTurn(text:text.isEmpty ? "餐食照片" : text,reply:"",actions:[])
      turn.deliveryState="sending";turn.attemptID=UUID();turn.photo=photo;turn.model="deepseek-flash"
      guard store.beginCoachRequest(turn) else { return false }
      accepted=CoachThreads.turns(store.data).last;return true
    }
    precondition(ok)
    return accepted!
  }
  func exchange(_ turn: CoachTurn, attempt: UUID? = nil) throws -> CoachExchange {
    let b=AssistantContext.build(store.data,text:turn.text,includeHealth:false)
    let object:[String:Any] = ["request_id":(attempt ?? turn.attemptID!).uuidString,"snapshot_id":b.snapshot.snapshot_id,"expected_plan_version":b.snapshot.expected_plan_version,"status":"insufficient_data","message":"合成回复","questions":[String](),"cards":[[String:String]]()]
    let response=try JSONDecoder().decode(CoachAssistantResponse.self,from:JSONSerialization.data(withJSONObject:object))
    return CoachExchange(bundle:b,response:response)
  }
  let first=submit("第一条消息")
  check(composer.text.isEmpty && composer.photo == nil && store.data.homeComposer?.text.isEmpty == true,"Accepted send clears the input immediately")
  check(CoachThreads.turns(store.data).last?.text == "第一条消息" && CoachThreads.turns(store.data).last?.deliveryState == "sending","Outgoing message is visible and durable before an AI reply")
  check(AssistantContext.history(CoachThreads.turns(store.data),includeHealth:true).isEmpty,"Unanswered messages are not invented assistant history")
  try await Task.sleep(nanoseconds:80_000_000)
  check(store.data.homeComposer?.text.isEmpty == true,"Old debounce cannot put submitted text back")
  composer.text="下一条尚未发送"; _=composer.flush()
  check(store.finishCoachRequest(turnID:first.id,attemptID:first.attemptID!,exchange:try exchange(first)),"Reply completes the original outgoing message")
  check(composer.text == "下一条尚未发送" && store.data.homeComposer?.text == composer.text,"Reply never clears the next draft")
  check(try CoachThreads.turns(store.data).count == 1 && !store.finishCoachRequest(turnID:first.id,attemptID:first.attemptID!,exchange:try exchange(first)),"Duplicate completion cannot duplicate the chat bubble")
  let failed=submit("第二条")
  composer.text="保留这个新草稿";_=composer.flush()
  check(store.stopCoachRequest(attemptID:failed.attemptID!,error:"合成断网") && composer.text == "保留这个新草稿","Failure marks the submitted message without overwriting new input")
  let retryID=UUID(), count=CoachThreads.turns(store.data).count
  check(store.retryCoachRequest(turnID:failed.id,attemptID:retryID,model:"deepseek-v4-pro") && CoachThreads.turns(store.data).count == count,"Retry reuses the bubble and captures the selected model")
  check(!store.finishCoachRequest(turnID:failed.id,attemptID:failed.attemptID!,exchange:try exchange(failed)),"Late previous-attempt reply is rejected")
  check(try store.stopCoachRequest(attemptID:retryID) && !store.finishCoachRequest(turnID:failed.id,attemptID:retryID,exchange:try exchange(failed,attempt:retryID)),"Stopped request cannot later execute or display a completed result")
  let owner=store.data.activeCoachThreadID!
  let switched=submit("切换时尚未完成")
  _=store.stopCoachRequest(attemptID:switched.attemptID!)
  _=store.newCoachThread()
  check(!store.finishCoachRequest(turnID:switched.id,attemptID:switched.attemptID!,exchange:try exchange(switched)) && CoachThreads.turns(store.data).isEmpty,"Switching chats isolates the stopped request from the new chat")
  _=store.selectCoachThread(owner)
  composer.restore(store.data.homeComposer) { store.saveComposer(text:$0,photo:$1,state:$2) }
  let image=submit("合成午饭",photo:Data([1,2,3]))
  check(composer.photo == nil && store.data.meals.isEmpty && CoachThreads.turns(store.data).last?.photo == Data([1,2,3]),"Sent photo moves into chat without becoming an actual meal")
  let resultObject:[String:Any] = ["request_id":image.attemptID!.uuidString,"title":"合成午饭","summary":"仅用于软件检查","questions":[String](),"limitations":[String](),"items":[[String:String]](),"totals":["energyKcal":NSNull(),"proteinG":NSNull(),"carbsG":NSNull(),"fatG":NSNull()],"requires_confirmation":true,"source":"AI 估计","catalog_version":"synthetic"]
  let meal=try JSONDecoder().decode(MealAgentResult.self,from:JSONSerialization.data(withJSONObject:resultObject))
  composer.text="图片分析时的新草稿";_=composer.flush()
  check(store.finishCoachMeal(turnID:image.id,attemptID:image.attemptID!,result:meal) && store.data.pendingHomeMeal?.photo == Data([1,2,3]) && composer.text == "图片分析时的新草稿","Photo result preserves the new draft and creates only a pending meal")
  let before=CoachThreads.turns(store.data).count, pending=store.data.pendingHomeMeal!
  check(store.confirmHomeMeal(pending) && store.data.meals.count == 1 && CoachThreads.turns(store.data).count == before,"Meal confirmation updates its existing message instead of duplicating a user bubble")
  check(!store.confirmHomeMeal(pending),"Repeated meal confirmation still saves only once")
  let discarded=submit("取消的合成午饭",photo:Data([4,5,6]))
  var discardedObject=resultObject; discardedObject["request_id"]=discarded.attemptID!.uuidString
  let discardedResult=try JSONDecoder().decode(MealAgentResult.self,from:JSONSerialization.data(withJSONObject:discardedObject))
  precondition(store.finishCoachMeal(turnID:discarded.id,attemptID:discarded.attemptID!,result:discardedResult))
  let discardedID=store.data.pendingHomeMeal!.id
  check(!store.discardHomeMeal(id:UUID()) && store.data.pendingHomeMeal?.id == discardedID,"Stale discard cannot remove another meal draft")
  check(store.discardHomeMeal(id:discardedID) && store.data.pendingHomeMeal == nil && store.data.meals.count == 1 && CoachThreads.turns(store.data).last?.reply.contains("没有计入") == true,"Discard updates the chat result without creating a meal")
  composer.text="不能丢失的草稿"
  check(!composer.submit(accept:{_,_ in false}) && composer.text == "不能丢失的草稿","Rejected submit preserves the input")
  let restart=submit("重启时的未完成消息")
  composer.text="重启后还要继续输入";_=composer.flush()
  let fresh=AppStore()
  check(fresh.data.conversation?.first(where:{$0.id == restart.id})?.deliveryState == "stopped" && fresh.data.homeComposer?.text == composer.text,"Restart restores pending messages separately from the next draft")
  let backup=try BackupCodec.decode(fresh.backupBytes())
  check(backup.records.conversation?.first(where:{$0.id == failed.id})?.model == "deepseek-v4-pro" && backup.records.conversation?.first(where:{$0.id == restart.id})?.deliveryState == "stopped","Backup preserves request state and selected-model provenance")
  let savedBytes=try JSONEncoder().encode(store.data), recordURL=URL(fileURLWithPath:store.storagePath).appendingPathComponent("records-v1.json")
  try Data("temporarily unreadable synthetic fixture".utf8).write(to:recordURL,options:.atomic)
  let delayedLoad=AppStore()
  try savedBytes.write(to:recordURL,options:.atomic)
  delayedLoad.retryProtectedLoad()
  check(delayedLoad.data.conversation?.first(where:{$0.id == restart.id})?.deliveryState == "stopped" && delayedLoad.data.homeComposer?.text == composer.text,"Delayed protected-data recovery cannot leave a request stuck sending")
  var pendingBackup=backup
  let restartIndex=pendingBackup.records.conversation!.firstIndex(where:{$0.id == restart.id})!
  pendingBackup.records.conversation?[restartIndex].deliveryState="sending"
  check(delayedLoad.restore(pendingBackup) && delayedLoad.data.conversation?.first(where:{$0.id == restart.id})?.deliveryState == "stopped","Restoring an in-flight backup offers retry instead of an endless spinner")
  composer.cancelPendingSave()
  print("\(passed) chat interaction checks passed")
 }
}
