import Foundation
import SwiftUI
import FitnessCore
#if os(iOS)
import UIKit
#endif

/// Owned by the app root, never by a conversation or sheet. Backgrounding only
/// detaches polling; accepted work belongs to the server until cancel/expiry.
@MainActor final class RemoteCoachCoordinator: ObservableObject {
  struct Progress { var title: String; var preview = "" }
  @Published var progress: [UUID: Progress] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var tickets: [UUID: UUID] = [:]
  private var blocked: Set<UUID> = []
  private var supervisor: Task<Void, Never>?
  private var active = true
  #if os(iOS)
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  #endif
  static var deviceID: UUID {
    let defaults = UserDefaults.standard
    if let value = defaults.string(forKey: "coach.jobDeviceID"), let id = UUID(uuidString: value) { return id }
    let id = UUID(); defaults.set(id.uuidString, forKey: "coach.jobDeviceID"); return id
  }
  func resume(_ store: AppStore) {
    active = true; blocked.removeAll(); endGrace()
    if supervisor == nil {
      supervisor = Task { @MainActor [weak self, weak store] in
        while !Task.isCancelled {
          guard let self, let store else { return }
          self.reconcile(store)
          try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
      }
    }
    reconcile(store)
  }
  func background() {
    active = false
    // A short OS-granted window finishes in-flight submission only. Generation
    // does not depend on this window, an iOS timer, or an open socket.
    #if os(iOS)
    if backgroundTask == .invalid {
      backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Submit coach request") { [weak self] in
        Task { @MainActor in self?.pausePolling() }
      }
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        if self?.active == false { self?.pausePolling() }
      }
    }
    #endif
  }
  private func endGrace() {
    #if os(iOS)
    if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    #endif
  }
  private func pausePolling() {
    supervisor?.cancel(); supervisor = nil
    for task in tasks.values { task.cancel() }
    tasks.removeAll(); tickets.removeAll(); endGrace()
  }
  func cancel(_ id: UUID, store: AppStore) {
    guard store.stopCoachRequest(attemptID: id) else { return }
    tasks[id]?.cancel(); tasks[id] = nil; progress[id] = nil
    reconcile(store)
  }
  func reconcile(_ store: AppStore) {
    guard let transport = AgentConnection.load().transport else { return }
    let health = UserDefaults.standard.bool(forKey: "coach.includeHealthSummary")
    let memory = UserDefaults.standard.bool(forKey: "coach.includeMemorySummary")
    for turn in store.data.conversation ?? [] {
      guard let job = turn.remoteJob else { continue }
      let learningRevoked = job.learning && store.data.coachThreads?.first(where: { $0.id == turn.threadID })?.noLongTermMemory == true
      if (job.health && !health) || (job.memory && !memory) || learningRevoked || !job.memoryStillCurrent(store.data) {
        _ = store.stopCoachRequest(attemptID: job.id, error: "相关授权已关闭，任务已停止。")
        tasks[job.id]?.cancel(); tasks[job.id] = nil
        continue
      }
      guard job.matches(transport) else {
        _ = store.stopCoachRequest(attemptID: job.id, error: "连接已变化，旧任务不会上传到新服务；旧服务临时内容会在 24 小时内清理。")
        tasks[job.id]?.cancel(); tasks[job.id] = nil
        continue
      }
      guard !blocked.contains(job.id), tasks[job.id] == nil else { continue }
      let ticket = UUID(); tickets[job.id] = ticket
      tasks[job.id] = Task { @MainActor [weak self, weak store] in
        guard let self, let store else { return }
        defer { if self.tickets[job.id] == ticket { self.tasks[job.id] = nil; self.tickets[job.id] = nil } }
        await self.follow(turnID: turn.id, job: job, transport: transport, store: store)
      }
    }
    for item in store.data.coachJobCleanup ?? [] where tasks[item.id] == nil && !blocked.contains(item.id) {
      guard item.matches(transport) else { continue }
      let ticket = UUID(); tickets[item.id] = ticket
      tasks[item.id] = Task { @MainActor [weak self, weak store] in
        guard let self, let store else { return }
        defer { if self.tickets[item.id] == ticket { self.tasks[item.id] = nil; self.tickets[item.id] = nil } }
        do { try await transport.cleanupJob(item); store.clearJobCleanup(item.id) }
        catch CoachJobError.missing { store.clearJobCleanup(item.id) }
        catch { self.blocked.insert(item.id) } // Retried on foreground/reconnect, never regenerate.
      }
    }
  }
  private func follow(turnID: UUID, job: CoachRemoteJob, transport: MealAgentTransport, store: AppStore) async {
    var submitted = job.accepted
    var transientFailures = 0
    while !Task.isCancelled {
      guard let turn = store.data.conversation?.first(where: { $0.id == turnID && $0.remoteJob?.id == job.id }), let current = turn.remoteJob else { return }
      do {
        let result: CoachJobStatus
        do { result = try await transport.jobStatus(job.id) }
        catch CoachJobError.missing {
          guard !submitted, Date().timeIntervalSince(job.createdAt) < 600 else {
            _ = store.stopCoachRequest(attemptID: job.id, error: "任务已过期或未能提交，原消息保留；可手动重试。")
            return
          }
          progress[job.id] = .init(title: "正在提交…")
          result = try await transport.submitJob(current)
        }
        try Task.checkCancellation()
        guard result.job_id == job.id.uuidString else { throw MealAgentError.invalid }
        submitted = true
        guard store.acceptRemoteJob(job.id) else { blocked.insert(job.id); return }
        transientFailures = 0
        switch result.state {
        case "queued", "running":
          let names = ["thinking":"正在思考…", "responding":"正在回复…", "searching":"正在搜索…", "reading":"正在阅读来源…", "summarizing":"正在整理结论…"]
          progress[job.id] = .init(title: result.state == "queued" ? "已提交，排队中…" : (names[result.stage] ?? "正在处理…"), preview: result.preview ?? "")
          if !active { return }
        case "completed":
          // Recheck local authorization after every await, before accepting results.
          guard let currentTransport = AgentConnection.load().transport, job.memoryStillCurrent(store.data), job.matches(currentTransport), (!job.health || UserDefaults.standard.bool(forKey: "coach.includeHealthSummary")), (!job.memory || UserDefaults.standard.bool(forKey: "coach.includeMemorySummary")),
            !job.learning || store.data.coachThreads?.first(where: { $0.id == turn.threadID })?.noLongTermMemory != true else {
            _ = store.stopCoachRequest(attemptID: job.id, error: "相关授权已关闭，结果未采用。"); return
          }
          let saved: Bool
          if let bundle = job.bundle, let response = result.assistant {
            try response.validate(requestID: job.id.uuidString, snapshot: bundle.snapshot)
            try validateGeneration(response.generation, turn: turn)
            saved = store.finishPersonalRequest(turnID: turnID, attemptID: job.id, bundle: bundle, response: response)
          } else if job.bundle == nil, let response = result.meal {
            try response.validate(expectedID: job.id.uuidString); try validateGeneration(response.generation, turn: turn)
            saved = store.finishCoachMeal(turnID: turnID, attemptID: job.id, result: response)
          } else { throw MealAgentError.invalid }
          if !saved { progress[job.id] = .init(title: "结果尚未存入本机，返回 App 后重试保存"); blocked.insert(job.id) }
          else { progress[job.id] = nil }
          return
        default:
          let reason = ["server_restarted":"服务已重启，本次任务未完成。", "server_interrupted":"服务中断，本次任务未完成。", "expired":"结果已超过保留期限。", "queue_timeout":"排队超时。"]
          let description = reason[result.error ?? result.state] ?? (result.state == "cancelled" ? "任务已停止。" : CoachStreamError.failed(result.error ?? "unknown").localizedDescription)
          _ = store.stopCoachRequest(attemptID: job.id, error: description); return
        }
        try await Task.sleep(nanoseconds: 800_000_000)
      } catch is CancellationError { return }
      catch let error as CoachJobError {
        if case .rejected(let code) = error, [400,401,403,409,413,422,429].contains(code) {
          _ = store.stopCoachRequest(attemptID: job.id, error: code == 429 ? "当前任务数或额度已达上限，请稍后手动重试。" : "任务提交被拒绝，请检查连接后手动重试。")
          return
        }
        transientFailures += 1
      } catch is MealAgentError {
        _ = store.stopCoachRequest(attemptID: job.id, error: "回复未通过校验，未执行操作。可手动重试。"); return
      } catch { transientFailures += 1 }
      if transientFailures > 0 {
        if Task.isCancelled { return }
        progress[job.id] = .init(title: submitted ? "连接中断，服务器继续处理；正在重连…" : "尚未确认提交，正在重连…")
        if !active || transientFailures >= 6 {
          progress[job.id] = .init(title: "连接暂不可用，返回 App 后继续取回")
          blocked.insert(job.id); return
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
      }
    }
  }
  private func validateGeneration(_ actual: CoachGenerationResult?, turn: CoachTurn) throws {
    guard let actual, actual.valid, actual.model == turn.model, actual.effort == (turn.generation?.effort ?? "none"), actual.web_mode == (turn.generation?.web_mode ?? "off") else { throw MealAgentError.invalid }
  }
}
