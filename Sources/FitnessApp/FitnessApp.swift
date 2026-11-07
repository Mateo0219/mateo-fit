import FitnessCore
import SwiftUI

@main struct XuXuApp: App {
  @StateObject private var store = AppStore.shared
  #if os(iOS)
    @UIApplicationDelegateAdaptor(HealthAppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
  #endif
  var body: some Scene {
    WindowGroup {
      RootView().environmentObject(store).preferredColorScheme(.light)
        #if os(iOS)
          .task { await HealthBridge.shared.refresh(into: store) }
          .onChange(of: scenePhase) { _, phase in
            if phase == .active {
              store.retryProtectedLoad()
              Task { await HealthBridge.shared.refresh(into: store) }
            }
          }
          .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            store.retryProtectedLoad()
            Task { await HealthBridge.shared.refresh(into: store) }
          }
        #endif
        #if os(macOS)
          .frame(minWidth: 420, minHeight: 650)
        #endif
    }
    #if os(macOS)
      .defaultSize(width: 510, height: 850)
    #endif
  }
}
struct RootView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var coachSession = HomeCoachSession()
  @StateObject private var remoteCoach = RemoteCoachCoordinator()
  @AppStorage("coach.includeHealthSummary") private var includeHealthSummary = false
  @AppStorage("coach.includeMemorySummary") private var includeMemorySummary = false
  var body: some View {
    CoachHomeView().environmentObject(coachSession).environmentObject(remoteCoach)
      .id(store.data.activeCoachThreadID ?? CoachThreads.legacyID)
      .background(Color.canvas).foregroundStyle(Color.ink)
      .task { store.prepareCoachThreads(); remoteCoach.resume(store) }
      .onChange(of: includeHealthSummary) { _, _ in remoteCoach.reconcile(store) }
      .onChange(of: includeMemorySummary) { _, _ in remoteCoach.reconcile(store) }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { remoteCoach.resume(store) }
        if phase == .background {
          remoteCoach.background()
          if let attempt = coachSession.requestID { _ = store.stopCoachRequest(attemptID: attempt) }
          coachSession.end()
        }
      }
      .alert(
        "需要注意",
        isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })
      ) {
        Button("知道了", role: .cancel) { store.alert = nil }
      } message: {
        Text(store.alert ?? "")
      }
  }
}
#if os(iOS)
import UIKit
@MainActor final class HealthAppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    HealthBridge.shared.startObservers(into: AppStore.shared)
    return true
  }
}
#endif
