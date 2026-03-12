import Foundation
import WatchConnectivity

@Observable
final class WatchConnectivityService: NSObject, WCSessionDelegate {
    var isWatchAppInstalled: Bool = false
    var isWatchReachable: Bool = false
    var watchSessionState: SmartWakeSessionState?
    var watchPermissionStatus: SmartWakePermissionStatus?

    private var session: WCSession?
    private var cachedSchedulesContext: [String: Any]?

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
        do {
            let data = try JSONEncoder().encode(snapshots)
            cachedSchedulesContext = [
                WCMessageKey.type: WCMessageKey.schedulesUpdated,
                WCMessageKey.payload: data
            ]
            flushCachedSchedulesContext()
        } catch {
            print("[WatchConnectivity] Failed to encode schedules: \(error)")
        }
    }

    func sendLightHandoff(_ payload: SmartWakeLightHandoffPayload) {
        guard let session else { return }

        do {
            let data = try JSONEncoder().encode(payload)
            let message: [String: Any] = [
                WCMessageKey.type: WCMessageKey.smartWakeLightHandoff,
                WCMessageKey.payload: data
            ]

            if session.isReachable {
                session.sendMessage(message, replyHandler: nil) { error in
                    print("[WatchConnectivity] Failed to send handoff for \(payload.triggerID): \(error)")
                }
            } else {
                session.transferUserInfo(message)
                print("[WatchConnectivity] Watch not reachable, queued handoff for \(payload.triggerID)")
            }
        } catch {
            print("[WatchConnectivity] Failed to encode handoff: \(error)")
        }
    }

    private func flushCachedSchedulesContext() {
        guard let session,
              session.activationState == .activated,
              let context = cachedSchedulesContext else { return }

        do {
            try session.updateApplicationContext(context)
            if let data = context[WCMessageKey.payload] as? Data,
               let schedules = try? JSONDecoder().decode([WatchScheduleSnapshot].self, from: data) {
                print("[WatchConnectivity] Sent \(schedules.count) schedule(s) to watch")
            } else {
                print("[WatchConnectivity] Sent schedules to watch")
            }
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
            self.flushCachedSchedulesContext()
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
            self.flushCachedSchedulesContext()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isWatchReachable = session.isReachable
            self.flushCachedSchedulesContext()
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
                print("[WatchConnectivity] Received smart wake trigger \(trigger.triggerID) for \(trigger.scheduleID)")
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
                print("[WatchConnectivity] Received test trigger \(trigger.triggerID) for \(trigger.scheduleID)")
                onTestTrigger?(trigger)
            }
        default:
            break
        }
    }
}
