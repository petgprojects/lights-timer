import SwiftUI

@main
struct LightsTimerWatchApp: App {
    @State private var sessionManager = WatchSessionManager()
    @State private var sessionController = SmartWakeSessionController()

    #if os(watchOS)
    @State private var alarmScheduler: SmartAlarmScheduler?
    #endif

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(sessionManager)
                .environment(sessionController)
                .task {
                    #if os(watchOS)
                    // Create the scheduler and wire it up
                    let scheduler = SmartAlarmScheduler(
                        sessionController: sessionController,
                        sessionManager: sessionManager
                    )
                    alarmScheduler = scheduler

                    // When schedules arrive (even in background), notify the scheduler
                    sessionManager.onSchedulesUpdated = { schedules in
                        scheduler.schedulesDidUpdate(schedules)
                    }
                    #endif

                    // Request HealthKit authorization
                    await sessionController.requestAuthorization()
                    sessionManager.sendPermissionStatus(
                        authorized: sessionController.isHealthKitAuthorized
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
        }
    }
}
