#if os(watchOS)
import Foundation
import WatchKit

enum SmartWakeArmingState: Equatable {
    case noUpcomingWake
    case armed(wakeUpTime: Date, monitoringStart: Date)
    case monitoringNow
    case backstopActive(wakeUpTime: Date)
    case needsForegroundToArm(wakeUpTime: Date)
    case tooEarlyToArm(wakeUpTime: Date, earliestArmingDate: Date)
    case failed(message: String)
}

enum SmartWakeAutoLaunchState: Equatable {
    case unknown
    case authorized
    case notAuthorized
    case unsupported
    case failed(message: String)
}

private struct PendingWake: Equatable {
    let schedule: WatchScheduleSnapshot
    let wakeUpTime: Date
    let windowStart: Date
    let baselineStart: Date
    let scheduledSessionStart: Date

    func matchesOccurrence(_ other: PendingWake) -> Bool {
        schedule.id == other.schedule.id
            && wakeUpTime == other.wakeUpTime
            && windowStart == other.windowStart
            && baselineStart == other.baselineStart
    }
}

@Observable
final class SmartAlarmScheduler: NSObject {
    private(set) var isAlarmSessionActive = false
    private(set) var scheduledMonitoringDate: Date?
    private(set) var alarmSessionError: String?
    private(set) var armingState: SmartWakeArmingState = .noUpcomingWake
    private(set) var autoLaunchState: SmartWakeAutoLaunchState

    private var extendedSession: WKExtendedRuntimeSession?
    private var pendingSchedule: PendingWake?
    private var recoveredRunningBackstopWake: PendingWake?

    private var currentSessionScheduleID: UUID?
    private var currentSessionWakeTime: Date?

    /// Tracks wakes that have been handled for the current occurrence — either
    /// triggered and completed, or manually stopped/failed. Prevents re-entry
    /// for the same occurrence after state returns to .idle.
    private var completedWakeOccurrence: (scheduleID: UUID, wakeUpTime: Date)?

    private let sessionController: SmartWakeSessionController
    private let sessionManager: WatchSessionManager
    private let logStore: SmartWakeLogStore
    private let pendingWakeStore: SmartWakePendingWakeStore

    /// Conservative budget for the extended runtime session. Apple grants ~30 min
    /// for smart-alarm sessions; we use 25 min to leave a safety margin for
    /// force-fire at wake time.
    private let safeSessionBudget: TimeInterval = 25 * 60

    /// Small buffer before the wake window start for workout/query setup.
    private let sessionSetupBuffer: TimeInterval = 120
    private let armingHorizon: TimeInterval = 35 * 3600

    init(
        sessionController: SmartWakeSessionController,
        sessionManager: WatchSessionManager,
        logStore: SmartWakeLogStore,
        pendingWakeStore: SmartWakePendingWakeStore = SmartWakePendingWakeStore()
    ) {
        self.sessionController = sessionController
        self.sessionManager = sessionManager
        self.logStore = logStore
        self.pendingWakeStore = pendingWakeStore
        self.autoLaunchState = Self.autoLaunchState(
            from: pendingWakeStore.loadAutoLaunchState()
        )
        super.init()

        sessionController.onTrigger = { [weak self] payload in
            self?.sessionManager.sendTrigger(payload)
            self?.handleWakeTriggered()
        }
        sessionController.onPostTriggerWorkComplete = { [weak self] in
            self?.cleanUpAfterCompletedWake()
        }
        sessionController.onMonitoringCancelled = { [weak self] in
            self?.handleMonitoringCancelled()
        }
        sessionController.onStateChange = { [weak self] state in
            self?.sessionManager.sendSessionState(state)
        }

        _ = loadPersistedPendingWakeRecord(
            reason: "Scheduler initialization checked for stale pending wake"
        )
        migratePersistedWakeTimingIfNeeded()
    }

    // MARK: - Auto-Launch Authorization

