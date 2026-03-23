import Foundation
import WatchConnectivity

@Observable
final class WatchSessionManager: NSObject, WCSessionDelegate {
    var activeSchedules: [WatchScheduleSnapshot] = []
    var isPhoneReachable: Bool = false
    var lastLightHandoff: SmartWakeLightHandoffPayload?
    private(set) var hasLoadedInitialScheduleContext = false
    private(set) var powerMode: SmartWakePowerMode = SmartWakeSharedStore.loadPowerMode()

    /// Called whenever schedules are received (including from background WCSession delivery).
    var onSchedulesUpdated: (([WatchScheduleSnapshot]) -> Void)?
    var onLightHandoff: ((SmartWakeLightHandoffPayload) -> Void)?

    private let logStore: SmartWakeLogStore
    private var session: WCSession?
    private var hasProcessedIncomingApplicationContext = false
    private var lastProcessedSyncPayload: Data?

    init(logStore: SmartWakeLogStore) {
        self.logStore = logStore
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
        logStore.log(
            "CONNECTIVITY",
            "Sending smart wake trigger \(payload.triggerID.uuidString) to phone"
        )
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
                session.sendMessage(message, replyHandler: nil) { [weak self] error in
                    self?.logStore.log(
                        "CONNECTIVITY",
                        "sendMessage failed for session state, falling back to transferUserInfo: \(error.localizedDescription)",
                        level: .warning
                    )
                    session.transferUserInfo(message)
                }
            } else {
                session.transferUserInfo(message)
            }
        } catch {
            logStore.log(
                "CONNECTIVITY",
                "Failed to send session state: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    func sendHapticPatternChange(scheduleID: UUID, pattern: String) {
        let payload = HapticPatternChangePayload(scheduleID: scheduleID, hapticPatternRaw: pattern)
        sendBestEffortMessage(payload, type: WCMessageKey.hapticPatternChanged)
    }

    func sendTestTrigger(_ payload: SmartWakeTriggerPayload) {
        logStore.log(
            "CONNECTIVITY",
            "Sending watch test trigger \(payload.triggerID.uuidString) to phone"
        )
        sendRealtimeMessage(payload, type: WCMessageKey.testTrigger)
    }

    func sendHeartRateStatus(active: Bool) {
        guard let session else { return }

        do {
            let status = SmartWakePermissionStatus(
                heartRateDataActive: active,
                watchConnected: true
            )
            let data = try JSONEncoder().encode(status)
            let message: [String: Any] = [
                WCMessageKey.type: WCMessageKey.permissionStatus,
                WCMessageKey.payload: data
            ]

            if session.isReachable {
                session.sendMessage(message, replyHandler: nil) { [weak self] error in
                    self?.logStore.log(
                        "CONNECTIVITY",
                        "sendMessage failed for heart rate status, falling back to transferUserInfo: \(error.localizedDescription)",
                        level: .warning
                    )
                    session.transferUserInfo(message)
                }
            } else {
                session.transferUserInfo(message)
            }
        } catch {
            logStore.log(
                "CONNECTIVITY",
                "Failed to send heart rate status: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    func transferLogFile(_ url: URL) {
        guard let session else {
            logStore.noteFailedTransfer(for: url.lastPathComponent, error: "WCSession unavailable")
            return
        }

        let fileName = url.lastPathComponent
        let metadata: [String: Any] = [
            "kind": "smartWakeLog",
            "filename": fileName
        ]

        do {
            let snapshotURL = try logStore.prepareTransferSnapshot(for: url)
            session.transferFile(snapshotURL, metadata: metadata)
            logStore.noteQueuedTransfer(for: url)
            logStore.log(
                "CONNECTIVITY",
                "Queued watch log transfer to iPhone: \(fileName)"
            )
        } catch {
            logStore.noteFailedTransfer(for: fileName, error: error.localizedDescription)
            logStore.log(
                "CONNECTIVITY",
                "Failed to queue watch log transfer for \(fileName): \(error.localizedDescription)",
                level: .error
            )
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
                self.logStore.log("CONNECTIVITY", "\(type) sent successfully. reply=\(reply)")
            }, errorHandler: { error in
                self.logStore.log(
                    "CONNECTIVITY",
                    "sendMessage failed for \(type): \(error.localizedDescription). Falling back to transferUserInfo.",
                    level: .warning
                )
                session.transferUserInfo(message)
            })
        } catch {
            logStore.log(
                "CONNECTIVITY",
                "Failed to encode \(type): \(error.localizedDescription)",
                level: .error
            )
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
                    self.logStore.log(
                        "CONNECTIVITY",
                        "sendMessage failed for \(type): \(error.localizedDescription). Falling back to transferUserInfo.",
                        level: .warning
                    )
                    session.transferUserInfo(message)
                }
            } else {
                session.transferUserInfo(message)
                logStore.log(
                    "CONNECTIVITY",
                    "Phone not reachable. Queued \(type) via transferUserInfo",
                    level: .warning
                )
            }
        } catch {
            logStore.log(
                "CONNECTIVITY",
                "Failed to encode \(type): \(error.localizedDescription)",
                level: .error
            )
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
            self.logStore.log(
                "CONNECTIVITY",
                "WCSession activated. state=\(activationState.rawValue) reachable=\(session.isReachable)"
            )
            guard !self.hasProcessedIncomingApplicationContext else { return }
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
            self.hasProcessedIncomingApplicationContext = true
            self.processApplicationContext(applicationContext)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isPhoneReachable = session.isReachable
            self.logStore.log(
                "CONNECTIVITY",
                "Phone reachability changed. reachable=\(session.isReachable)"
            )
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

        guard lastProcessedSyncPayload != data else { return }

        do {
            let decoder = JSONDecoder()
            let syncPayload: SmartWakeSyncPayload
            if let decoded = try? decoder.decode(SmartWakeSyncPayload.self, from: data) {
                syncPayload = decoded
            } else {
                let schedules = try decoder.decode([WatchScheduleSnapshot].self, from: data)
                syncPayload = SmartWakeSyncPayload(
                    schedules: schedules,
                    powerMode: powerMode
                )
            }

            lastProcessedSyncPayload = data
            powerMode = syncPayload.powerMode
            SmartWakeSharedStore.savePowerMode(syncPayload.powerMode)
            activeSchedules = syncPayload.schedules
            hasLoadedInitialScheduleContext = true
            onSchedulesUpdated?(syncPayload.schedules)
            logStore.log(
                "CONNECTIVITY",
                "Received \(syncPayload.schedules.count) smart-wake schedule snapshot(s) from phone with powerMode=\(syncPayload.powerMode.rawValue)"
            )
        } catch {
            logStore.log(
                "CONNECTIVITY",
                "Failed to decode schedules: \(error.localizedDescription)",
                level: .error
            )
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
                logStore.log(
                    "CONNECTIVITY",
                    "Received phone handoff for trigger \(payload.triggerID.uuidString). phoneWillHandleLights=\(payload.phoneWillHandleLights)"
                )
            } catch {
                logStore.log(
                    "CONNECTIVITY",
                    "Failed to decode phone handoff: \(error.localizedDescription)",
                    level: .error
                )
            }
        default:
            break
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        Task { @MainActor in
            let fileName = (fileTransfer.file.metadata?["filename"] as? String)
                ?? fileTransfer.file.fileURL.lastPathComponent
            self.logStore.cleanupTransferSnapshot(at: fileTransfer.file.fileURL)
            if let error {
                self.logStore.noteFailedTransfer(for: fileName, error: error.localizedDescription)
                self.logStore.log(
                    "CONNECTIVITY",
                    "Watch log transfer failed for \(fileName): \(error.localizedDescription)",
                    level: .error
                )
            } else {
                self.logStore.noteCompletedTransfer(for: fileName)
                self.logStore.log(
                    "CONNECTIVITY",
                    "Watch log transfer finished for \(fileName)"
                )
            }
        }
    }
}
