import Foundation
import FitnessCore

extension AppStore {
  @discardableResult func commitAgentOperation(_ id: UUID) -> Bool {
    var next = data
    do { try AgentOperations.commit(id, data: &next) }
    catch { alert = error.localizedDescription; return false }
    return change { $0 = next }
  }
  @discardableResult func undoAgentOperation(_ id: UUID) -> Bool {
    var next = data
    do { try AgentOperations.undo(id, data: &next) }
    catch { alert = error.localizedDescription; return false }
    return change { $0 = next }
  }
  func cancelAgentOperation(_ id: UUID) {
    guard let index = data.personalAgent?.operations.firstIndex(where: { $0.id == id && $0.status == "pending" }) else { return }
    _ = change { $0.personalAgent?.operations[index].status = "cancelled" }
  }
  @discardableResult func editAgentOperation(_ id: UUID, input: AgentOperationInput) -> Bool {
    guard let index = data.personalAgent?.operations.firstIndex(where: { $0.id == id && $0.status == "pending" }), var op = data.personalAgent?.operations[index] else { return false }
    // Editing may refresh a proposal only after presenting current before/after values.
    op.input = input; op.edited = true; op.fingerprint = AssistantContext.fingerprint(data); op.createdAt = Date(); op.timezone = TimeZone.current.identifier
    do { op.summary = try AgentOperations.preview(op, data: data) }
    catch { alert = error.localizedDescription; return false }
    return change { $0.personalAgent?.operations[index] = op }
  }
  func setNoLongTermMemory(_ disabled: Bool) {
    guard let i = data.coachThreads?.firstIndex(where: { $0.id == data.activeCoachThreadID }) else { return }
    _ = change { $0.coachThreads?[i].noLongTermMemory = disabled }
  }
  @discardableResult func finishPersonalRequest(turnID: UUID, attemptID: UUID, bundle: CoachContextBundle, response: CoachAssistantResponse) -> Bool {
    guard let index = data.conversation?.firstIndex(where: { $0.id == turnID && $0.attemptID == attemptID && $0.deliveryState == "sending" }), response.request_id == attemptID.uuidString else { return false }
    var next = data, turn = data.conversation![index]
    let targets = Set(bundle.snapshot.facts.map(\.id))
    do {
      try response.validate(requestID: attemptID.uuidString, snapshot: bundle.snapshot)
      guard !CoachReplyText.claimsUncommittedWrite(response.message),
        !response.cards.contains(where: { CoachReplyText.claimsUncommittedWrite($0.detail) }) else {
        throw AgentOperationError.rejected("这次回复没有真实保存结果。内容尚未保存，请重试。")
      }
      if next.personalAgent == nil { next.personalAgent = PersonalAgentState() }
      var ops: [AgentOperation] = []
      let sentAt = ISO8601DateFormatter().date(from: bundle.snapshot.generated_at) ?? turn.date
      let canStage = turn.remoteJob == nil || (bundle.fingerprint == AssistantContext.fingerprint(next) && Calendar.current.isDateInToday(sentAt) && bundle.snapshot.timezone == TimeZone.current.identifier && Date().timeIntervalSince(sentAt) < 86400)
      for input in canStage ? (response.operations ?? []) : [] {
        var op = try AgentOperations.stage(input, turn: turn, data: next, allowedTargets: targets)
        op.fingerprint = bundle.fingerprint
        if turn.remoteJob != nil { op.createdAt = ISO8601DateFormatter().date(from: bundle.snapshot.generated_at) ?? turn.date }
        ops.append(op)
      }
      if !canStage { turn.outcome = "回复基于发送时的资料；当前记录或日期已变化，旧操作未采用，请重新评估。" }
      turn.reply = response.message; turn.exchange = CoachExchange(bundle: bundle, response: response)
      turn.actions = Array(Set(response.cards.map(\.action))).sorted { $0.rawValue < $1.rawValue }
      turn.deliveryState = nil; turn.attemptID = nil; turn.deliveryError = nil; turn.agentOperationIDs = ops.map(\.id)
      turn.requiresMemoryConsent = bundle.snapshot.facts.contains { $0.id.hasPrefix("memory.") } || ops.contains { AgentOperations.scope($0.input.kind) == "memory" }
      turn.requiresSummaryConsent = bundle.snapshot.facts.contains { !$0.id.hasPrefix("memory.") && !$0.id.hasPrefix("public.") } || ops.contains { AgentOperations.scope($0.input.kind) != "memory" }
      CoachBackgroundJobs.finish(&turn, data: &next)
      guard turn.valid else { return false }
      next.conversation?[index] = turn
      TrainingSafety.observe(turn, in: &next)
      next.personalAgent?.operations += ops
      if next.coachThreads?.first(where: { $0.id == turn.threadID })?.noLongTermMemory != true, ops.count == 1, let op = ops.first, MemoryRules.canAutoRemember(op.input, data: next, turn: turn), AgentOperations.fresh(op, data: next) {
        try AgentOperations.commit(op.id, data: &next)
        next.conversation?[index].reply = "已记住。"
      }
      return change { $0 = next }
    } catch { alert = error.localizedDescription; return false }
  }
  // Deterministic commands also work offline and never upload local memory.
  func handlesLocalAgentText(_ text: String) -> Bool {
    ["你记住了我什么", "你记住了我什么？", "查看记忆", "我的记忆", "撤销上次操作", "撤销刚才的操作"].contains(text) || MemoryRules.localInput(text) != nil
  }
  @discardableResult func submitLocalAgentText(_ text: String) -> Bool {
    var next = data
    if next.personalAgent == nil { next.personalAgent = PersonalAgentState() }
    var turn = CoachTurn(text: text, reply: "", actions: [], origin: "本机结果")
    turn.threadID = data.activeCoachThreadID ?? CoachThreads.legacyID
    if ["撤销上次操作", "撤销刚才的操作"].contains(text) {
      guard let id = next.personalAgent?.receipts.last(where: { !$0.undone })?.id else { alert = "没有可撤销的操作。"; return false }
      do { try AgentOperations.undo(id, data: &next) } catch { alert = error.localizedDescription; return false }
      turn.reply = "已撤销最近一次操作，恢复了修改前的数据。"; turn.requiresSummaryConsent = true; turn.requiresMemoryConsent = true
      CoachThreads.record(turn, into: &next)
    } else if let input = MemoryRules.localInput(text) {
      if data.coachThreads?.first(where: { $0.id == turn.threadID })?.noLongTermMemory == true {
        turn.reply = "本次会话不形成长期记忆，这句话不会保存为记忆。"; CoachThreads.record(turn, into: &next)
      } else {
        turn.reply = "请核对这条记忆。"; turn.requiresMemoryConsent = true
        do {
          let op = try AgentOperations.stage(input, turn: turn, data: next)
          turn.agentOperationIDs = [op.id]; CoachThreads.record(turn, into: &next); next.personalAgent?.operations.append(op)
          if MemoryRules.canAutoRemember(input, data: next, turn: turn) {
            try AgentOperations.commit(op.id, data: &next)
            if let i = next.conversation?.firstIndex(where: { $0.id == turn.id }) { next.conversation?[i].reply = "已记住。" }
          }
        } catch { alert = error.localizedDescription; return false }
      }
    } else {
      let memories = next.personalAgent?.memories.filter { $0.active() } ?? []
      turn.reply = memories.isEmpty ? "还没有有效的长期记忆。你可以直接说“记住……”；也可以从侧栏打开记忆管理。" : "我当前记住了：\n" + memories.prefix(15).map { "• " + $0.content }.joined(separator: "\n") + "\n可从侧栏查看来源、修改或忘记。"
      turn.requiresMemoryConsent = true; CoachThreads.record(turn, into: &next)
    }
    next.homeComposer = HomeComposerDraft()
    return change { $0 = next }
  }
  @discardableResult func manageMemory(_ input: AgentOperationInput, source: String) -> Bool {
    var next = data
    if next.personalAgent == nil { next.personalAgent = PersonalAgentState() }
    var turn = CoachTurn(text: source, reply: "记忆管理", actions: [], origin: "本机结果")
    turn.threadID = data.activeCoachThreadID ?? CoachThreads.legacyID; turn.requiresMemoryConsent = true
    do {
      // The management form is an explicit local user edit, not model output.
      var op = AgentOperation(turnID: turn.id, input: input, fingerprint: AssistantContext.fingerprint(next), summary: "", grounding: source)
      op.edited = true; op.summary = try AgentOperations.preview(op, data: next)
      turn.agentOperationIDs = [op.id]; CoachThreads.record(turn, into: &next); next.personalAgent?.operations.append(op)
      try AgentOperations.commit(op.id, data: &next)
      return change { $0 = next }
    } catch { alert = error.localizedDescription; return false }
  }
}
