import Foundation
import FitnessCore

extension AppStore {
  func pendingMeal(in thread: UUID?) -> HomeMealDraft? {
    thread == data.activeCoachThreadID ? data.pendingHomeMeal : data.coachThreads?.first(where: { $0.id == thread })?.pendingMeal
  }
  @discardableResult func acceptRemoteJob(_ id: UUID) -> Bool {
    guard let i = data.conversation?.firstIndex(where: { $0.remoteJob?.id == id }) else { return false }
    if data.conversation?[i].remoteJob?.accepted == true { return true }
    return change { $0.conversation?[i].remoteJob?.accepted = true }
  }
  func clearJobCleanup(_ id: UUID) { _ = change { $0.coachJobCleanup?.removeAll { $0.id == id } } }

  @discardableResult func discardHomeMeal(id: UUID) -> Bool {
    guard let draft = data.pendingHomeMeal, draft.id == id else { return false }
    return change { data in
      if let source = draft.sourceTurnID, let i = data.conversation?.firstIndex(where: { $0.id == source }) {
        data.conversation?[i].reply = "已放弃这份餐食草稿，没有计入饮食记录。"
        data.conversation?[i].relatedMealID = nil
      }
      data.pendingHomeMeal = nil
    }
  }
  @discardableResult func beginCoachRequest(_ turn: CoachTurn) -> Bool {
    guard (data.conversation ?? []).filter({ $0.remoteJob != nil }).count < 4, turn.valid, turn.deliveryState == "sending", turn.attemptID != nil,
      !CoachThreads.turns(data).contains(where: { $0.deliveryState == "sending" }),
      !((data.conversation ?? []).contains { $0.id == turn.id }),
      turn.photo == nil || data.pendingHomeMeal == nil else { return false }
    return change {
      CoachThreads.record(turn, into: &$0)
      $0.homeComposer = HomeComposerDraft()
    }
  }
  @discardableResult func retryCoachRequest(turnID: UUID, attemptID: UUID, model: String, remoteJob: CoachRemoteJob? = nil) -> Bool {
    guard let i = data.conversation?.firstIndex(where: { $0.id == turnID }),
      let turn = data.conversation?[i], !turn.isComplete, turn.deliveryState != "sending",
      (turn.threadID ?? CoachThreads.legacyID) == (data.activeCoachThreadID ?? CoachThreads.legacyID),
      !CoachThreads.turns(data).contains(where: { $0.deliveryState == "sending" }),
      turn.photo == nil || data.pendingHomeMeal == nil else { return false }
    return change { $0.conversation?[i].attemptID = attemptID; $0.conversation?[i].deliveryState = "sending"; $0.conversation?[i].deliveryError = nil; $0.conversation?[i].model = model; $0.conversation?[i].remoteJob = remoteJob }
  }
  @discardableResult func stopCoachRequest(attemptID: UUID, error: String? = nil) -> Bool {
    guard let i = data.conversation?.firstIndex(where: { $0.attemptID == attemptID && $0.deliveryState == "sending" }) else { return false }
    return change { data in
      var turn = data.conversation![i]
      CoachBackgroundJobs.finish(&turn, data: &data, action: "cancel")
      turn.deliveryState = error == nil ? "stopped" : "failed"; turn.deliveryError = error.map { String($0.prefix(500)) }
      data.conversation?[i] = turn
    }
  }
  @discardableResult func finishCoachRequest(turnID: UUID, attemptID: UUID, exchange: CoachExchange) -> Bool {
    guard let i = data.conversation?.firstIndex(where: { $0.id == turnID && $0.attemptID == attemptID && $0.deliveryState == "sending" }),
      exchange.response.request_id == attemptID.uuidString else { return false }
    var turn = data.conversation![i]
    turn.reply = exchange.response.message; turn.exchange = exchange
    turn.actions = Array(Set(exchange.response.cards.map(\.action))).sorted { $0.rawValue < $1.rawValue }
    turn.deliveryState = nil; turn.attemptID = nil; turn.deliveryError = nil
    guard turn.valid else { return false }
    return change { $0.conversation?[i] = turn; TrainingSafety.observe(turn, in: &$0) }
  }
  @discardableResult func finishCoachMeal(turnID: UUID, attemptID: UUID, result: MealAgentResult) -> Bool {
    guard let i = data.conversation?.firstIndex(where: { $0.id == turnID && $0.attemptID == attemptID && $0.deliveryState == "sending" }),
      let turn = data.conversation?[i],
      pendingMeal(in: turn.threadID) == nil, (try? result.validate(expectedID: attemptID.uuidString)) != nil else { return false }
    var meal = HomeMealDraft(description: turn.text, photo: turn.photo, result: result)
    meal.sourceTurnID = turnID
    return change {
      if turn.threadID == $0.activeCoachThreadID { $0.pendingHomeMeal = meal }
      else if let t = $0.coachThreads?.firstIndex(where: { $0.id == turn.threadID }) { $0.coachThreads?[t].pendingMeal = meal }
      if let job = turn.remoteJob { CoachBackgroundJobs.enqueue(job, action: "ack", data: &$0) }
      $0.conversation?[i].remoteJob = nil
      $0.conversation?[i].reply = "已分析这餐，请核对下方的份量和结果。"
      $0.conversation?[i].relatedMealID = meal.id; $0.conversation?[i].photo = nil
      $0.conversation?[i].deliveryState = nil; $0.conversation?[i].attemptID = nil
    }
  }
}
