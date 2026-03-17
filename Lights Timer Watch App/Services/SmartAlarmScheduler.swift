#if os(watchOS)
import Foundation
import WatchKit

enum SmartWakeArmingState: Equatable {
    case noUpcomingWake
    case armed(wakeUpTime: Date, monitoringStart: Date)
    case monitoringNow
    case needsForegroundToArm(wakeUpTime: Date)
    case tooEarlyToArm(wakeUpTime: Date, earliestArmingDate: Date)
    case failed(message: String)
}

private struct PendingWake {
    let schedule: WatchScheduleSnapshot
    let wakeUpTime: Date
    let windowStart: Date
    let baselineStart: Date
}

@Observable
final class SmartAlarmScheduler: NSObject {
    private(set) var isAlarmSessionActive = false
    private(set) var scheduledMonitoringDate: Date?
    private(set) var alarmSessionError: String?
    private(set) var armingState: SmartWakeArmingState = .noUpcomingWake

    private var extendedSession: WKExtendedRuntimeSession?
    private var pendingSchedule: PendingWake?

    private var currentSessionScheduleID: UUID?
    private var currentSessionWakeTime: Date?

    /// Tracks wakes that have been handled for the current occurrence — either
    /// triggered and completed, or manually stopped/failed. Prevents re-entry
    /// for the same occurrence after state returns to .idle.
    private var completedWakeOccurrence: (scheduleID: UUID, wakeUpTime: Date)?

    private let sessionController: SmartWakeSessionController
    private let sessionManager: WatchSessionManager
    private let logStore: SmartWakeLogStore

    private let baselineCollectionLeadTime: TimeInterval = 3600
    private let armingHorizon: TimeInterval = 35 * 3600

    init(
        sessionController: SmartWakeSessionController,
        sessionManager: WatchSessionManager,
        logStore: SmartWakeLogStore
    ) {
        self.sessionController = sessionController
        self.sessionManager = sessionManager
        self.logStore = logStore
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
        let smartWakeSchedules = schedules.filter(\.usesSmartWake)

        guard let nextOccurrence = findNextRelevantOccurrence(smartWakeSchedules) else {
            logStore.log("SCHEDULER", "No upcoming smart wake schedules found", level: .warning)
            cancelAlarmSession()
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
        let baselineStart = windowStart.addingTimeInterval(-baselineCollectionLeadTime)
        let nextWake = PendingWake(
            schedule: nextSchedule,
            wakeUpTime: wakeUpTime,
            windowStart: windowStart,
            baselineStart: baselineStart
        )
        let now = Date()
        logStore.prepareSessionLog(
            schedule: nextSchedule,
            wakeUpTime: wakeUpTime,
            wakeWindowStart: windowStart,
            reason: "scheduler evaluation"
        )
        logStore.log(
            "SCHEDULER",
            "Evaluating next schedule '\(nextSchedule.name)' now=\(formatTimestamp(now)) wake=\(formatTimestamp(wakeUpTime)) windowStart=\(formatTimestamp(windowStart))"
        )

        sessionController.updateNextScheduledWakeWindow(schedule: nextSchedule, wakeUpTime: wakeUpTime)

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
            pendingSchedule = nextWake
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
        cancelAlarmSession()

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

        if let extendedSession,
           extendedSession.state == .running || extendedSession.state == .scheduled {
            logStore.log(
                "SCHEDULER",
                "Invalidating extended runtime session (state=\(extendedSession.state.rawValue))"
            )
            extendedSession.invalidate()
        }

        extendedSession = nil
        pendingSchedule = nil
        currentSessionScheduleID = nil
        currentSessionWakeTime = nil
        isAlarmSessionActive = false
        sessionController.isAlarmSessionActive = false
        scheduledMonitoringDate = nil
        alarmSessionError = nil

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
        cancelAlarmSession()

        let session = WKExtendedRuntimeSession()
        session.delegate = self
        extendedSession = session
        currentSessionScheduleID = schedule.id
        currentSessionWakeTime = wakeUpTime
        pendingSchedule = PendingWake(
            schedule: schedule,
            wakeUpTime: wakeUpTime,
            windowStart: windowStart,
            baselineStart: baselineStart
        )
        session.start(at: date)

        scheduledMonitoringDate = date
        alarmSessionError = nil
        armingState = .armed(wakeUpTime: wakeUpTime, monitoringStart: baselineStart)
        logStore.log(
            "SCHEDULER",
            "Scheduled extended runtime session for '\(schedule.name)' at \(formatTimestamp(date)). baselineStart=\(formatTimestamp(baselineStart))"
        )
    }

    private func cancelAlarmSession() {
        if let extendedSession {
            extendedSession.invalidate()
        }

        extendedSession = nil
        pendingSchedule = nil
        currentSessionScheduleID = nil
        currentSessionWakeTime = nil
        isAlarmSessionActive = false
        sessionController.isAlarmSessionActive = false
        scheduledMonitoringDate = nil
        alarmSessionError = nil
        armingState = .noUpcomingWake
        logStore.log("SCHEDULER", "Cancelled any pending extended runtime session")
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
        scheduledMonitoringDate = nil
        alarmSessionError = nil
        armingState = .monitoringNow

        sessionController.hapticPatternType = HapticPattern(rawValue: schedule.hapticPatternRaw) ?? .gentle

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

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        formatter.timeZone = .current
        return formatter
    }()

    // MARK: - Schedule Helpers

    private func findNextRelevantOccurrence(
        _ schedules: [WatchScheduleSnapshot]
    ) -> (schedule: WatchScheduleSnapshot, wakeUpTime: Date)? {
        return schedules
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

        return pendingSchedule.schedule.id == wake.schedule.id
            && pendingSchedule.wakeUpTime == wake.wakeUpTime
            && pendingSchedule.windowStart == wake.windowStart
            && pendingSchedule.baselineStart == wake.baselineStart
    }

    private func clearStaleArmedWakeIfNeeded(comparedTo wake: PendingWake, reason: String) {
        guard let pendingSchedule,
              pendingSchedule.schedule.id != wake.schedule.id
                || pendingSchedule.wakeUpTime != wake.wakeUpTime
                || pendingSchedule.windowStart != wake.windowStart
                || pendingSchedule.baselineStart != wake.baselineStart else {
            return
        }

        logStore.log(
            "SCHEDULER",
            "\(reason); cancelling stale armed wake before waiting for foreground re-arm",
            level: .warning
        )
        cancelAlarmSession()
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
                self.startMonitoringNow(schedule: pending.schedule, wakeUpTime: pending.wakeUpTime)
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
            // Only force-start monitoring if nothing has triggered yet
            if !self.sessionController.isMonitoringActive,
               self.sessionController.sessionState != .triggered,
               let pending = self.pendingSchedule {
                self.startMonitoringNow(schedule: pending.schedule, wakeUpTime: pending.wakeUpTime)
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
            } else if self.sessionController.isMonitoringActive || self.sessionController.sessionState == .triggered {
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
