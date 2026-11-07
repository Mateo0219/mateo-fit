import Foundation
import FitnessCore

@main struct ComposerChecks {
 @MainActor static func main() async throws {
  guard let directory = ProcessInfo.processInfo.environment["XUXU_DATA_DIR"], directory.contains("mateo-composer-check-") else { fatalError("Use isolated data") }
  let store = AppStore(), draft = CoachComposerDraft(delayNanoseconds: 80_000_000)
  var writes = 0, passed = 0
  func check(_ ok: Bool, _ label: String) { precondition(ok, label); passed += 1; print("PASS: "+label) }
  let writer: (String,Data?,String)->Bool = { text,photo,state in writes += 1; return store.saveComposer(text:text,photo:photo,state:state) }
  var original = HomeComposerDraft(); original.photo = Data(repeating:33,count:8_000_000)
  draft.restore(original, save:writer)
  check(writes == 0, "Restoring a photo draft performs no write")
  let started = Date()
  for i in 1...20 {
   let text = String(repeating:"测",count:i)
   if CommandLine.arguments.contains("--legacy") { _ = writer(text,original.photo,"editing") }
   else { draft.text = text }
  }
  print("20 edits main-thread milliseconds:",Date().timeIntervalSince(started)*1000)
  if CommandLine.arguments.contains("--legacy") {
   guard writes == 0 else { print("EXPECTED FAIL: typing caused \(writes) full-record writes"); exit(2) }
  }
  check(writes == 0, "Continuous typing never writes full records on the input path")
  try await Task.sleep(nanoseconds: 180_000_000)
  check(writes == 1 && AppStore().data.homeComposer?.text == String(repeating:"测",count:20), "A typing burst commits only its final text after a pause")
  check(AppStore().data.homeComposer?.photo == original.photo, "Debounced save preserves the original photo")
  draft.text = "马上发送"
  check(draft.flush(state:"sending") && AppStore().data.homeComposer?.state == "sending", "Send flushes current input before the network request")
  let sentWrites = writes
  try await Task.sleep(nanoseconds: 180_000_000)
  check(writes == sentWrites && store.data.homeComposer?.state == "sending", "Old debounce cannot overwrite sending state")
  draft.text = "返回后台前的最后一句"
  check(draft.flush(state:"interrupted") && AppStore().data.homeComposer?.text == draft.text, "Background or navigation flush saves the latest input immediately")
  draft.text = "不应在切换后保存"
  draft.cancelPendingSave()
  let cancelledWrites = writes
  try await Task.sleep(nanoseconds: 180_000_000)
  check(writes == cancelledWrites, "Cancelled draft cannot write after navigation")
  var next = HomeComposerDraft(); next.text = "另一段对话"
  draft.restore(next,save:writer)
  try await Task.sleep(nanoseconds: 180_000_000)
  check(writes == cancelledWrites && draft.text == next.text && draft.photo == nil, "Restoring another conversation cancels old pending input")
  print("\(passed) composer checks passed")
 }
}
