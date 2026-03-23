import Foundation

struct SmartWakeTriggerPayload: Codable, Equatable {
    let triggerID: UUID
    let scheduleID: UUID
    let triggerDate: Date
    let confidence: Double
    let heartRateAtTrigger: Double?
    let motionLevel: Double?
    let lightsHandledOnWatch: Bool?

    init(
        triggerID: UUID = UUID(),
        scheduleID: UUID,
        triggerDate: Date,
        confidence: Double,
        heartRateAtTrigger: Double?,
        motionLevel: Double?,
        lightsHandledOnWatch: Bool? = nil
    ) {
        self.triggerID = triggerID
        self.scheduleID = scheduleID
        self.triggerDate = triggerDate
        self.confidence = confidence
        self.heartRateAtTrigger = heartRateAtTrigger
        self.motionLevel = motionLevel
        self.lightsHandledOnWatch = lightsHandledOnWatch
    }
}

struct SmartWakeLightHandoffPayload: Codable, Equatable {
    let triggerID: UUID
    let scheduleID: UUID
    let phoneWillHandleLights: Bool
    let reason: String?
}

struct SmartWakeSessionState: Codable {
    enum State: String, Codable {
        case idle
        case monitoring
        case triggered
        case failed
    }

    let state: State
    let scheduleID: UUID?
    let message: String?
}

struct SmartWakePermissionStatus: Codable {
    let heartRateDataActive: Bool
    let watchConnected: Bool

    private enum CodingKeys: String, CodingKey {
        case heartRateDataActive = "healthKitAuthorized"
        case watchConnected
    }
}

struct HapticPatternChangePayload: Codable {
    let scheduleID: UUID
    let hapticPatternRaw: String
}

enum SmartWakePowerMode: String, Codable, CaseIterable, Identifiable {
    case balanced
    case highReliability

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .balanced:
            "Balanced"
        case .highReliability:
            "High Reliability"
        }
    }

    var summary: String {
        switch self {
        case .balanced:
            "Starts the workout only near wake for lower overnight battery use."
        case .highReliability:
            "Starts an overnight workout session to maximize early Smart Wake reliability."
        }
    }

    var detail: String {
        switch self {
        case .balanced:
            "Recommended. Smart Wake is best-effort before exact wake, with lower battery use. Add the watch widget for better background delivery."
        case .highReliability:
            "Highest chance of an early Smart Wake trigger, with significantly higher overnight battery use."
        }
    }

    var isBatteryHeavy: Bool {
        switch self {
        case .balanced:
            false
        case .highReliability:
            true
        }
    }
}

struct SmartWakeSyncPayload: Codable, Equatable {
    let schedules: [WatchScheduleSnapshot]
    let powerMode: SmartWakePowerMode
}

enum WCMessageKey {
    static let type = "type"
    static let payload = "payload"

    static let smartWakeTriggered = "smartWakeTriggered"
    static let sessionStateChanged = "sessionStateChanged"
    static let permissionStatus = "permissionStatus"
    static let schedulesUpdated = "schedulesUpdated"
    static let hapticPatternChanged = "hapticPatternChanged"
    static let testTrigger = "testTrigger"
    static let smartWakeLightHandoff = "smartWakeLightHandoff"
}

enum HapticPattern: String, Codable, CaseIterable, Identifiable {
    case gentle
    case pulse
    case heartbeat
    case alarm
    case critical

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gentle: "Gentle"
        case .pulse: "Pulse"
        case .heartbeat: "Heartbeat"
        case .alarm: "Alarm"
        case .critical: "Critical"
        }
    }

    var patternDescription: String {
        switch self {
        case .gentle: "Soft taps that gradually increase"
        case .pulse: "Rhythmic pulses that build"
        case .heartbeat: "Heartbeat-like double taps"
        case .alarm: "Aggressive alarm bursts with rapid follow-up taps"
        case .critical: "Maximum-strength triple bursts using the strongest watch haptics available to the app"
        }
    }

    var systemImage: String {
        switch self {
        case .gentle: "hand.tap"
        case .pulse: "waveform.path"
        case .heartbeat: "heart.fill"
        case .alarm: "alarm.fill"
        case .critical: "exclamationmark.triangle.fill"
        }
    }
}
