import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(PhoneLogStore.self) private var phoneLogStore
    @Environment(ScheduleEngine.self) private var scheduleEngine
    @Environment(SmartWakeCoordinator.self) private var smartWakeCoordinator
    @Environment(WatchConnectivityService.self) private var watchConnectivity
    @Environment(HealthKitAuthorizationService.self) private var healthKitAuth

    var body: some View {
        NavigationStack {
            ScheduleListView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            phoneLogStore.log("APP", "Scene phase changed to \(scenePhaseDescription(newPhase))")

            if newPhase == .active {
                phoneLogStore.log("APP", "Refreshing schedules, watch sync, and watch status on active scene")
                Task {
                    await scheduleEngine.onAppActive(modelContext: modelContext)
                }
                smartWakeCoordinator.syncSchedulesToWatch(modelContext: modelContext)
                smartWakeCoordinator.resetDailyState()

                // Update health auth status from watch connectivity
                if let status = watchConnectivity.watchPermissionStatus {
                    healthKitAuth.updateFromWatch(heartRateActive: status.heartRateDataActive)
                }
                healthKitAuth.updateFromConnectivity(
                    watchPaired: watchConnectivity.isWatchPaired,
                    watchInstalled: watchConnectivity.effectiveWatchAppInstalled,
                    watchReachable: watchConnectivity.isWatchReachable
                )
            }
        }
    }

    private func scenePhaseDescription(_ phase: ScenePhase) -> String {
        switch phase {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }
}
