import SwiftUI

@main
struct LightsTimerWatchApp: App {
    @State private var sessionManager = WatchSessionManager()
    @State private var sessionController = SmartWakeSessionController()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(sessionManager)
                .environment(sessionController)
                .task {
                    await sessionController.requestAuthorization()
                    sessionManager.sendPermissionStatus(
                        authorized: sessionController.isHealthKitAuthorized
                    )
                }
                .onChange(of: sessionManager.activeSchedules) { _, schedules in
                    Task {
                        await evaluateSchedules(schedules)
                    }
                }
        }
    }

    private func evaluateSchedules(_ schedules: [WatchScheduleSnapshot]) async {
        // Wire up callbacks
        sessionController.onTrigger = { payload in
            sessionManager.sendTrigger(payload)
        }
        sessionController.onStateChange = { state in
            sessionManager.sendSessionState(state)
        }

        // Find the next relevant schedule
        guard let nextSchedule = findNextRelevantSchedule(schedules) else {
            sessionController.stopMonitoring()
            return
        }

        guard let wakeUpTime = nextWakeTime(for: nextSchedule) else { return }

        let windowStart = wakeUpTime.addingTimeInterval(
            -Double(nextSchedule.smartWakeWindowMinutes) * 60
        )
        let now = Date()

        // Start monitoring if we're within an hour of the window start,
        // or already in the window
        let monitoringLeadTime: TimeInterval = 3600
        if now >= windowStart.addingTimeInterval(-monitoringLeadTime) && now < wakeUpTime {
            if sessionController.currentScheduleID != nextSchedule.id {
                await sessionController.startMonitoring(
                    scheduleID: nextSchedule.id,
                    wakeUpTime: wakeUpTime,
                    windowMinutes: nextSchedule.smartWakeWindowMinutes
                )
            }
        }
    }

    private func findNextRelevantSchedule(
        _ schedules: [WatchScheduleSnapshot]
    ) -> WatchScheduleSnapshot? {
        let now = Date()

        return schedules
            .filter { $0.usesSmartWake }
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
