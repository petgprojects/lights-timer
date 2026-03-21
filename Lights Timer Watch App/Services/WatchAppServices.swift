#if os(watchOS)
import Foundation

@MainActor
final class WatchAppServices {
    static let shared = WatchAppServices()

    let logStore: SmartWakeLogStore
    let sessionManager: WatchSessionManager
    let sessionController: SmartWakeSessionController
    let alarmScheduler: SmartAlarmScheduler

    private init() {
        let logStore = SmartWakeLogStore()
        let sessionManager = WatchSessionManager(logStore: logStore)
        let sessionController = SmartWakeSessionController(logStore: logStore)
        let alarmScheduler = SmartAlarmScheduler(
            sessionController: sessionController,
            sessionManager: sessionManager,
            logStore: logStore
        )

        self.logStore = logStore
        self.sessionManager = sessionManager
        self.sessionController = sessionController
        self.alarmScheduler = alarmScheduler

        sessionManager.onSchedulesUpdated = { [weak self] schedules in
            self?.alarmScheduler.schedulesDidUpdate(schedules)
        }
        sessionManager.onLightHandoff = { [weak self] payload in
            self?.sessionController.handleLightHandoff(payload)
        }
        sessionController.onHRAccessConfirmed = { [weak self] in
            self?.sessionManager.sendHeartRateStatus(active: true)
        }
        sessionController.onLogReadyToTransfer = { [weak self] url in
            self?.sessionManager.transferLogFile(url)
        }
    }
}
#endif
