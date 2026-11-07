import Foundation
import SwiftUI
import FitnessCore

@main struct ComposerEvents {
 @MainActor static func main() async throws {
  let draft=CoachComposerDraft(delayNanoseconds:10_000_000)
  var saved="",count=0
  func check(_ value:Bool,_ name:String) { guard value else { print("FAIL: "+name);exit(2) };count += 1;print("PASS: "+name) }
  draft.restore(nil) { text,_,_ in saved=text;return true }
  // Mirrors a text control retaining its binding for an edit/IME callback that
  // was queued before send. No timers or model calls are needed to expose it.
  let editor = CommandLine.arguments.contains("--legacy") ? Binding<String>(get:{draft.text},set:{draft.text=$0}) : draft.editorText
  editor.wrappedValue="软件合成测试：这是一条跨多行的中文消息，发送后不能继续留在输入框。"
  let sent=editor.wrappedValue
  check(draft.submit { _,_ in saved="";return true },"Local acceptance succeeds")
  check(draft.text.isEmpty,"Logical draft clears at send")
  editor.wrappedValue=sent
  try await Task.sleep(nanoseconds:30_000_000)
  check(draft.text.isEmpty && saved.isEmpty,"Delayed native text callback cannot restore submitted input")
  let nextEditor=draft.editorText
  nextEditor.wrappedValue="等待回复期间的新草稿"
  editor.wrappedValue=sent
  check(draft.text == "等待回复期间的新草稿","Old editor cannot overwrite a genuinely new draft")
  check(draft.flush() && saved == draft.text,"Background flush persists the new draft only")
  let restored=HomeComposerDraft();draft.restore(restored) { text,_,_ in saved=text;return true }
  nextEditor.wrappedValue="已离开的会话文字"
  check(draft.text.isEmpty,"Restoring a conversation retires old text-control callbacks")
  let current=draft.editorText;current.wrappedValue="发送失败应保留"
  let revision=draft.editorRevision
  check(!draft.submit { _,_ in false } && draft.text == "发送失败应保留" && draft.editorRevision == revision,"Rejected send preserves input and its active editor")
  current.wrappedValue="失败后继续编辑"
  check(draft.text == "失败后继续编辑","Editor remains writable after a rejected send")
  var emissions=0
  let subscription=draft.objectWillChange.sink { emissions += 1 }
  current.wrappedValue="新的中文候选文本"
  check(draft.editorRevision == revision && emissions == 1,"Keystrokes do not recreate the text control or rescan history")
  subscription.cancel()
  for _ in 0..<100 {
    let field=draft.editorText;field.wrappedValue="快速发送测试"
    precondition(draft.submit { _,_ in saved="";return true })
    field.wrappedValue="快速发送测试"
    precondition(draft.text.isEmpty)
  }
  check(draft.text.isEmpty && saved.isEmpty,"100 repeated send/late-event cycles keep the composer empty")
  print("\(count) composer event checks passed")
 }
}
