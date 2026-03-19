import SwiftUI
#if os(watchOS)
import WatchKit
#endif

@main
struct LightsTimerWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    #if os(watchOS)
    @WKExtensionDelegateAdaptor(WatchExtensionDelegate.self) private var extensionDelegate
    private let services = WatchAppServices.shared
    #endif

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                #if os(watchOS)
                .environment(services.logStore)
                .environment(services.sessionManager)
                .environment(services.sessionController)
                .environment(services.alarmScheduler)
                .task {
                    // Request HealthKit authorization
                    _ = await services.sessionController.requestAuthorization()
                    services.sessionManager.sendPermissionStatus(
                        authorized: services.sessionController.isHealthKitAuthorized
                    )
                    services.logStore.log(
                        "APP",
                        "Watch app task initialized. HealthKit authorized=\(services.sessionController.isHealthKitAuthorized)"
                    )

                    #if os(watchOS)
                    services.alarmScheduler.refreshAutoLaunchAuthorization(
                        promptIfEligible: shouldPromptAutoLaunchAuthorization(
                            for: services.sessionManager.activeSchedules
                        )
                    )

                    // Evaluate any schedules already received before the view appeared
                    if !services.sessionManager.activeSchedules.isEmpty {
                        services.alarmScheduler.schedulesDidUpdate(services.sessionManager.activeSchedules)
                    }
                    #endif
                }
                .onChange(of: services.sessionManager.activeSchedules) { _, schedules in
                    #if os(watchOS)
                    services.alarmScheduler.refreshAutoLaunchAuthorization(
                        promptIfEligible: shouldPromptAutoLaunchAuthorization(for: schedules)
                    )
                    services.alarmScheduler.schedulesDidUpdate(schedules)
                    #endif
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        services.alarmScheduler.refreshAutoLaunchAuthorization(
                            promptIfEligible: shouldPromptAutoLaunchAuthorization(
                                for: services.sessionManager.activeSchedules
                            )
                        )
                        services.alarmScheduler.onAppForeground()
                    }
                }
                #endif
        }
    }

    #if os(watchOS)
    private func shouldPromptAutoLaunchAuthorization(
        for schedules: [WatchScheduleSnapshot]
    ) -> Bool {
        scenePhase == .active && schedules.contains(where: \.usesSmartWake)
    }
    #endif
}
