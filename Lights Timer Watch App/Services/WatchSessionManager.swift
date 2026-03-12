import Foundation
import WatchConnectivity

@Observable
final class WatchSessionManager: NSObject, WCSessionDelegate {
    var activeSchedules: [WatchScheduleSnapshot] = []
    var isPhoneReachable: Bool = false
    var lastLightHandoff: SmartWakeLightHandoffPayload?

    /// Called whenever schedules are received (including from background WCSession delivery).
    var onSchedulesUpdated: (([WatchScheduleSnapshot]) -> Void)?
    var onLightHandoff: ((SmartWakeLightHandoffPayload) -> Void)?

    private var session: WCSession?

    override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session
        }
    }

    // MARK: - Send to Phone

    func sendTrigger(_ payload: SmartWakeTriggerPayload) {
        sendRealtimeMessage(payload, type: WCMessageKey.smartWakeTriggered)
    }

    func sendSessionState(_ state: SmartWakeSessionState) {
        guard let session else { return }

        do {
            let data = try JSONEncoder().encode(state)
            let message: [String: Any] = [
                WCMessageKey.type: WCMessageKey.sessionStateChanged,
                WCMessageKey.payload: data
            ]
            if session.isReachable {
                session.sendMessage(message, replyHandler: nil, errorHandler: nil)
            }
        } catch {
            print("[WatchSession] Failed to send state: \(error)")
        }
    }

    func sendHapticPatternChange(scheduleID: UUID, pattern: String) {
        let payload = HapticPatternChangePayload(scheduleID: scheduleID, hapticPatternRaw: pattern)
        sendBestEffortMessage(payload, type: WCMessageKey.hapticPatternChanged)
    }

    func sendTestTrigger(_ payload: SmartWakeTriggerPayload) {
        sendRealtimeMessage(payload, type: WCMessageKey.testTrigger)
    }

    func sendPermissionStatus(authorized: Bool) {
        guard let session else { return }

        do {
            let status = SmartWakePermissionStatus(
                healthKitAuthorized: authorized,
                watchConnected: true
            )
            let data = try JSONEncoder().encode(status)
            let message: [String: Any] = [
                WCMessageKey.type: WCMessageKey.permissionStatus,
                WCMessageKey.payload: data
            ]
            if session.isReachable {
                session.sendMessage(message, replyHandler: nil, errorHandler: nil)
            }
        } catch {
            print("[WatchSession] Failed to send permission status: \(error)")
        }
    }

    private func sendRealtimeMessage<T: Codable>(_ payload: T, type: String) {
        guard let session else { return }

        do {
            let data = try JSONEncoder().encode(payload)
            let message: [String: Any] = [
                WCMessageKey.type: type,
                WCMessageKey.payload: data
            ]

            // On watchOS, sendMessage can wake the iPhone app even when isReachable is false.
            session.sendMessage(message, replyHandler: { reply in
                print("[WatchSession] \(type) sent, reply: \(reply)")
            }, errorHandler: { error in
                print("[WatchSession] sendMessage failed for \(type): \(error), using transferUserInfo")
                session.transferUserInfo(message)
            })
        } catch {
            print("[WatchSession] Failed to encode \(type): \(error)")
        }
    }

    private func sendBestEffortMessage<T: Codable>(_ payload: T, type: String) {
        guard let session else { return }

        do {
            let data = try JSONEncoder().encode(payload)
            let message: [String: Any] = [
                WCMessageKey.type: type,
                WCMessageKey.payload: data
            ]

            if session.isReachable {
                session.sendMessage(message, replyHandler: nil) { error in
                    print("[WatchSession] sendMessage failed for \(type): \(error), using transferUserInfo")
                    session.transferUserInfo(message)
                }
            } else {
                session.transferUserInfo(message)
            }
        } catch {
            print("[WatchSession] Failed to encode \(type): \(error)")
        }
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.isPhoneReachable = session.isReachable
            self.processApplicationContext(session.receivedApplicationContext)
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in
            self.processApplicationContext(applicationContext)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isPhoneReachable = session.isReachable
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        Task { @MainActor in
            self.handleMessage(message)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        Task { @MainActor in
            self.handleMessage(userInfo)
        }
    }

    // MARK: - Context Processing

    private func processApplicationContext(_ context: [String: Any]) {
        guard let type = context[WCMessageKey.type] as? String,
              type == WCMessageKey.schedulesUpdated,
              let data = context[WCMessageKey.payload] as? Data else { return }

        do {
            let schedules = try JSONDecoder().decode([WatchScheduleSnapshot].self, from: data)
            activeSchedules = schedules
            onSchedulesUpdated?(schedules)
            print("[WatchSession] Received \(schedules.count) schedule(s) from phone")
        } catch {
            print("[WatchSession] Failed to decode schedules: \(error)")
        }
    }

    private func handleMessage(_ message: [String: Any]) {
        guard let type = message[WCMessageKey.type] as? String,
              let data = message[WCMessageKey.payload] as? Data else { return }

        switch type {
        case WCMessageKey.smartWakeLightHandoff:
            do {
                let payload = try JSONDecoder().decode(SmartWakeLightHandoffPayload.self, from: data)
                lastLightHandoff = payload
                onLightHandoff?(payload)
                print("[WatchSession] Received handoff for trigger \(payload.triggerID): phoneWillHandleLights=\(payload.phoneWillHandleLights)")
            } catch {
                print("[WatchSession] Failed to decode handoff: \(error)")
            }
        default:
            break
        }
    }
}
