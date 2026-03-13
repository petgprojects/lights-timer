import Foundation
import WatchConnectivity

@Observable
final class WatchConnectivityService: NSObject, WCSessionDelegate {
    private let logStore: PhoneLogStore

    var isWatchAppInstalled: Bool = false
    var isWatchReachable: Bool = false
    var isWatchPaired: Bool = false
    var watchSessionState: SmartWakeSessionState?
    var watchPermissionStatus: SmartWakePermissionStatus?

    var effectiveWatchAppInstalled: Bool {
        isWatchAppInstalled || hasConfirmedWatchAppPresence || isWatchReachable
    }

    private var session: WCSession?
    private var cachedSchedulesContext: [String: Any]?
    private var lastSuccessfullySentSchedulesPayload: Data?
    private var hasConfirmedWatchAppPresence = false

    var onSmartWakeTrigger: ((SmartWakeTriggerPayload) -> Void)?
    var onHapticPatternChanged: ((HapticPatternChangePayload) -> Void)?
    var onTestTrigger: ((SmartWakeTriggerPayload) -> Void)?
    var onWatchLogFileReceived: ((URL, [String: Any]?) -> Void)?

    init(logStore: PhoneLogStore) {
        self.logStore = logStore
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session
            log("WCSession supported; activating watch connectivity session")
        } else {
            log("WCSession is not supported on this device", level: .warning)
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
            log("Failed to encode schedules: \(error)", level: .error)
        }
    }

    func sendLightHandoff(_ payload: SmartWakeLightHandoffPayload) {
        guard let session else {
            log("Cannot send handoff \(payload.triggerID): WCSession unavailable", level: .warning)
            return
        }

        do {
            let data = try JSONEncoder().encode(payload)
            let message: [String: Any] = [
                WCMessageKey.type: WCMessageKey.smartWakeLightHandoff,
                WCMessageKey.payload: data
            ]

            if session.isReachable {
                session.sendMessage(message, replyHandler: nil) { error in
                    Task { @MainActor in
                        self.log("Failed to send handoff for \(payload.triggerID): \(error)", level: .error)
                    }
                }
            } else {
                session.transferUserInfo(message)
                log("Watch not reachable, queued handoff for \(payload.triggerID)", level: .warning)
            }
        } catch {
            log("Failed to encode handoff: \(error)", level: .error)
        }
    }

    private func flushCachedSchedulesContext() {
        guard let session,
              session.activationState == .activated,
              let context = cachedSchedulesContext,
              let payload = context[WCMessageKey.payload] as? Data else { return }

        guard lastSuccessfullySentSchedulesPayload != payload else { return }

        do {
            try session.updateApplicationContext(context)
            lastSuccessfullySentSchedulesPayload = payload
            if let schedules = try? JSONDecoder().decode([WatchScheduleSnapshot].self, from: payload) {
                log("Sent \(schedules.count) schedule(s) to watch")
            } else {
                log("Sent schedules to watch")
            }
        } catch {
            log("Failed to send schedules: \(error)", level: .error)
        }
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.log("WCSession activation completed with error: \(error)", level: .error)
            } else {
                self.log("WCSession activation completed: state=\(activationState.rawValue)")
            }
            self.refreshSessionState(from: session, reason: "activation-complete")
            self.flushCachedSchedulesContext()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            self.log("WCSession deactivated; reactivating")
        }
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshSessionState(from: session, reason: "watch-state-changed")
            self.flushCachedSchedulesContext()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshSessionState(from: session, reason: "reachability-changed")
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        Task { @MainActor in
            self.noteWatchAppPresence()
            self.handleMessage(message)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            self.noteWatchAppPresence()
            self.handleMessage(message)
        }
        replyHandler(["received": true])
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        Task { @MainActor in
            self.noteWatchAppPresence()
            self.handleMessage(userInfo)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceive file: WCSessionFile
    ) {
        Task { @MainActor in
            self.noteWatchAppPresence()
            self.log(
                "Received watch log file \(file.fileURL.lastPathComponent) with metadata \(file.metadata ?? [:])"
            )
            self.onWatchLogFileReceived?(file.fileURL, file.metadata)
        }
    }

    // MARK: - Message Handling

    private func refreshSessionState(from session: WCSession, reason: String) {
        isWatchPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isWatchReachable = session.isReachable

        if session.isWatchAppInstalled || session.isReachable {
            hasConfirmedWatchAppPresence = true
        } else if !session.isPaired {
            hasConfirmedWatchAppPresence = false
        }

        log(
            "Watch session state updated (\(reason)): paired=\(isWatchPaired), installed=\(isWatchAppInstalled), reachable=\(isWatchReachable), effectiveInstalled=\(effectiveWatchAppInstalled)"
        )
    }

    private func noteWatchAppPresence() {
        hasConfirmedWatchAppPresence = true
        log("Confirmed watch app presence from incoming watch traffic")
    }

    private func handleMessage(_ message: [String: Any]) {
        guard let type = message[WCMessageKey.type] as? String,
              let payloadData = message[WCMessageKey.payload] as? Data else {
            log("Received malformed watch message: \(message)", level: .warning)
            return
        }

        let decoder = JSONDecoder()

        switch type {
        case WCMessageKey.smartWakeTriggered:
            if let trigger = try? decoder.decode(SmartWakeTriggerPayload.self, from: payloadData) {
                log("Received smart wake trigger \(trigger.triggerID) for \(trigger.scheduleID)")
                onSmartWakeTrigger?(trigger)
            } else {
                log("Failed to decode smart wake trigger payload", level: .error)
            }
        case WCMessageKey.sessionStateChanged:
            if let state = try? decoder.decode(SmartWakeSessionState.self, from: payloadData) {
                watchSessionState = state
                log(
                    "Received watch session state: state=\(state.state.rawValue), scheduleID=\(state.scheduleID?.uuidString ?? "none"), message=\(state.message ?? "none")"
                )
            } else {
                log("Failed to decode watch session state payload", level: .error)
            }
        case WCMessageKey.permissionStatus:
            if let status = try? decoder.decode(SmartWakePermissionStatus.self, from: payloadData) {
                watchPermissionStatus = status
                log(
                    "Received watch permission status: healthKitAuthorized=\(status.healthKitAuthorized), watchConnected=\(status.watchConnected)"
                )
            } else {
                log("Failed to decode watch permission status payload", level: .error)
            }
        case WCMessageKey.hapticPatternChanged:
            if let payload = try? decoder.decode(HapticPatternChangePayload.self, from: payloadData) {
                log("Received haptic pattern change for \(payload.scheduleID): \(payload.hapticPatternRaw)")
                onHapticPatternChanged?(payload)
            } else {
                log("Failed to decode haptic pattern change payload", level: .error)
            }
        case WCMessageKey.testTrigger:
            if let trigger = try? decoder.decode(SmartWakeTriggerPayload.self, from: payloadData) {
                log("Received test trigger \(trigger.triggerID) for \(trigger.scheduleID)")
                onTestTrigger?(trigger)
            } else {
                log("Failed to decode test trigger payload", level: .error)
            }
        default:
            log("Received unsupported watch message type '\(type)'", level: .warning)
        }
    }

    private func log(_ message: String, level: PhoneLogLevel = .info) {
        logStore.log("WatchConnectivity", message, level: level)
    }
}
