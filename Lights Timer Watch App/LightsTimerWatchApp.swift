import SwiftUI

@main
struct LightsTimerWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var logStore: SmartWakeLogStore
    @State private var sessionManager: WatchSessionManager
    @State private var sessionController: SmartWakeSessionController

    #if os(watchOS)
    @State private var alarmScheduler: SmartAlarmScheduler?
    #endif

    init() {
        let logStore = SmartWakeLogStore()
        let sessionManager = WatchSessionManager(logStore: logStore)
        let sessionController = SmartWakeSessionController(logStore: logStore)

        _logStore = State(initialValue: logStore)
        _sessionManager = State(initialValue: sessionManager)
        _sessionController = State(initialValue: sessionController)
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(logStore)
                .environment(sessionManager)
                .environment(sessionController)
                .task {
                    #if os(watchOS)
                    // Create the scheduler and wire it up
                    let scheduler = SmartAlarmScheduler(
                        sessionController: sessionController,
                        sessionManager: sessionManager,
                        logStore: logStore
                    )
                    alarmScheduler = scheduler

                    // When schedules arrive (even in background), notify the scheduler
                    sessionManager.onSchedulesUpdated = { schedules in
                        scheduler.schedulesDidUpdate(schedules)
                    }
                    sessionManager.onLightHandoff = { payload in
                        sessionController.handleLightHandoff(payload)
                    }
                    sessionController.onLogReadyToTransfer = { url in
                        sessionManager.transferLogFile(url)
                    }
                    #endif

                    // Request HealthKit authorization
                    _ = await sessionController.requestAuthorization()
                    sessionManager.sendPermissionStatus(
                        authorized: sessionController.isHealthKitAuthorized
                    )
                    logStore.log(
                        "APP",
                        "Watch app task initialized. HealthKit authorized=\(sessionController.isHealthKitAuthorized)"
                    )

                    #if os(watchOS)
                    // Evaluate any schedules already received before the view appeared
                    if !sessionManager.activeSchedules.isEmpty {
                        scheduler.schedulesDidUpdate(sessionManager.activeSchedules)
                    }
                    #endif
                }
                .onChange(of: sessionManager.activeSchedules) { _, schedules in
                    #if os(watchOS)
                    alarmScheduler?.schedulesDidUpdate(schedules)
                    #endif
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        #if os(watchOS)
                        alarmScheduler?.onAppForeground()
                        #endif
                    }
                }
        }
    }
}
