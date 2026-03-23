import Foundation

struct SmartWakeWidgetSnapshot: Codable {
    let statusTitle: String
    let statusDetail: String
    let nextWakeText: String
    let powerModeDisplayName: String
    let powerModeDescription: String
    let isBatteryHeavy: Bool
    let updatedAt: Date

    static let placeholder = SmartWakeWidgetSnapshot(
        statusTitle: "Smart Wake Armed",
        statusDetail: "Monitoring will start near your wake window.",
        nextWakeText: "Next wake 7:00 AM",
        powerModeDisplayName: "Balanced",
        powerModeDescription: "Lower battery, best-effort smart wake.",
        isBatteryHeavy: false,
        updatedAt: .now
    )

    static let empty = SmartWakeWidgetSnapshot(
        statusTitle: "No Wake Armed",
        statusDetail: "Open Lights Timer on your watch to arm Smart Wake.",
        nextWakeText: "No wake armed",
        powerModeDisplayName: "Balanced",
        powerModeDescription: "Lower battery, best-effort smart wake.",
        isBatteryHeavy: false,
        updatedAt: .now
    )
}

enum SmartWakeSharedStore {
    static let appGroupID = "group.com.PeterGelgor.Lights-Timer.smartwake"
    static let widgetSnapshotKey = "smartWake.widgetSnapshot"

    static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func loadWidgetSnapshot() -> SmartWakeWidgetSnapshot {
        guard
            let data = sharedDefaults()?.data(forKey: widgetSnapshotKey),
            let snapshot = try? JSONDecoder().decode(SmartWakeWidgetSnapshot.self, from: data)
        else {
            return .empty
        }

        return snapshot
    }
}
