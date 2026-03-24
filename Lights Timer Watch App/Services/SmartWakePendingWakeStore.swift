import Foundation

struct SmartWakePendingWakeRecord: Codable, Equatable {
    let schedule: WatchScheduleSnapshot
    let wakeUpTime: Date
    let windowStart: Date
    let baselineStart: Date
    let scheduledSessionStart: Date
    let armedAt: Date
    let savedAt: Date
    let isSessionScheduled: Bool

    init(
        schedule: WatchScheduleSnapshot,
        wakeUpTime: Date,
        windowStart: Date,
        baselineStart: Date,
        scheduledSessionStart: Date,
        armedAt: Date,
        savedAt: Date,
        isSessionScheduled: Bool = true
    ) {
        self.schedule = schedule
        self.wakeUpTime = wakeUpTime
        self.windowStart = windowStart
        self.baselineStart = baselineStart
        self.scheduledSessionStart = scheduledSessionStart
        self.armedAt = armedAt
        self.savedAt = savedAt
        self.isSessionScheduled = isSessionScheduled
    }

    private enum CodingKeys: String, CodingKey {
        case schedule
        case wakeUpTime
        case windowStart
        case baselineStart
        case scheduledSessionStart
        case armedAt
        case savedAt
        case isSessionScheduled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schedule = try container.decode(WatchScheduleSnapshot.self, forKey: .schedule)
        wakeUpTime = try container.decode(Date.self, forKey: .wakeUpTime)
        windowStart = try container.decode(Date.self, forKey: .windowStart)
        baselineStart = try container.decode(Date.self, forKey: .baselineStart)
        scheduledSessionStart = try container.decode(Date.self, forKey: .scheduledSessionStart)
        armedAt = try container.decodeIfPresent(Date.self, forKey: .armedAt)
            ?? scheduledSessionStart
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        isSessionScheduled =
            try container.decodeIfPresent(Bool.self, forKey: .isSessionScheduled) ?? true
    }
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
