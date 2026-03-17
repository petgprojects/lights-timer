import SwiftUI

@main
struct LightsTimerWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var logStore: SmartWakeLogStore
    @State private var sessionManager: WatchSessionManager
    @State private var sessionController: SmartWakeSessionController

    #if os(watchOS)
    @State private var alarmScheduler: SmartAlarmScheduler
    #endif

    init() {
        let logStore = SmartWakeLogStore()
        let sessionManager = WatchSessionManager(logStore: logStore)
        let sessionController = SmartWakeSessionController(logStore: logStore)
        #if os(watchOS)
        let alarmScheduler = SmartAlarmScheduler(
            sessionController: sessionController,
            sessionManager: sessionManager,
            logStore: logStore
        )
        #endif

        _logStore = State(initialValue: logStore)
        _sessionManager = State(initialValue: sessionManager)
        _sessionController = State(initialValue: sessionController)
        #if os(watchOS)
        _alarmScheduler = State(initialValue: alarmScheduler)
        #endif

        #if os(watchOS)
        sessionManager.onSchedulesUpdated = { schedules in
            alarmScheduler.schedulesDidUpdate(schedules)
        }
        sessionManager.onLightHandoff = { payload in
            sessionController.handleLightHandoff(payload)
        }
        sessionController.onLogReadyToTransfer = { url in
            sessionManager.transferLogFile(url)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(logStore)
                .environment(sessionManager)
                .environment(sessionController)
                #if os(watchOS)
                .environment(alarmScheduler)
                #endif
                .task {
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
                        alarmScheduler.schedulesDidUpdate(sessionManager.activeSchedules)
                    }
                    #endif
                }
                .onChange(of: sessionManager.activeSchedules) { _, schedules in
                    #if os(watchOS)
                    alarmScheduler.schedulesDidUpdate(schedules)
                    #endif
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        #if os(watchOS)
                        alarmScheduler.onAppForeground()
                        #endif
                    }
                }
        }
    }
}
