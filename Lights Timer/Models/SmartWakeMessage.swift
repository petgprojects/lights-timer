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
    let healthKitAuthorized: Bool
    let watchConnected: Bool
}

struct HapticPatternChangePayload: Codable {
    let scheduleID: UUID
    let hapticPatternRaw: String
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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gentle: "Gentle"
        case .pulse: "Pulse"
        case .heartbeat: "Heartbeat"
        case .alarm: "Alarm"
        }
    }

    var patternDescription: String {
        switch self {
        case .gentle: "Soft taps that gradually increase"
        case .pulse: "Rhythmic pulses that build"
        case .heartbeat: "Heartbeat-like double taps"
        case .alarm: "Strong, urgent tapping"
        }
    }

    var systemImage: String {
        switch self {
        case .gentle: "hand.tap"
        case .pulse: "waveform.path"
        case .heartbeat: "heart.fill"
        case .alarm: "alarm.fill"
        }
    }
}
