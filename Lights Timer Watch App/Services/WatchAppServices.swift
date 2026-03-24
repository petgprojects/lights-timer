#if os(watchOS)
import Foundation

@MainActor
final class WatchAppServices {
    static let shared = WatchAppServices()

    let logStore: SmartWakeLogStore
    let sessionManager: WatchSessionManager
    let sessionController: SmartWakeSessionController
    let alarmScheduler: SmartAlarmScheduler
    let widgetStateStore: SmartWakeWidgetStateStore

    private init() {
        let logStore = SmartWakeLogStore()
        let sessionManager = WatchSessionManager(logStore: logStore)
        let sessionController = SmartWakeSessionController(logStore: logStore)
        let alarmScheduler = SmartAlarmScheduler(
            sessionController: sessionController,
            sessionManager: sessionManager,
            logStore: logStore
        )
        let widgetStateStore = SmartWakeWidgetStateStore()

        self.logStore = logStore
        self.sessionManager = sessionManager
        self.sessionController = sessionController
        self.alarmScheduler = alarmScheduler
        self.widgetStateStore = widgetStateStore

        sessionManager.onSchedulesUpdated = { [weak self] schedules in
            self?.alarmScheduler.schedulesDidUpdate(schedules)
            self?.refreshDerivedSmartWakeState()
        }
        sessionManager.onLightHandoff = { [weak self] payload in
            self?.sessionController.handleLightHandoff(payload)
        }
        sessionController.onHRAccessConfirmed = { [weak self] in
            guard let self else { return }
            self.sessionManager.sendPermissionStatus(self.sessionController.motionStatusPayload)
            self.refreshDerivedSmartWakeState()
        }
        sessionController.onAuthorizationChanged = { [weak self] in
            guard let self else { return }
            self.sessionManager.sendPermissionStatus(self.sessionController.motionStatusPayload)
            self.refreshDerivedSmartWakeState()
        }
        sessionController.onPresentationStateChanged = { [weak self] in
            self?.updateWidgetState()
        }
        sessionController.onLogReadyToTransfer = { [weak self] url in
            self?.sessionManager.transferLogFile(url)
        }
        sessionController.onOccurrenceSummaryReady = { [weak self] summary in
            self?.sessionManager.sendOccurrenceSummary(summary)
        }
        alarmScheduler.onStatusChanged = { [weak self] in
            self?.refreshDerivedSmartWakeState()
        }

        refreshDerivedSmartWakeState()
    }

    func refreshDerivedSmartWakeState() {
        refreshPassiveHeartRateObservation()
        updateWidgetState()
    }

    private func refreshPassiveHeartRateObservation() {
        let hasSmartWakeSchedules = sessionManager.activeSchedules.contains(where: \.usesSmartWake)
        let shouldEnable: Bool
        let reason: String

        if !hasSmartWakeSchedules {
            shouldEnable = false
            reason = "No smart wake schedules"
        } else if !sessionController.isHealthKitAuthorized {
            shouldEnable = false
            reason = "Needs Health Access"
        } else if sessionController.isMonitoringActive
                    || sessionController.isMonitoringStartupInProgress {
            shouldEnable = false
            reason = "Suspended during active monitoring"
        } else {
            shouldEnable = true
            reason = "Background HR delivery active for motion-first Smart Wake"
        }

        sessionController.configurePassiveHeartRateObservation(
            enabled: shouldEnable,
            reason: reason
        )
    }

    private func updateWidgetState() {
        widgetStateStore.update(
            sessionManager: sessionManager,
            sessionController: sessionController,
            alarmScheduler: alarmScheduler
        )
    }
}
#endif
