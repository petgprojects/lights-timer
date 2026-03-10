import Foundation
import WatchConnectivity

@Observable
final class WatchSessionManager: NSObject, WCSessionDelegate {
    var activeSchedules: [WatchScheduleSnapshot] = []
    var isPhoneReachable: Bool = false

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
        guard let session else { return }

        do {
            let data = try JSONEncoder().encode(payload)
            let message: [String: Any] = [
                WCMessageKey.type: WCMessageKey.smartWakeTriggered,
                WCMessageKey.payload: data
            ]

            if session.isReachable {
                session.sendMessage(message, replyHandler: { reply in
                    print("[WatchSession] Trigger sent, reply: \(reply)")
                }, errorHandler: { error in
                    print("[WatchSession] sendMessage failed: \(error), using transferUserInfo")
                    session.transferUserInfo(message)
                })
            } else {
                session.transferUserInfo(message)
                print("[WatchSession] Phone not reachable, queued via transferUserInfo")
            }
        } catch {
            print("[WatchSession] Failed to encode trigger: \(error)")
        }
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

    // MARK: - Context Processing

    private func processApplicationContext(_ context: [String: Any]) {
        guard let type = context[WCMessageKey.type] as? String,
              type == WCMessageKey.schedulesUpdated,
              let data = context[WCMessageKey.payload] as? Data else { return }

        do {
            let schedules = try JSONDecoder().decode([WatchScheduleSnapshot].self, from: data)
            activeSchedules = schedules
            print("[WatchSession] Received \(schedules.count) schedule(s) from phone")
        } catch {
            print("[WatchSession] Failed to decode schedules: \(error)")
        }
    }
}
