import Foundation
import WatchConnectivity

@Observable
final class WatchConnectivityService: NSObject, WCSessionDelegate {
    var isWatchAppInstalled: Bool = false
    var isWatchReachable: Bool = false
    var watchSessionState: SmartWakeSessionState?
    var watchPermissionStatus: SmartWakePermissionStatus?

    private var session: WCSession?
    var onSmartWakeTrigger: ((SmartWakeTriggerPayload) -> Void)?
    var onHapticPatternChanged: ((HapticPatternChangePayload) -> Void)?
    var onTestTrigger: ((SmartWakeTriggerPayload) -> Void)?

    override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session
        }
    }

    // MARK: - Send to Watch

    func sendSchedules(_ snapshots: [WatchScheduleSnapshot]) {
        guard let session, session.activationState == .activated else { return }

        do {
            let data = try JSONEncoder().encode(snapshots)
            let context: [String: Any] = [
                WCMessageKey.type: WCMessageKey.schedulesUpdated,
                WCMessageKey.payload: data
            ]
            try session.updateApplicationContext(context)
            print("[WatchConnectivity] Sent \(snapshots.count) schedule(s) to watch")
        } catch {
            print("[WatchConnectivity] Failed to send schedules: \(error)")
        }
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.isWatchAppInstalled = session.isWatchAppInstalled
            self.isWatchReachable = session.isReachable
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isWatchAppInstalled = session.isWatchAppInstalled
            self.isWatchReachable = session.isReachable
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
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            self.handleMessage(message)
        }
        replyHandler(["received": true])
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        Task { @MainActor in
            self.handleMessage(userInfo)
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: [String: Any]) {
        guard let type = message[WCMessageKey.type] as? String,
              let payloadData = message[WCMessageKey.payload] as? Data else { return }

        let decoder = JSONDecoder()

        switch type {
        case WCMessageKey.smartWakeTriggered:
            if let trigger = try? decoder.decode(SmartWakeTriggerPayload.self, from: payloadData) {
                print("[WatchConnectivity] Received smart wake trigger for \(trigger.scheduleID)")
                onSmartWakeTrigger?(trigger)
            }
        case WCMessageKey.sessionStateChanged:
            watchSessionState = try? decoder.decode(SmartWakeSessionState.self, from: payloadData)
        case WCMessageKey.permissionStatus:
            watchPermissionStatus = try? decoder.decode(SmartWakePermissionStatus.self, from: payloadData)
        case WCMessageKey.hapticPatternChanged:
            if let payload = try? decoder.decode(HapticPatternChangePayload.self, from: payloadData) {
                print("[WatchConnectivity] Received haptic pattern change for \(payload.scheduleID): \(payload.hapticPatternRaw)")
                onHapticPatternChanged?(payload)
            }
        case WCMessageKey.testTrigger:
            if let trigger = try? decoder.decode(SmartWakeTriggerPayload.self, from: payloadData) {
                print("[WatchConnectivity] Received test trigger for \(trigger.scheduleID)")
                onTestTrigger?(trigger)
            }
        default:
            break
        }
    }
}
