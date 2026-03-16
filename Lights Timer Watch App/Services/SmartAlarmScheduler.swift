#if os(watchOS)
import Foundation
import WatchKit

@Observable
final class SmartAlarmScheduler: NSObject {
    private(set) var isAlarmSessionActive = false
    private(set) var scheduledMonitoringDate: Date?
    private(set) var alarmSessionError: String?

    private var extendedSession: WKExtendedRuntimeSession?
    private var monitoringTimer: Timer?
    private var pendingSchedule: (schedule: WatchScheduleSnapshot, wakeUpTime: Date, windowStart: Date)?

    private var currentSessionScheduleID: UUID?
    private var currentSessionWakeTime: Date?

    private let sessionController: SmartWakeSessionController
    private let sessionManager: WatchSessionManager
    private let logStore: SmartWakeLogStore

    private let monitoringLeadTime: TimeInterval = 3600
    private let proactiveWorkoutHorizon: TimeInterval = 43200  // 12 hours

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
        }
        sessionController.onStateChange = { [weak self] state in
            self?.sessionManager.sendSessionState(state)
        }
    }

    // MARK: - Schedule Evaluation

    func schedulesDidUpdate(_ schedules: [WatchScheduleSnapshot]) {
        let smartWakeSchedules = schedules.filter(\.usesSmartWake)

        guard let nextSchedule = findNextRelevantSchedule(smartWakeSchedules),
              let wakeUpTime = nextWakeTime(for: nextSchedule) else {
            logStore.log("SCHEDULER", "No upcoming smart wake schedules found", level: .warning)
            cancelAlarmSession()
            sessionController.updateNextScheduledWakeWindow(schedule: nil, wakeUpTime: nil)
            return
        }

        let windowStart = wakeUpTime.addingTimeInterval(
            -Double(nextSchedule.smartWakeWindowMinutes) * 60
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

        if sessionController.isMonitoringActive,
           sessionController.currentScheduleID == nextSchedule.id {
            logStore.log(
                "SCHEDULER",
                "Monitoring already active for '\(nextSchedule.name)'; skipping re-schedule"
            )
            return
        }

        if currentSessionScheduleID == nextSchedule.id,
           currentSessionWakeTime == wakeUpTime,
           let extendedSession,
           extendedSession.state == .running || extendedSession.state == .scheduled {
            logStore.log(
                "SCHEDULER",
                "Extended runtime session already prepared for '\(nextSchedule.name)'; skipping duplicate scheduling"
            )
            return
        }

        if now >= windowStart && now < wakeUpTime {
            logStore.log(
                "SCHEDULER",
                "Already inside the wake window for '\(nextSchedule.name)'; starting monitoring immediately"
            )
            monitoringTimer?.invalidate()
            monitoringTimer = nil
            scheduledMonitoringDate = nil
            startMonitoringNow(schedule: nextSchedule, wakeUpTime: wakeUpTime)
            return
        }

        // Schedule extended runtime session to fire at wakeTime - min(windowMinutes, 30) min
        // This ensures the ~30 min execution window always covers wake time for force-fire + haptics
        let sessionLeadSeconds = Double(min(nextSchedule.smartWakeWindowMinutes, 30)) * 60
        let desiredSessionStart = max(wakeUpTime.addingTimeInterval(-sessionLeadSeconds), now.addingTimeInterval(1))
        scheduleAlarmSession(
            at: desiredSessionStart,
            schedule: nextSchedule,
            wakeUpTime: wakeUpTime,
            windowStart: windowStart
        )

        // Evaluate proactive workout start if app is in foreground
        evaluateProactiveWorkout(schedules)
    }

    // MARK: - Proactive Workout

    func evaluateProactiveWorkout(_ schedules: [WatchScheduleSnapshot]) {
        guard !sessionController.isWorkoutSessionRunning else { return }

        let smartWakeSchedules = schedules.filter(\.usesSmartWake)
        let now = Date()
        let horizon = now.addingTimeInterval(proactiveWorkoutHorizon)

        guard let nextSchedule = findNextRelevantSchedule(smartWakeSchedules),
              let wakeUpTime = nextWakeTime(for: nextSchedule),
              wakeUpTime <= horizon else {
            return
        }

        let appState = WKApplication.shared().applicationState
        guard appState == .active else {
            logStore.log(
                "SCHEDULER",
                "Proactive workout skipped — app not in foreground (state=\(appState.rawValue))"
            )
            return
        }

        let windowStart = wakeUpTime.addingTimeInterval(-Double(nextSchedule.smartWakeWindowMinutes) * 60)

        logStore.log(
            "SCHEDULER",
            "Starting proactive workout session for '\(nextSchedule.name)' wake=\(formatTimestamp(wakeUpTime))"
        )

        Task {
            do {
                try await sessionController.startProactiveWorkoutSession()
                // Schedule deferred monitoring start — workout-processing keeps us alive
                scheduleMonitoringStart(
                    schedule: nextSchedule,
                    wakeUpTime: wakeUpTime,
                    windowStart: windowStart
                )
            } catch {
                logStore.log(
                    "SCHEDULER",
                    "Proactive workout session failed: \(error.localizedDescription)",
                    level: .error
                )
            }
        }
    }

    func onAppForeground() {
        logStore.log("SCHEDULER", "App returned to foreground — re-evaluating proactive workout")
        evaluateProactiveWorkout(sessionManager.activeSchedules)
    }

    // MARK: - Extended Runtime Session

    private func scheduleAlarmSession(
        at date: Date,
        schedule: WatchScheduleSnapshot,
        wakeUpTime: Date,
        windowStart: Date
    ) {
        cancelAlarmSession()

        let session = WKExtendedRuntimeSession()
        session.delegate = self
        extendedSession = session
        currentSessionScheduleID = schedule.id
        currentSessionWakeTime = wakeUpTime
        pendingSchedule = (schedule, wakeUpTime, windowStart)
        session.start(at: date)

        let monitoringStart = windowStart.addingTimeInterval(-monitoringLeadTime)
        scheduledMonitoringDate = max(monitoringStart, date)
        alarmSessionError = nil
        logStore.log(
            "SCHEDULER",
            "Scheduled extended runtime session for '\(schedule.name)' at \(formatTimestamp(date)). monitoringStart=\(formatTimestamp(scheduledMonitoringDate))"
        )
    }

    private func cancelAlarmSession() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil

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
        logStore.log("SCHEDULER", "Cancelled any pending extended runtime session")
    }

    // MARK: - HR Monitoring Start

    private func scheduleMonitoringStart(
        schedule: WatchScheduleSnapshot,
        wakeUpTime: Date,
        windowStart: Date
    ) {
        let monitoringStart = windowStart.addingTimeInterval(-monitoringLeadTime)
        let now = Date()

        if now >= monitoringStart {
            logStore.log(
                "SCHEDULER",
                "Monitoring lead time already started for '\(schedule.name)'; beginning monitoring immediately"
            )
            startMonitoringNow(schedule: schedule, wakeUpTime: wakeUpTime)
            return
        }

        monitoringTimer?.invalidate()
        let delay = monitoringStart.timeIntervalSince(now)
        scheduledMonitoringDate = monitoringStart
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startMonitoringNow(schedule: schedule, wakeUpTime: wakeUpTime)
            }
        }
        logStore.log(
            "SCHEDULER",
            "Scheduled HR monitoring start for '\(schedule.name)' at \(formatTimestamp(monitoringStart))"
        )
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

        pendingSchedule = nil
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        scheduledMonitoringDate = nil

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

    private func findNextRelevantSchedule(
        _ schedules: [WatchScheduleSnapshot]
    ) -> WatchScheduleSnapshot? {
        let now = Date()

        return schedules
            .compactMap { schedule -> (WatchScheduleSnapshot, Date)? in
                guard let wakeTime = nextWakeTime(for: schedule) else { return nil }
                return (schedule, wakeTime)
            }
            .filter { $0.1 > now }
            .sorted { $0.1 < $1.1 }
            .first?.0
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
            if wakeUpTime > now { return wakeUpTime }
        }

        return nil
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension SmartAlarmScheduler: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(
        _ extendedRuntimeSession: WKExtendedRuntimeSession
    ) {
        Task { @MainActor in
            self.isAlarmSessionActive = true
            self.sessionController.isAlarmSessionActive = true
            self.logStore.log("SCHEDULER", "Extended runtime session is now running")

            if self.sessionController.isMonitoringActive {
                self.logStore.log(
                    "SCHEDULER",
                    "Safety-net session started; monitoring already active via proactive workout — skipping"
                )
                return
            }

            if let pending = self.pendingSchedule {
                self.scheduleMonitoringStart(
                    schedule: pending.schedule,
                    wakeUpTime: pending.wakeUpTime,
                    windowStart: pending.windowStart
                )
            }
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(
        _ extendedRuntimeSession: WKExtendedRuntimeSession
    ) {
        Task { @MainActor in
            self.logStore.log(
                "SCHEDULER",
                "Extended runtime session will expire soon",
                level: .warning
            )
            if !self.sessionController.isMonitoringActive,
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
            self.isAlarmSessionActive = false
            self.sessionController.isAlarmSessionActive = false
            self.extendedSession = nil

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
        }
    }
}
#endif
