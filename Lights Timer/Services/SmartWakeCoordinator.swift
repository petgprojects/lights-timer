import Foundation
import SwiftData

@Observable
final class SmartWakeCoordinator {
    private let scheduleEngine: ScheduleEngine
    private let watchConnectivity: WatchConnectivityService
    private var firedToday: [UUID: Date] = [:]

    var lastTriggerResult: String?

    init(scheduleEngine: ScheduleEngine, watchConnectivity: WatchConnectivityService) {
        self.scheduleEngine = scheduleEngine
        self.watchConnectivity = watchConnectivity

        watchConnectivity.onSmartWakeTrigger = { [weak self] trigger in
            guard let self else { return }
            Task {
                await self.handleTrigger(trigger)
            }
        }
    }

    // MARK: - Trigger Handling

    /// Validates and processes a smart wake trigger from the watch.
    /// Must be called with a valid modelContext available.
    private var pendingTrigger: SmartWakeTriggerPayload?

    func handleTrigger(_ trigger: SmartWakeTriggerPayload) async {
        pendingTrigger = trigger
        print("[SmartWakeCoordinator] Trigger received for schedule \(trigger.scheduleID), confidence: \(trigger.confidence)")
    }

    /// Called from SwiftUI context where modelContext is available.
    func processPendingTrigger(modelContext: ModelContext) async {
        guard let trigger = pendingTrigger else { return }
        pendingTrigger = nil

        await processValidatedTrigger(trigger, modelContext: modelContext)
    }

    private func processValidatedTrigger(
        _ trigger: SmartWakeTriggerPayload,
        modelContext: ModelContext
    ) async {
        let scheduleID = trigger.scheduleID
        let triggerDate = trigger.triggerDate

        // 1. Find matching schedule
        do {
            let descriptor = FetchDescriptor<LightSchedule>(
                predicate: #Predicate { $0.isEnabled }
            )
            let schedules = try modelContext.fetch(descriptor)
            guard let schedule = schedules.first(where: { $0.id == scheduleID }) else {
                lastTriggerResult = "Schedule not found"
                print("[SmartWakeCoordinator] No matching schedule for \(scheduleID)")
                return
            }

            // 2. Validate smart wake is enabled
            guard schedule.usesSmartWake else {
                lastTriggerResult = "Smart wake not enabled"
                return
            }

            // 3. Find next wake time
            guard let wakeUpTime = scheduleEngine.nextOccurrence(for: schedule) else {
                lastTriggerResult = "No upcoming occurrence"
                return
            }

            // 4. Check trigger is within the smart wake window
            let windowStart = wakeUpTime.addingTimeInterval(
                -Double(schedule.smartWakeWindowMinutes) * 60
            )
            guard triggerDate >= windowStart && triggerDate < wakeUpTime else {
                lastTriggerResult = "Outside wake window"
                print("[SmartWakeCoordinator] Trigger at \(triggerDate) outside window \(windowStart)...\(wakeUpTime)")
                return
            }

            // 5. Check not already fired today
            if let lastFired = firedToday[scheduleID] {
                let calendar = Calendar.current
                if calendar.isDate(lastFired, inSameDayAs: triggerDate) {
                    lastTriggerResult = "Already fired today"
                    return
                }
            }

            // 6. Don't start if engine is already running
            guard !scheduleEngine.isRunning else {
                lastTriggerResult = "Ramp already running"
                return
            }

            // 7. Start the ramp
            firedToday[scheduleID] = triggerDate
            schedule.lastSmartWakeTriggerAt = triggerDate

            await scheduleEngine.startSmartWakeExecution(
                for: schedule,
                triggerTime: triggerDate
            )

            lastTriggerResult = "Smart wake started at \(formatTime(triggerDate))"
            print("[SmartWakeCoordinator] Smart wake ramp started for '\(schedule.name)'")

        } catch {
            lastTriggerResult = "Error: \(error.localizedDescription)"
            print("[SmartWakeCoordinator] Error processing trigger: \(error)")
        }
    }

    // MARK: - Schedule Sync

    /// Sends current smart-wake-enabled schedules to the watch.
    func syncSchedulesToWatch(modelContext: ModelContext) {
        do {
            let descriptor = FetchDescriptor<LightSchedule>(
                predicate: #Predicate { $0.isEnabled }
            )
            let schedules = try modelContext.fetch(descriptor)
            let snapshots = schedules
                .filter { $0.usesSmartWake }
                .map { WatchScheduleSnapshot(from: $0) }
            watchConnectivity.sendSchedules(snapshots)
        } catch {
            print("[SmartWakeCoordinator] Failed to sync schedules: \(error)")
        }
    }

    /// Simulate a smart wake trigger for testing.
    func simulateTrigger(for schedule: LightSchedule) async {
        let trigger = SmartWakeTriggerPayload(
            scheduleID: schedule.id,
            triggerDate: Date(),
            confidence: 0.85,
            heartRateAtTrigger: 72,
            motionLevel: 0.6
        )
        pendingTrigger = trigger
        print("[SmartWakeCoordinator] Simulated trigger for '\(schedule.name)'")
    }

    // MARK: - Cleanup

    func resetDailyState() {
        let calendar = Calendar.current
        let today = Date()
        firedToday = firedToday.filter { _, date in
            calendar.isDate(date, inSameDayAs: today)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