    func refreshAutoLaunchAuthorization(promptIfEligible: Bool) {
        let shouldPrompt = promptIfEligible && !pendingWakeStore.autoLaunchPromptAttempted
        let shouldRefreshStatus = shouldPrompt || pendingWakeStore.autoLaunchPromptAttempted

        guard shouldRefreshStatus else {
            autoLaunchState = Self.autoLaunchState(from: pendingWakeStore.loadAutoLaunchState())
            return
        }

        if shouldPrompt {
            pendingWakeStore.autoLaunchPromptAttempted = true
            logStore.log(
                "SCHEDULER",
                "Requesting Smart Wake auto-launch authorization status (prompt eligible=true)"
            )
        }

        WKExtendedRuntimeSession.requestAutoLaunchAuthorizationStatus { [weak self] status, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error = error as NSError? {
                    if error.domain == WKExtendedRuntimeSessionErrorDomain,
                       error.code == Int(
                           WKExtendedRuntimeSessionErrorCode.unsupportedSessionType.rawValue
                       ) {
                        self.updateAutoLaunchState(
                            .unsupported,
                            persistedState: .unsupported
                        )
                        self.logStore.log(
                            "SCHEDULER",
                            "Smart Wake auto-launch authorization unsupported for this session type",
                            level: .warning
                        )
                        return
                    }

                    self.autoLaunchState = .failed(message: error.localizedDescription)
                    self.pendingWakeStore.saveAutoLaunchState(.unknown)
                    self.logStore.log(
                        "SCHEDULER",
                        "Failed to refresh Smart Wake auto-launch authorization: \(error.localizedDescription)",
                        level: .error
                    )
                    return
                }

                switch status {
                case .active:
                    self.updateAutoLaunchState(.authorized, persistedState: .authorized)
                case .inactive:
                    self.updateAutoLaunchState(.notAuthorized, persistedState: .notAuthorized)
                case .unknown:
                    self.updateAutoLaunchState(.unknown, persistedState: .unknown)
                @unknown default:
                    self.updateAutoLaunchState(.unknown, persistedState: .unknown)
                }

                self.logStore.log(
                    "SCHEDULER",
                    "Smart Wake auto-launch authorization refreshed. state=\(self.describeAutoLaunchState(self.autoLaunchState))"
                )
            }
        }
    }

    // MARK: - Recovery

    func attachRecoveredExtendedRuntimeSession(_ session: WKExtendedRuntimeSession) {
        session.delegate = self
        logStore.log(
            "SCHEDULER",
            "Attaching recovered extended runtime session. state=\(session.state.rawValue)"
        )

        guard let record = loadPersistedPendingWakeRecord(
            reason: "Recovered extended runtime session looked up pending wake"
        ) else {
            logStore.log(
                "SCHEDULER",
                "Rejecting recovered extended runtime session because no valid pending wake record exists",
                level: .error
            )
            invalidateRecoveredSession(
                session,
                failureMessage: "Recovered session had no pending wake record"
            )
            return
        }

        let now = Date()
        guard now.timeIntervalSince(record.wakeUpTime) <= 7200 else {
            logStore.log(
                "SCHEDULER",
                "Rejecting recovered extended runtime session because the pending wake is stale",
                level: .error
            )
            invalidateRecoveredSession(
                session,
                failureMessage: "Recovered session was stale"
            )
            return
        }

        extendedSession = session
        restorePendingWakeState(
            from: record,
            reason: "recovered extended runtime session"
        )

        switch session.state {
        case .scheduled:
            isAlarmSessionActive = false
            sessionController.isAlarmSessionActive = false
            recoveredRunningBackstopWake = nil
            armingState = .armed(
                wakeUpTime: record.wakeUpTime,
                monitoringStart: record.baselineStart
            )
            logStore.log(
                "SCHEDULER",
                "Recovered scheduled extended runtime session for '\(record.schedule.name)'; waiting for didStart"
            )

        case .running:
            isAlarmSessionActive = true
            sessionController.isAlarmSessionActive = true

            if now < record.wakeUpTime {
                recoveredRunningBackstopWake = nil
                if sessionController.isMonitoringActive {
                    armingState = .monitoringNow
                    logStore.log(
                        "SCHEDULER",
                        "Recovered running session while monitoring was already active"
                    )
                } else if sessionController.sessionState == .triggered {
                    armingState = .monitoringNow
                    logStore.log(
                        "SCHEDULER",
                        "Recovered running session after trigger; keeping it as the execution backstop"
                    )
                } else {
                    logStore.log(
                        "SCHEDULER",
                        "Recovered running session before wake time; resuming monitoring immediately"
                    )
                    startMonitoringNow(
                        schedule: record.schedule,
                        wakeUpTime: record.wakeUpTime
                    )
                }
            } else {
                recoveredRunningBackstopWake = pendingWake(from: record)
                pendingSchedule = nil
                scheduledMonitoringDate = nil
                armingState = .backstopActive(wakeUpTime: record.wakeUpTime)
                logStore.log(
                    "SCHEDULER",
                    "Recovered running session after wake time; keeping it as a backstop without restarting monitoring",
                    level: .warning
                )
            }

        case .notStarted, .invalid:
            logStore.log(
                "SCHEDULER",
                "Recovered session had unusable state=\(session.state.rawValue)",
                level: .error
            )
            invalidateRecoveredSession(
                session,
                failureMessage: "Recovered session was unusable"
            )
        @unknown default:
            logStore.log(
                "SCHEDULER",
                "Recovered session had unknown state=\(session.state.rawValue)",
                level: .error
            )
            invalidateRecoveredSession(
                session,
                failureMessage: "Recovered session was unusable"
            )
        }
    }

    // MARK: - Schedule Evaluation

    func schedulesDidUpdate(_ schedules: [WatchScheduleSnapshot]) {
        // Don't reevaluate while a trigger is in progress — post-trigger work
        // (haptics, handoff, light fallback, workout teardown) needs the current
        // extended session as a background-execution backstop.
        guard sessionController.sessionState != .triggered else {
            logStore.log(
                "SCHEDULER",
                "Skipping schedule reevaluation — wake trigger in progress (will re-evaluate after cleanup)",
                level: .warning
            )
            return
        }

        pruneCompletedWake()
        let now = Date()

        if preserveRecoveredRunningBackstopIfNeeded(now: now) {
            return
        }

        let smartWakeSchedules = schedules.filter(\.usesSmartWake)

        guard let nextOccurrence = findNextRelevantOccurrence(smartWakeSchedules) else {
            if !sessionManager.hasLoadedInitialScheduleContext,
               let record = loadPersistedPendingWakeRecord(
                   reason: "No schedules available before initial WCSession hydration"
               ) {
                restorePendingWakeState(
                    from: record,
                    reason: "preserving pending wake before initial WCSession hydration"
                )
                armingState = .armed(
                    wakeUpTime: record.wakeUpTime,
                    monitoringStart: record.baselineStart
                )
                alarmSessionError = nil
                logStore.log(
                    "SCHEDULER",
                    "No upcoming schedules yet, but preserving the persisted pending wake until WCSession hydration completes",
                    level: .warning
                )
                return
            }

            logStore.log("SCHEDULER", "No upcoming smart wake schedules found", level: .warning)
            cancelAlarmSession(clearPersistedWake: true)
            armingState = .noUpcomingWake
            alarmSessionError = nil
            sessionController.updateNextScheduledWakeWindow(schedule: nil, wakeUpTime: nil)
            return
        }

        let nextSchedule = nextOccurrence.schedule
        let wakeUpTime = nextOccurrence.wakeUpTime

        let windowStart = wakeUpTime.addingTimeInterval(
            -Double(nextSchedule.smartWakeWindowMinutes) * 60
        )
        let baselineStart = computeSessionStart(
            windowStart: windowStart,
            wakeUpTime: wakeUpTime
        )
        let nextWake = PendingWake(
            schedule: nextSchedule,
            wakeUpTime: wakeUpTime,
            windowStart: windowStart,
            baselineStart: baselineStart,
            scheduledSessionStart: baselineStart
        )
        logStore.prepareSessionLogIfNeeded(
            schedule: nextSchedule,
            wakeUpTime: wakeUpTime,
            wakeWindowStart: windowStart,
            reason: "scheduler evaluation"
        )
        logStore.log(
            "SCHEDULER",
            "Evaluating next schedule '\(nextSchedule.name)' now=\(formatTimestamp(now)) wake=\(formatTimestamp(wakeUpTime)) windowStart=\(formatTimestamp(windowStart))"
        )

        sessionController.updateNextScheduledWakeWindow(
            schedule: nextSchedule,
            wakeUpTime: wakeUpTime
        )

        // Don't re-enter monitoring if a wake is already being handled
        if sessionController.isMonitoringActive,
           sessionController.currentScheduleID == nextSchedule.id {
            armingState = .monitoringNow
            scheduledMonitoringDate = nil
            logStore.log(
                "SCHEDULER",
                "Monitoring already active for '\(nextSchedule.name)'; skipping re-schedule"
            )
            return
        }

        if hasEquivalentArmedWake(for: nextWake) {
            let preservedSessionStart = scheduledMonitoringDate
                ?? pendingSchedule?.scheduledSessionStart
                ?? baselineStart
            let prematureBy = baselineStart.timeIntervalSince(preservedSessionStart)

            if prematureBy > 300 {
                logStore.log(
                    "SCHEDULER",
                    "Armed session for '\(nextSchedule.name)' is scheduled \(Int(prematureBy / 60)) min too early; cancelling and re-arming",
                    level: .warning
                )
            } else {
                pendingSchedule = PendingWake(
                    schedule: nextSchedule,
                    wakeUpTime: wakeUpTime,
                    windowStart: windowStart,
                    baselineStart: baselineStart,
                    scheduledSessionStart: preservedSessionStart
                )
                currentSessionScheduleID = nextSchedule.id
                currentSessionWakeTime = wakeUpTime
                alarmSessionError = nil
                armingState = .armed(wakeUpTime: wakeUpTime, monitoringStart: baselineStart)
                logStore.log(
                    "SCHEDULER",
                    "Extended runtime session already armed for '\(nextSchedule.name)'; refreshed pending payload without re-scheduling"
                )
                return
            }
        }

        if now >= baselineStart && now < wakeUpTime {
            logStore.log(
                "SCHEDULER",
                "Already inside the monitoring period for '\(nextSchedule.name)'; starting monitoring immediately"
            )
            scheduledMonitoringDate = nil
            startMonitoringNow(schedule: nextSchedule, wakeUpTime: wakeUpTime)
            return
        }

        if baselineStart.timeIntervalSince(now) > armingHorizon {
            clearStaleArmedWakeIfNeeded(
                comparedTo: nextWake,
                reason: "Wake moved outside the 35-hour arming horizon"
            )
            armingState = .tooEarlyToArm(
                wakeUpTime: wakeUpTime,
                earliestArmingDate: baselineStart.addingTimeInterval(-armingHorizon)
            )
            scheduledMonitoringDate = nil
            alarmSessionError = nil
            logStore.log(
                "SCHEDULER",
                "Wake '\(nextSchedule.name)' at \(formatTimestamp(wakeUpTime)) is beyond the 35-hour arming horizon; will re-evaluate later",
                level: .warning
            )
            return
        }

        let appState = WKApplication.shared().applicationState
        guard appState == .active else {
            if let record = equivalentPersistedPendingWake(
                for: nextWake,
                reason: "Inactive-app guard checked persisted pending wake"
            ) {
                restorePendingWakeState(
                    from: record,
                    reason: "preserving equivalent pending wake while app is inactive"
                )
                armingState = .armed(
                    wakeUpTime: wakeUpTime,
                    monitoringStart: baselineStart
                )
                alarmSessionError = nil
                logStore.log(
                    "SCHEDULER",
                    "Preserving equivalent recovered/persisted wake while the watch app is inactive"
                )
                return
            }

            clearStaleArmedWakeIfNeeded(
                comparedTo: nextWake,
                reason: "Upcoming wake changed while the watch app was inactive"
            )
            armingState = .needsForegroundToArm(wakeUpTime: wakeUpTime)
            scheduledMonitoringDate = nil
            alarmSessionError = nil
            logStore.log(
                "SCHEDULER",
                "Cannot arm extended runtime session — app is not active (state=\(appState.rawValue)). Will arm on next foreground.",
                level: .warning
            )
            return
        }

        let desiredSessionStart = max(baselineStart, now.addingTimeInterval(1))
        scheduleAlarmSession(
            at: desiredSessionStart,
            schedule: nextSchedule,
            wakeUpTime: wakeUpTime,
            windowStart: windowStart,
            baselineStart: baselineStart
        )
    }

    func onAppForeground() {
        logStore.log("SCHEDULER", "App returned to foreground — re-evaluating schedules")
        schedulesDidUpdate(sessionManager.activeSchedules)
    }

    // MARK: - Monitoring Lifecycle

    /// Called when monitoring ends without a trigger (manual stop or failure).
    /// Tears down the scheduler's extended runtime session and clears stale state
    /// so the idle session doesn't linger and future evaluations aren't blocked.
    private func handleMonitoringCancelled() {
        // Record the occurrence before cancelAlarmSession() clears the IDs,
        // so a later schedulesDidUpdate or onAppForeground can't re-arm
        // the same wake the user explicitly stopped.
        if let scheduleID = currentSessionScheduleID,
           let wakeTime = currentSessionWakeTime {
            completedWakeOccurrence = (scheduleID, wakeTime)
        }
        logStore.log(
            "SCHEDULER",
            "Monitoring cancelled — tearing down scheduler state"
        )
        cancelAlarmSession(clearPersistedWake: true)

        // Re-evaluate so the next occurrence gets scheduled. If the cancelled
        // wake is still in-window, completedWakeOccurrence blocks re-entry.
        // If it's past, the next future occurrence gets scheduled.
        let latestSchedules = sessionManager.activeSchedules
        logStore.log(
            "SCHEDULER",
            "Re-evaluating schedules after monitoring cancellation (\(latestSchedules.count) schedule(s))"
        )
        schedulesDidUpdate(latestSchedules)
    }

    /// Called immediately when the session controller fires a wake trigger.
    /// Prevents the scheduler from re-entering monitoring for this wake.
    private func handleWakeTriggered() {
        if let scheduleID = currentSessionScheduleID,
           let wakeTime = currentSessionWakeTime {
            completedWakeOccurrence = (scheduleID, wakeTime)
        }
        pendingSchedule = nil
        scheduledMonitoringDate = nil
        armingState = .monitoringNow
        logStore.log(
            "SCHEDULER",
            "Wake triggered — cleared pending monitoring state to prevent re-entry"
        )
    }

    /// Called after all post-trigger work (haptics, handoff, light fallback, workout teardown) completes.
    /// Fully resets scheduler state so the next wake can be scheduled cleanly.
    private func cleanUpAfterCompletedWake() {
        logStore.log("SCHEDULER", "Post-trigger work complete — cleaning up scheduler state")

        let sessionToInvalidate = extendedSession
        if let sessionToInvalidate,
           sessionToInvalidate.state == .running || sessionToInvalidate.state == .scheduled {
            logStore.log(
                "SCHEDULER",
                "Invalidating extended runtime session (state=\(sessionToInvalidate.state.rawValue))"
            )
        }

        clearSchedulerState(clearPersistedWake: true, resetArmingState: true)
        sessionToInvalidate?.invalidate()

        // Re-evaluate with the latest cached schedules so the next occurrence
        // gets scheduled immediately. Without this, the next wake would only
        // be scheduled when the phone pushes schedules or the app comes to
        // foreground — both of which the phone suppresses if schedules haven't
        // changed (WatchConnectivityService.flushCachedSchedulesContext).
        let latestSchedules = sessionManager.activeSchedules
        logStore.log(
            "SCHEDULER",
            "Re-evaluating schedules after wake completion (\(latestSchedules.count) schedule(s))"
        )
        schedulesDidUpdate(latestSchedules)
    }

    /// Clears stale completed-wake records (wake time > 2 hours in the past).
    private func pruneCompletedWake() {
        guard let completed = completedWakeOccurrence else { return }
        if Date().timeIntervalSince(completed.wakeUpTime) > 7200 {
            completedWakeOccurrence = nil
        }
    }

    // MARK: - Extended Runtime Session

    private func scheduleAlarmSession(
        at date: Date,
        schedule: WatchScheduleSnapshot,
        wakeUpTime: Date,
        windowStart: Date,
        baselineStart: Date
    ) {
        cancelAlarmSession(clearPersistedWake: true)

        let session = WKExtendedRuntimeSession()
        session.delegate = self

        let wake = PendingWake(
            schedule: schedule,
            wakeUpTime: wakeUpTime,
            windowStart: windowStart,
            baselineStart: baselineStart,
            scheduledSessionStart: date
        )

        extendedSession = session
        currentSessionScheduleID = schedule.id
        currentSessionWakeTime = wakeUpTime
        pendingSchedule = wake
        recoveredRunningBackstopWake = nil
        savePendingWakeRecord(for: wake)
        session.start(at: date)

        scheduledMonitoringDate = date
        alarmSessionError = nil
        armingState = .armed(wakeUpTime: wakeUpTime, monitoringStart: baselineStart)
        logStore.log(
            "SCHEDULER",
            "Scheduled extended runtime session for '\(schedule.name)' at \(formatTimestamp(date)). monitoringStart=\(formatTimestamp(baselineStart))"
        )
    }

    /// Best-effort: cancel the current premature session and re-schedule at the
    /// correct time. If watchOS refuses start(at:) from a background context,
    /// the wake falls back to the HomeKit wake-time scene.
    private func rescheduleAlarmSession(
        pending: PendingWake,
        correctStart: Date
    ) {
        let schedule = pending.schedule
        let wakeUpTime = pending.wakeUpTime
        let windowStart = pending.windowStart

        cancelAlarmSession(clearPersistedWake: true)

        let newSession = WKExtendedRuntimeSession()
        newSession.delegate = self

        let newWake = PendingWake(
            schedule: schedule,
            wakeUpTime: wakeUpTime,
            windowStart: windowStart,
            baselineStart: correctStart,
            scheduledSessionStart: correctStart
        )

        extendedSession = newSession
        currentSessionScheduleID = schedule.id
        currentSessionWakeTime = wakeUpTime
        pendingSchedule = newWake
        savePendingWakeRecord(for: newWake)

        newSession.start(at: correctStart)

        scheduledMonitoringDate = correctStart
        alarmSessionError = nil
        armingState = .armed(wakeUpTime: wakeUpTime, monitoringStart: correctStart)
        logStore.log(
            "SCHEDULER",
            "Re-scheduled session for '\(schedule.name)' at \(formatTimestamp(correctStart))"
        )
    }

    private func cancelAlarmSession(clearPersistedWake: Bool) {
        let sessionToInvalidate = extendedSession
        let invalidatedState = sessionToInvalidate?.state

        clearSchedulerState(
            clearPersistedWake: clearPersistedWake,
            resetArmingState: true
        )
        sessionToInvalidate?.invalidate()

        if let invalidatedState {
            logStore.log(
                "SCHEDULER",
                "Cancelled any pending extended runtime session (previous state=\(invalidatedState.rawValue))"
            )
        } else {
            logStore.log("SCHEDULER", "Cancelled any pending extended runtime session")
        }
    }

    private func clearSchedulerState(
        clearPersistedWake: Bool,
        resetArmingState: Bool
    ) {
        if clearPersistedWake {
            pendingWakeStore.clearPendingWakeRecord()
        }

        extendedSession = nil
        pendingSchedule = nil
        recoveredRunningBackstopWake = nil
        currentSessionScheduleID = nil
        currentSessionWakeTime = nil
        isAlarmSessionActive = false
        sessionController.isAlarmSessionActive = false
        scheduledMonitoringDate = nil
        alarmSessionError = nil

        if resetArmingState {
            armingState = .noUpcomingWake
        }
    }

    private func invalidateRecoveredSession(
        _ session: WKExtendedRuntimeSession,
        failureMessage: String
    ) {
        clearSchedulerState(clearPersistedWake: true, resetArmingState: false)
        session.invalidate()
        armingState = .failed(message: failureMessage)
    }

    private func startMonitoringNow(schedule: WatchScheduleSnapshot, wakeUpTime: Date) {
        guard !sessionController.isMonitoringActive else {
            logStore.log(
                "SCHEDULER",
                "startMonitoringNow ignored because monitoring is already active",
                level: .warning
            )
            return
        }

        guard sessionController.sessionState != .triggered else {
            logStore.log(
                "SCHEDULER",
                "startMonitoringNow ignored — wake already triggered and post-trigger work in progress",
                level: .warning
            )
            return
        }

        // Ensure the scheduler always knows which wake is being monitored,
        // so handleWakeTriggered() can persist it into completedWakeOccurrence.
        // (The "already inside wake window" path in schedulesDidUpdate skips
        // scheduleAlarmSession, which is the other place these are set.)
        currentSessionScheduleID = schedule.id
        currentSessionWakeTime = wakeUpTime

        pendingSchedule = nil
        recoveredRunningBackstopWake = nil
        scheduledMonitoringDate = nil
        alarmSessionError = nil
        armingState = .monitoringNow

        sessionController.hapticPatternType =
            HapticPattern(rawValue: schedule.hapticPatternRaw) ?? .gentle

        Task {
            await sessionController.startMonitoring(
                schedule: schedule,
                wakeUpTime: wakeUpTime
            )
            logStore.log(
                "SCHEDULER",
                "HR monitoring started for '\(schedule.name)' with haptic=\(sessionController.hapticPatternType.displayName)"
            )
        }
    }

    private func formatTimestamp(_ date: Date?) -> String {
        guard let date else { return "--" }
        return Self.timestampFormatter.string(from: date)
    }

    private func describeAutoLaunchState(_ state: SmartWakeAutoLaunchState) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .authorized:
            return "authorized"
        case .notAuthorized:
            return "notAuthorized"
        case .unsupported:
            return "unsupported"
        case .failed:
            return "failed"
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        formatter.timeZone = .current
        return formatter
    }()

    // MARK: - Schedule Helpers

    /// Compute the session start time to maximize wake-window coverage within
    /// the smart-alarm session budget.
    private func computeSessionStart(windowStart: Date, wakeUpTime: Date) -> Date {
        let idealStart = windowStart.addingTimeInterval(-sessionSetupBuffer)
        let latestViableStart = wakeUpTime.addingTimeInterval(-safeSessionBudget)
        return max(idealStart, latestViableStart)
    }

    /// One-time migration for persisted wakes saved with the old one-hour lead
    /// time. This keeps inactive-app recovery aligned with the new timing.
    private func migratePersistedWakeTimingIfNeeded() {
        guard let record = pendingWakeStore.loadPendingWakeRecord() else { return }
        guard Date().timeIntervalSince(record.wakeUpTime) <= 7200 else { return }

        let correctStart = computeSessionStart(
            windowStart: record.windowStart,
            wakeUpTime: record.wakeUpTime
        )
        guard record.baselineStart != correctStart else { return }

        let migrated = SmartWakePendingWakeRecord(
            schedule: record.schedule,
            wakeUpTime: record.wakeUpTime,
            windowStart: record.windowStart,
            baselineStart: correctStart,
            scheduledSessionStart: record.scheduledSessionStart,
            savedAt: record.savedAt
        )
        pendingWakeStore.savePendingWakeRecord(migrated)
        logStore.log(
            "SCHEDULER",
            "Migrated persisted wake timing from \(formatTimestamp(record.baselineStart)) to \(formatTimestamp(correctStart))"
        )
    }

    private func findNextRelevantOccurrence(
        _ schedules: [WatchScheduleSnapshot]
    ) -> (schedule: WatchScheduleSnapshot, wakeUpTime: Date)? {
        schedules
            .compactMap { schedule -> (WatchScheduleSnapshot, Date)? in
                guard let wakeTime = nextWakeTime(for: schedule) else { return nil }
                return (schedule, wakeTime)
            }
            .sorted { $0.1 < $1.1 }
            .first
    }

    private func nextWakeTime(for schedule: WatchScheduleSnapshot) -> Date? {
        let calendar = Calendar.current
        let now = Date()

        for dayOffset in 0..<8 {
            guard let candidateDate = calendar.date(
                byAdding: .day,
                value: dayOffset,
                to: now
            ) else { continue }

            let weekday = calendar.component(.weekday, from: candidateDate)
            guard schedule.activeDaysRaw.contains(weekday) else { continue }

            var components = calendar.dateComponents([.year, .month, .day], from: candidateDate)
            components.hour = schedule.wakeUpHour
            components.minute = schedule.wakeUpMinute
            components.second = 0

            guard let wakeUpTime = calendar.date(from: components) else { continue }
            guard wakeUpTime > now else { continue }

            if let completedOccurrence = completedWakeOccurrence,
               completedOccurrence.scheduleID == schedule.id,
               completedOccurrence.wakeUpTime == wakeUpTime {
                continue
            }

            return wakeUpTime
        }

        return nil
    }

    private func hasEquivalentArmedWake(for wake: PendingWake) -> Bool {
        guard let pendingSchedule,
              let extendedSession,
              extendedSession.state == .scheduled || extendedSession.state == .running else {
            return false
        }

        return pendingSchedule.matchesOccurrence(wake)
    }

    private func preserveRecoveredRunningBackstopIfNeeded(now: Date) -> Bool {
        guard let backstopWake = recoveredRunningBackstopWake,
              let extendedSession,
              extendedSession.state == .running,
              now >= backstopWake.wakeUpTime,
              !sessionController.isMonitoringActive,
              sessionController.sessionState != .triggered else {
            return false
        }

        currentSessionScheduleID = backstopWake.schedule.id
        currentSessionWakeTime = backstopWake.wakeUpTime
        scheduledMonitoringDate = nil
        alarmSessionError = nil

        if armingState != .backstopActive(wakeUpTime: backstopWake.wakeUpTime) {
            logStore.log(
                "SCHEDULER",
                "Preserving recovered post-wake backstop session for '\(backstopWake.schedule.name)' until the session invalidates"
            )
        }

        armingState = .backstopActive(wakeUpTime: backstopWake.wakeUpTime)
        return true
    }

    private func equivalentPersistedPendingWake(
        for wake: PendingWake,
        reason: String
    ) -> SmartWakePendingWakeRecord? {
        guard let record = loadPersistedPendingWakeRecord(reason: reason) else { return nil }
        return pendingWake(from: record).matchesOccurrence(wake) ? record : nil
    }

    private func clearStaleArmedWakeIfNeeded(comparedTo wake: PendingWake, reason: String) {
        if let pendingSchedule, !pendingSchedule.matchesOccurrence(wake) {
            logStore.log(
                "SCHEDULER",
                "\(reason); cancelling stale armed wake before waiting for foreground re-arm",
                level: .warning
            )
            cancelAlarmSession(clearPersistedWake: true)
            return
        }

        guard let record = loadPersistedPendingWakeRecord(reason: reason) else { return }
        guard !pendingWake(from: record).matchesOccurrence(wake) else { return }

        if extendedSession != nil {
            logStore.log(
                "SCHEDULER",
                "\(reason); invalidating stale recovered wake before waiting for foreground re-arm",
                level: .warning
            )
            cancelAlarmSession(clearPersistedWake: true)
        } else {
            clearPersistedPendingWakeRecord(
                reason: "\(reason); clearing stale persisted wake before waiting for foreground re-arm"
            )
            pendingSchedule = nil
            recoveredRunningBackstopWake = nil
            currentSessionScheduleID = nil
            currentSessionWakeTime = nil
            scheduledMonitoringDate = nil
        }
    }

    private func restorePendingWakeState(
        from record: SmartWakePendingWakeRecord,
        reason: String
    ) {
        let wake = pendingWake(from: record)
        pendingSchedule = wake
        currentSessionScheduleID = wake.schedule.id
        currentSessionWakeTime = wake.wakeUpTime
        scheduledMonitoringDate = wake.scheduledSessionStart
        alarmSessionError = nil

        logStore.prepareSessionLogIfNeeded(
            schedule: wake.schedule,
            wakeUpTime: wake.wakeUpTime,
            wakeWindowStart: wake.windowStart,
            reason: reason
        )
        sessionController.updateNextScheduledWakeWindow(
            schedule: wake.schedule,
            wakeUpTime: wake.wakeUpTime
        )
    }

    private func pendingWake(from record: SmartWakePendingWakeRecord) -> PendingWake {
        PendingWake(
            schedule: record.schedule,
            wakeUpTime: record.wakeUpTime,
            windowStart: record.windowStart,
            baselineStart: record.baselineStart,
            scheduledSessionStart: record.scheduledSessionStart
        )
    }

    private func savePendingWakeRecord(for wake: PendingWake) {
        pendingWakeStore.savePendingWakeRecord(
            SmartWakePendingWakeRecord(
                schedule: wake.schedule,
                wakeUpTime: wake.wakeUpTime,
                windowStart: wake.windowStart,
                baselineStart: wake.baselineStart,
                scheduledSessionStart: wake.scheduledSessionStart,
                savedAt: Date()
            )
        )
        logStore.log(
            "SCHEDULER",
            "Persisted pending wake for '\(wake.schedule.name)' at \(formatTimestamp(wake.wakeUpTime))"
        )
    }

    private func loadPersistedPendingWakeRecord(
        reason: String
    ) -> SmartWakePendingWakeRecord? {
        guard let record = pendingWakeStore.loadPendingWakeRecord() else { return nil }

        guard Date().timeIntervalSince(record.wakeUpTime) <= 7200 else {
            clearPersistedPendingWakeRecord(
                reason: "\(reason); pending wake record is stale"
            )
            return nil
        }

        return record
    }

    private func clearPersistedPendingWakeRecord(reason: String) {
        guard pendingWakeStore.loadPendingWakeRecord() != nil else { return }
        pendingWakeStore.clearPendingWakeRecord()
        logStore.log("SCHEDULER", reason, level: .warning)
    }

    private func updateAutoLaunchState(
        _ state: SmartWakeAutoLaunchState,
        persistedState: PersistedSmartWakeAutoLaunchState
    ) {
        autoLaunchState = state
        pendingWakeStore.saveAutoLaunchState(persistedState)
    }

    private static func autoLaunchState(
        from persistedState: PersistedSmartWakeAutoLaunchState?
    ) -> SmartWakeAutoLaunchState {
        switch persistedState {
        case .authorized:
            return .authorized
        case .notAuthorized:
            return .notAuthorized
        case .unsupported:
            return .unsupported
        case .unknown:
            return .unknown
        case nil:
            return .unknown
        }
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension SmartAlarmScheduler: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(
        _ extendedRuntimeSession: WKExtendedRuntimeSession
    ) {
        Task { @MainActor in
            guard extendedRuntimeSession === self.extendedSession else {
                self.logStore.log(
                    "SCHEDULER",
                    "Ignoring didStart from stale extended runtime session",
                    level: .warning
                )
                return
            }
            self.isAlarmSessionActive = true
            self.sessionController.isAlarmSessionActive = true
            self.logStore.log("SCHEDULER", "Extended runtime session is now running")

            if self.sessionController.isMonitoringActive {
                self.logStore.log(
                    "SCHEDULER",
                    "Extended runtime session started while monitoring was already active; keeping it as a background-execution backstop"
                )
                return
            }

            // If a trigger already fired and post-trigger work is in progress,
            // keep session as execution backstop but don't restart monitoring.
            if self.sessionController.sessionState == .triggered {
                self.logStore.log(
                    "SCHEDULER",
                    "Safety-net session started; wake already triggered — keeping as background-execution backstop for post-trigger work"
                )
                return
            }

            if let pending = self.pendingSchedule {
                let correctStart = self.computeSessionStart(
                    windowStart: pending.windowStart,
                    wakeUpTime: pending.wakeUpTime
                )
                let prematureBy = correctStart.timeIntervalSince(Date())

                if prematureBy > 300 {
                    self.logStore.log(
                        "SCHEDULER",
                        "Session started \(Int(prematureBy / 60)) min before computed start (\(self.formatTimestamp(correctStart))); attempting re-schedule",
                        level: .warning
                    )
                    self.rescheduleAlarmSession(
                        pending: pending,
                        correctStart: correctStart
                    )
                } else {
                    self.startMonitoringNow(
                        schedule: pending.schedule,
                        wakeUpTime: pending.wakeUpTime
                    )
                }
            }
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(
        _ extendedRuntimeSession: WKExtendedRuntimeSession
    ) {
        Task { @MainActor in
            guard extendedRuntimeSession === self.extendedSession else {
                self.logStore.log(
                    "SCHEDULER",
                    "Ignoring willExpire from stale extended runtime session",
                    level: .warning
                )
                return
            }
            self.logStore.log(
                "SCHEDULER",
                "Extended runtime session will expire soon",
                level: .warning
            )
            if !self.sessionController.isMonitoringActive,
               self.sessionController.sessionState != .triggered,
               let pending = self.pendingSchedule {
                // Session expiring before monitoring started — last chance to start it.
                self.startMonitoringNow(schedule: pending.schedule, wakeUpTime: pending.wakeUpTime)
            } else if self.sessionController.isMonitoringActive,
                      self.sessionController.sessionState != .triggered {
                self.logStore.log(
                    "SCHEDULER",
                    "Session expiring while monitoring is active — forcing immediate wake check",
                    level: .warning
                )
                self.sessionController.forceImmediateWakeCheck()
            }
        }
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: (any Error)?
    ) {
        Task { @MainActor in
            guard extendedRuntimeSession === self.extendedSession else {
                self.logStore.log(
                    "SCHEDULER",
                    "Ignoring didInvalidate from stale extended runtime session (reason=\(reason.rawValue))",
                    level: .warning
                )
                return
            }
            self.isAlarmSessionActive = false
            self.sessionController.isAlarmSessionActive = false
            self.extendedSession = nil
            self.scheduledMonitoringDate = nil
            let invalidatedRecoveredBackstop = self.recoveredRunningBackstopWake

            if let error {
                self.alarmSessionError = error.localizedDescription
                self.logStore.log(
                    "SCHEDULER",
                    "Extended runtime session invalidated with error: \(error.localizedDescription)",
                    level: .error
                )
            } else {
                self.logStore.log(
                    "SCHEDULER",
                    "Extended runtime session invalidated. reason=\(reason.rawValue)",
                    level: .warning
                )
            }

            if self.pendingSchedule != nil {
                self.armingState = .failed(message: "Session lost — will re-arm on next foreground")
                self.logStore.log(
                    "SCHEDULER",
                    "Extended runtime session invalidated but pending wake preserved — will re-arm on next foreground",
                    level: .warning
                )
            } else if let recoveredBackstop = invalidatedRecoveredBackstop {
                self.clearPersistedPendingWakeRecord(
                    reason: "Recovered post-wake backstop invalidated; clearing persisted wake record"
                )
                self.recoveredRunningBackstopWake = nil
                self.currentSessionScheduleID = nil
                self.currentSessionWakeTime = nil
                self.armingState = .failed(message: "Recovered backstop session ended")
                self.logStore.log(
                    "SCHEDULER",
                    "Recovered post-wake backstop invalidated for '\(recoveredBackstop.schedule.name)'; re-evaluating schedules",
                    level: .warning
                )
                self.schedulesDidUpdate(self.sessionManager.activeSchedules)
            } else if self.sessionController.isMonitoringActive,
                      self.sessionController.sessionState != .triggered {
                self.logStore.log(
                    "SCHEDULER",
                    "Extended runtime session invalidated during active monitoring — forcing final wake check",
                    level: .warning
                )
                self.sessionController.forceImmediateWakeCheck()
                if self.sessionController.sessionState != .triggered {
                    self.sessionController.tearDownMonitoringWithoutCompletion()
                    self.armingState = .failed(message: "Session expired during monitoring")
                }
            } else if self.sessionController.sessionState == .triggered {
                self.armingState = .monitoringNow
            } else if let error {
                self.armingState = .failed(message: error.localizedDescription)
            } else {
                self.armingState = .failed(message: "Extended runtime session invalidated")
            }
        }
    }
}
#endif
