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

    private let sessionController: SmartWakeSessionController
    private let sessionManager: WatchSessionManager

    /// How far before the wake window to start the extended session.
    /// The session itself stays alive; we then start HR monitoring closer to the window.
    private let sessionLeadTime: TimeInterval = 3600 // 1 hour before wake window

    /// How far before the wake window to start HR monitoring (within the session).
    private let monitoringLeadTime: TimeInterval = 3600 // 1 hour before wake window

    init(sessionController: SmartWakeSessionController, sessionManager: WatchSessionManager) {
        self.sessionController = sessionController
        self.sessionManager = sessionManager
        super.init()

        // Wire up session controller callbacks
        sessionController.onTrigger = { [weak self] payload in
            self?.sessionManager.sendTrigger(payload)
        }
        sessionController.onStateChange = { [weak self] state in
            self?.sessionManager.sendSessionState(state)
        }
    }

    // MARK: - Schedule Evaluation

    /// Called when schedules are received from the iPhone (can happen in background).
    func schedulesDidUpdate(_ schedules: [WatchScheduleSnapshot]) {
        let smartWakeSchedules = schedules.filter { $0.usesSmartWake }

        guard let nextSchedule = findNextRelevantSchedule(smartWakeSchedules),
              let wakeUpTime = nextWakeTime(for: nextSchedule) else {
            // No upcoming smart wake — tear down any active session
            cancelAlarmSession()
            return
        }

        let windowStart = wakeUpTime.addingTimeInterval(
            -Double(nextSchedule.smartWakeWindowMinutes) * 60
        )
        let sessionStartTime = windowStart.addingTimeInterval(-sessionLeadTime)
        let now = Date()

        // Already monitoring this schedule
        if sessionController.currentScheduleID == nextSchedule.id,
           sessionController.sessionState == .monitoring {
            return
        }

        if now >= windowStart && now < wakeUpTime {
            // Already inside the wake window — start monitoring immediately
            startMonitoringNow(schedule: nextSchedule, wakeUpTime: wakeUpTime)
        } else if now >= sessionStartTime && now < windowStart {
            // Within lead time — start the extended session and schedule monitoring
            startAlarmSession(schedule: nextSchedule, wakeUpTime: wakeUpTime, windowStart: windowStart)
        } else if now < sessionStartTime {
            // Too early — schedule the alarm session for later
            scheduleAlarmSession(at: sessionStartTime, schedule: nextSchedule, wakeUpTime: wakeUpTime, windowStart: windowStart)
        }
    }

    // MARK: - Extended Runtime Session

    private func startAlarmSession(
        schedule: WatchScheduleSnapshot,
        wakeUpTime: Date,
        windowStart: Date
    ) {
        cancelAlarmSession()

        let session = WKExtendedRuntimeSession()
        session.delegate = self
        self.extendedSession = session
        session.start()

        isAlarmSessionActive = true
        sessionController.isAlarmSessionActive = true
        alarmSessionError = nil
        print("[SmartAlarmScheduler] Extended runtime session started")

        // Schedule HR monitoring to begin at the right time
        scheduleMonitoringStart(schedule: schedule, wakeUpTime: wakeUpTime, windowStart: windowStart)
    }

    private func scheduleAlarmSession(
        at date: Date,
        schedule: WatchScheduleSnapshot,
        wakeUpTime: Date,
        windowStart: Date
    ) {
        cancelAlarmSession()

        let session = WKExtendedRuntimeSession()
        session.delegate = self
        self.extendedSession = session
        session.start(at: date)

        scheduledMonitoringDate = windowStart
        alarmSessionError = nil
        print("[SmartAlarmScheduler] Alarm session scheduled for \(date)")

        // Store schedule info so we can start monitoring when the session activates
        pendingSchedule = (schedule, wakeUpTime, windowStart)
    }

    private var pendingSchedule: (schedule: WatchScheduleSnapshot, wakeUpTime: Date, windowStart: Date)?

    private func cancelAlarmSession() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil

        if let session = extendedSession,
           session.state == .running || session.state == .scheduled {
            session.invalidate()
        }
        extendedSession = nil
        pendingSchedule = nil
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
        let now = Date()
        let monitoringStart = windowStart.addingTimeInterval(-monitoringLeadTime)

        if now >= monitoringStart {
            // Start monitoring immediately
            startMonitoringNow(schedule: schedule, wakeUpTime: wakeUpTime)
        } else {
            // Schedule a timer to start monitoring later
            let delay = monitoringStart.timeIntervalSince(now)
            scheduledMonitoringDate = monitoringStart
            monitoringTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.startMonitoringNow(schedule: schedule, wakeUpTime: wakeUpTime)
                }
            }
            print("[SmartAlarmScheduler] HR monitoring scheduled for \(monitoringStart)")
        }
    }

    private func startMonitoringNow(schedule: WatchScheduleSnapshot, wakeUpTime: Date) {
        guard sessionController.sessionState == .idle else {
            print("[SmartAlarmScheduler] Session controller already active, skipping")
            return
        }

        scheduledMonitoringDate = nil

        // Set the haptic pattern before starting monitoring
        sessionController.hapticPatternType = HapticPattern(rawValue: schedule.hapticPatternRaw) ?? .gentle

        Task {
            await sessionController.startMonitoring(
                scheduleID: schedule.id,
                wakeUpTime: wakeUpTime,
                windowMinutes: schedule.smartWakeWindowMinutes
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
                byAdding: .day, value: dayOffset, to: now
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

            // If we had a pending schedule (from a scheduled start), begin monitoring setup
            if let pending = self.pendingSchedule {
                self.pendingSchedule = nil
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
            // If monitoring hasn't started yet but we're close, force-start it
            if self.sessionController.sessionState == .idle,
               let pending = self.pendingSchedule {
                self.startMonitoringNow(schedule: pending.schedule, wakeUpTime: pending.wakeUpTime)
                self.pendingSchedule = nil
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
