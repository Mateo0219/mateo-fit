#if os(iOS)
  import Foundation
  import HealthKit
  import FitnessCore

  @MainActor final class HealthBridge {
    static let shared = HealthBridge()
    private let health = HKHealthStore()
    private enum SyncError: Error { case storage, tooManyBatches }
    private var observers: [HKObserverQuery] = []
    private var running: Task<Void, Never>?
    private var pending = false
    private var deliveryRequested = false
    private var deliveryReady = false

    var types: [HKSampleType] {
      [HKObjectType.quantityType(forIdentifier: .bodyMass)!,
       HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!]
    }
    func startObservers(into store: AppStore) {
      guard observers.isEmpty, HKHealthStore.isHealthDataAvailable() else { return }
      for type in types {
        let observer = HKObserverQuery(sampleType: type, predicate: nil) { [weak self, weak store] _, completion, error in
          Task { @MainActor in
            defer { completion() }
            guard let self, let store else { return }
            if error != nil {
              store.healthStatus = "健康更新通知暂不可用，打开 App 时会重试。"
              return
            }
            await self.refresh(into: store)
          }
        }
        observers.append(observer)
        health.execute(observer)
      }
    }
    func configureDelivery(into store: AppStore) async {
      guard !deliveryRequested else { return }
      deliveryRequested = true
      do {
        for type in types { try await health.enableBackgroundDelivery(for: type, frequency: .immediate) }
        deliveryReady = true
        store.healthStatus = "自动更新已开启"
      } catch {
        deliveryRequested = false
        store.healthStatus = "打开 App 会自动更新；后台更新暂不可用。"
      }
    }
    func sync(into store: AppStore) async {
      guard !store.healthBusy else { return }
      do {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await health.requestAuthorization(toShare: [], read: Set(types))
        guard store.change({ $0.healthAutoSyncEnabled = true }) else { return }
        await refresh(into: store)
      } catch { store.alert = "健康连接未完成，请稍后重试。" }
    }
    func refresh(into store: AppStore) async {
      guard store.data.healthAutoSyncEnabled == true || store.data.healthSyncedAt != nil else { return }
      startObservers(into: store)
      pending = true
      if let running { await running.value; return }
      let task = Task { @MainActor in
        await self.configureDelivery(into: store)
        while self.pending {
          self.pending = false
          await self.readChanges(into: store)
        }
        self.running = nil
      }
      running = task
      await task.value
    }
    private func readChanges(into store: AppStore) async {
      guard HKHealthStore.isHealthDataAvailable() else {
        store.alert = "此设备暂不支持健康数据。"
        return
      }
      store.healthBusy = true
      defer { store.healthBusy = false }
      let weight = HKObjectType.quantityType(forIdentifier: .bodyMass)!
      let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
      do {
        // Keep a stable query predicate across subsequent anchored reads.
        let windowKey = "window-start-v2"
        let window: Date
        if let bytes = store.data.healthAnchors[windowKey] {
          window = try JSONDecoder().decode(Date.self, from: bytes)
        } else {
          window = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        }
        for type in [weight as HKSampleType, sleep as HKSampleType] {
          let anchorKey = type.identifier + "-v2"
          var completed = false
          for _ in 0..<100 {
            let anchor: HKQueryAnchor?
            if let bytes = store.data.healthAnchors[anchorKey] {
              anchor = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: HKQueryAnchor.self, from: bytes)
            } else {
              anchor = nil
            }
            let predicate = HKQuery.predicateForSamples(withStart: window, end: nil, options: [])
            let batch = try await query(type: type, predicate: predicate, anchor: anchor)
            let deleted = Set(batch.deleted.map { $0.uuid.uuidString })
            let anchorData = try NSKeyedArchiver.archivedData(
              withRootObject: batch.anchor, requiringSecureCoding: true)
            let windowData = try JSONEncoder().encode(window)
            let saved = store.change { data in
              if type.identifier == weight.identifier {
                let additions = batch.samples.compactMap { sample -> WeightEntry? in
                  guard let value = sample as? HKQuantitySample else { return nil }
                  return WeightEntry(
                    id: value.uuid.uuidString, date: value.endDate,
                    kg: value.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                    source: "Apple 健康 · " + value.sourceRevision.source.name)
                }
                data.weights = DataMath.mergedWeights(
                  data.weights, additions: additions, deleted: deleted)
              } else {
                var entries = Dictionary(
                  data.sleep.filter { !deleted.contains($0.id) }.map { ($0.id, $0) },
                  uniquingKeysWith: { $1 })
                let stages: [Int: SleepStage] = [0: .inBed, 1: .unspecified, 2: .awake, 3: .core, 4: .deep, 5: .rem]
                for sample in batch.samples {
                  guard let value = sample as? HKCategorySample, let stage = stages[value.value],
                    !deleted.contains(value.uuid.uuidString) else { continue }
                  let revision = value.sourceRevision
                  let product = revision.productType ?? ""
                  entries[value.uuid.uuidString] = SleepEntry(
                    id: value.uuid.uuidString, start: value.startDate, end: value.endDate,
                    source: revision.source.name, stage: stage,
                    sourceID: revision.source.bundleIdentifier + ":" + product,
                    isWatch: product.hasPrefix("Watch") || value.device?.model?.contains("Watch") == true)
                }
                data.sleep = entries.values.sorted { $0.start < $1.start }
              }
              // Data and anchors commit in one atomic local write. Failed writes replay safely.
              data.healthAnchors[anchorKey] = anchorData
              data.healthAnchors[windowKey] = windowData
            }
            guard saved else { throw SyncError.storage }
            if batch.samples.count + batch.deleted.count < 500 {
              completed = true
              break
            }
          }
          guard completed else { throw SyncError.tooManyBatches }
        }
        let saved = store.change { data in
          data.healthSyncedAt = Date()
          let weights = data.weights.filter { $0.source.hasPrefix("Apple 健康") }.count
          data.lastHealthSummary =
            "查询完成：本地保留体重 \(weights) 条、睡眠片段 \(data.sleep.count) 条。暂无可用记录时，可能是未授权或来源尚无数据。"
        }
        if !saved { throw SyncError.storage }
        store.healthStatus = deliveryReady ? "自动更新已开启" : "打开 App 自动更新；后台更新暂不可用"
      } catch {
        store.healthStatus = "本次更新未完成，保留上次记录；解锁并打开 App 后重试。"
      }
    }
    private struct Batch {
      let samples: [HKSample]
      let deleted: [HKDeletedObject]
      let anchor: HKQueryAnchor
    }
    private func query(type: HKSampleType, predicate: NSPredicate, anchor: HKQueryAnchor?)
      async throws -> Batch
    {
      try await withCheckedThrowingContinuation { continuation in
        let query = HKAnchoredObjectQuery(
          type: type, predicate: predicate, anchor: anchor, limit: 500
        ) { _, samples, deleted, next, error in
          if let error {
            continuation.resume(throwing: error)
          } else if let next {
            continuation.resume(
              returning: Batch(samples: samples ?? [], deleted: deleted ?? [], anchor: next))
          } else {
            continuation.resume(throwing: SyncError.storage)
          }
        }
        health.execute(query)
      }
    }
  }
#endif
