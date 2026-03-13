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

    private let sessionLeadTime: TimeInterval = 3600
    private let monitoringLeadTime: TimeInterval = 3600

    init(sessionController: SmartWakeSessionController, sessionManager: WatchSessionManager) {
        self.sessionController = sessionController
        self.sessionManager = sessionManager
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
            cancelAlarmSession()
            sessionController.updateNextScheduledWakeWindow(schedule: nil, wakeUpTime: nil)
            return
        }

        let windowStart = wakeUpTime.addingTimeInterval(
            -Double(nextSchedule.smartWakeWindowMinutes) * 60
        )
        let now = Date()

        sessionController.updateNextScheduledWakeWindow(schedule: nextSchedule, wakeUpTime: wakeUpTime)

        if sessionController.isMonitoringActive,
           sessionController.currentScheduleID == nextSchedule.id {
            return
        }

        if currentSessionScheduleID == nextSchedule.id,
           currentSessionWakeTime == wakeUpTime,
           let extendedSession,
           extendedSession.state == .running || extendedSession.state == .scheduled {
            print("[SmartAlarmScheduler] Session already prepared for '\(nextSchedule.name)', skipping")
            return
        }

        if now >= windowStart && now < wakeUpTime {
            monitoringTimer?.invalidate()
            monitoringTimer = nil
            scheduledMonitoringDate = nil
            startMonitoringNow(schedule: nextSchedule, wakeUpTime: wakeUpTime)
            return
        }

        let desiredSessionStart = max(windowStart.addingTimeInterval(-sessionLeadTime), now.addingTimeInterval(1))
        scheduleAlarmSession(
            at: desiredSessionStart,
            schedule: nextSchedule,
            wakeUpTime: wakeUpTime,
            windowStart: windowStart
        )
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
        print("[SmartAlarmScheduler] Alarm session scheduled for \(date) (\(schedule.name))")
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
        print("[SmartAlarmScheduler] HR monitoring scheduled for \(monitoringStart)")
    }

    private func startMonitoringNow(schedule: WatchScheduleSnapshot, wakeUpTime: Date) {
        guard !sessionController.isMonitoringActive else {
            print("[SmartAlarmScheduler] Monitoring already active, skipping")
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
            print("[SmartAlarmScheduler] HR monitoring started for '\(schedule.name)' with haptic: \(sessionController.hapticPatternType.displayName)")
        }
    }

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
            print("[SmartAlarmScheduler] Extended runtime session now running")

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
            print("[SmartAlarmScheduler] Extended runtime session expiring soon")
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
                print("[SmartAlarmScheduler] Session invalidated with error: \(error)")
            } else {
                print("[SmartAlarmScheduler] Session invalidated, reason: \(reason.rawValue)")
            }
        }
    }
}
#endif
