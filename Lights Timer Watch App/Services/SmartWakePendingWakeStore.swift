import Foundation

struct SmartWakePendingWakeRecord: Codable, Equatable {
    let schedule: WatchScheduleSnapshot
    let wakeUpTime: Date
    let windowStart: Date
    let baselineStart: Date
    let scheduledSessionStart: Date
    let savedAt: Date
}

enum PersistedSmartWakeAutoLaunchState: String {
    case unknown
    case authorized
    case notAuthorized
    case unsupported
}

final class SmartWakePendingWakeStore {
    private let userDefaults: UserDefaults

    private let pendingWakeRecordKey = "smartWakePendingWakeRecordData"
    private let autoLaunchPromptAttemptedKey = "smartWakeAutoLaunchPromptAttempted"
    private let autoLaunchStateRawKey = "smartWakeAutoLaunchStateRaw"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadPendingWakeRecord() -> SmartWakePendingWakeRecord? {
        guard let data = userDefaults.data(forKey: pendingWakeRecordKey) else { return nil }
        return try? JSONDecoder().decode(SmartWakePendingWakeRecord.self, from: data)
    }

    func savePendingWakeRecord(_ record: SmartWakePendingWakeRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        userDefaults.set(data, forKey: pendingWakeRecordKey)
    }

    func clearPendingWakeRecord() {
        userDefaults.removeObject(forKey: pendingWakeRecordKey)
    }

    var autoLaunchPromptAttempted: Bool {
        get { userDefaults.bool(forKey: autoLaunchPromptAttemptedKey) }
        set { userDefaults.set(newValue, forKey: autoLaunchPromptAttemptedKey) }
    }

    func loadAutoLaunchState() -> PersistedSmartWakeAutoLaunchState? {
        guard let rawValue = userDefaults.string(forKey: autoLaunchStateRawKey) else { return nil }
        return PersistedSmartWakeAutoLaunchState(rawValue: rawValue)
    }

    func saveAutoLaunchState(_ state: PersistedSmartWakeAutoLaunchState) {
        userDefaults.set(state.rawValue, forKey: autoLaunchStateRawKey)
    }
}
