import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(ScheduleEngine.self) private var scheduleEngine
    @Environment(SmartWakeCoordinator.self) private var smartWakeCoordinator
    @Environment(WatchConnectivityService.self) private var watchConnectivity
    @Environment(HealthKitAuthorizationService.self) private var healthKitAuth

    var body: some View {
        NavigationStack {
            ScheduleListView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await scheduleEngine.onAppActive(modelContext: modelContext)
                    await smartWakeCoordinator.processPendingTrigger(modelContext: modelContext)
                }
                smartWakeCoordinator.syncSchedulesToWatch(modelContext: modelContext)
                smartWakeCoordinator.resetDailyState()

                // Update health auth status from watch connectivity
                if let status = watchConnectivity.watchPermissionStatus {
                    healthKitAuth.updateFromWatch(authorized: status.healthKitAuthorized)
                }
                healthKitAuth.updateFromConnectivity(
                    watchInstalled: watchConnectivity.isWatchAppInstalled,
                    watchReachable: watchConnectivity.isWatchReachable
                )
            }
        }
    }
}
