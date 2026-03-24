import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

struct SmartWakeWidgetSnapshot: Codable, Equatable, Sendable {
    let statusTitle: String
    let statusDetail: String
    let nextWakeText: String?
    let powerModeDisplayName: String
    let powerModeDescription: String
    let isBatteryHeavy: Bool
    let updatedAt: Date
}

enum SmartWakeSharedStore {
    static let appGroupID = "group.com.PeterGelgor.Lights-Timer.smartwake"

    private static let powerModeKey = "smartWakePowerMode"
    private static let widgetSnapshotKey = "smartWakeWidgetSnapshot"
    private static let calibrationProfileKey = "smartWakeCalibrationProfile"

    static func sharedDefaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static func loadPowerMode() -> SmartWakePowerMode {
        let defaults = sharedDefaults()
        guard let rawValue = defaults.string(forKey: powerModeKey),
              let mode = SmartWakePowerMode(rawValue: rawValue) else {
            return .balanced
        }
        return mode
    }

    static func savePowerMode(_ powerMode: SmartWakePowerMode) {
        sharedDefaults().set(powerMode.rawValue, forKey: powerModeKey)
    }

    static func loadCalibrationProfile() -> SmartWakeCalibrationProfile {
        let defaults = sharedDefaults()
        guard let data = defaults.data(forKey: calibrationProfileKey),
              let profile = try? JSONDecoder().decode(SmartWakeCalibrationProfile.self, from: data) else {
            return .default
        }
        return profile
    }

    static func saveCalibrationProfile(_ profile: SmartWakeCalibrationProfile) {
        guard let data = try? JSONEncoder().encode(profile.clamped()) else { return }
        sharedDefaults().set(data, forKey: calibrationProfileKey)
    }

    static func loadWidgetSnapshot() -> SmartWakeWidgetSnapshot? {
        let defaults = sharedDefaults()
        guard let data = defaults.data(forKey: widgetSnapshotKey) else { return nil }
        return try? JSONDecoder().decode(SmartWakeWidgetSnapshot.self, from: data)
    }

    static func saveWidgetSnapshot(_ snapshot: SmartWakeWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        sharedDefaults().set(data, forKey: widgetSnapshotKey)
    }
}

#if os(watchOS)
@MainActor
final class SmartWakeWidgetStateStore {
    func update(
        sessionManager: WatchSessionManager,
        sessionController: SmartWakeSessionController,
        alarmScheduler: SmartAlarmScheduler
    ) {
        let snapshot = makeSnapshot(
            sessionManager: sessionManager,
            sessionController: sessionController,
            alarmScheduler: alarmScheduler
        )
        SmartWakeSharedStore.saveWidgetSnapshot(snapshot)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private func makeSnapshot(
        sessionManager: WatchSessionManager,
        sessionController: SmartWakeSessionController,
        alarmScheduler: SmartAlarmScheduler
    ) -> SmartWakeWidgetSnapshot {
        let status: (title: String, detail: String)

        switch sessionController.sessionState {
        case .monitoring:
            status = ("Monitoring", "Watching for wake signals")
        case .triggered:
            status = ("Triggered", "Wake haptics and light fallback are active")
        case .failed:
            status = ("Error", sessionController.errorMessage ?? "Smart Wake failed")
        case .idle:
            switch alarmScheduler.armingState {
            case .armed(let wakeUpTime, _):
                status = ("Armed", "\(sessionManager.powerMode.displayName) motion-first armed for \(formatTime(wakeUpTime))")
            case .monitoringNow:
                status = ("Monitoring", "Monitoring startup is in progress")
            case .backstopActive(let wakeUpTime):
                status = ("Backstop", "Recovered backstop active for \(formatTime(wakeUpTime))")
            case .needsForegroundToArm(let wakeUpTime):
                status = ("Open App", "Open the watch app to arm \(formatTime(wakeUpTime))")
            case .tooEarlyToArm(_, let earliestArmingDate):
                status = ("Too Early", "Reopen after \(formatDateTime(earliestArmingDate))")
            case .failed(let message):
                status = ("Error", message)
            case .noUpcomingWake:
                status = ("No Wake", "No upcoming Smart Wake schedules")
            }
        }

        return SmartWakeWidgetSnapshot(
            statusTitle: status.title,
            statusDetail: status.detail,
            nextWakeText: sessionController.nextScheduledWakeWindowDescription,
            powerModeDisplayName: sessionManager.powerMode.displayName,
            powerModeDescription: sessionManager.powerMode.summary,
            isBatteryHeavy: sessionManager.powerMode.isBatteryHeavy,
            updatedAt: Date()
        )
    }

    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private func formatDateTime(_ date: Date) -> String {
        Self.dateTimeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
#endif
