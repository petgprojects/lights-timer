import Foundation

struct SmartWakeTriggerPayload: Codable {
    let scheduleID: UUID
    let triggerDate: Date
    let confidence: Double
    let heartRateAtTrigger: Double?
    let motionLevel: Double?
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

enum WCMessageKey {
    static let type = "type"
    static let payload = "payload"

    static let smartWakeTriggered = "smartWakeTriggered"
    static let sessionStateChanged = "sessionStateChanged"
    static let permissionStatus = "permissionStatus"
    static let schedulesUpdated = "schedulesUpdated"
}
