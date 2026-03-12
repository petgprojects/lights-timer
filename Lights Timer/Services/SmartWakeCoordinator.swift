import Foundation
import SwiftData

@Observable
final class SmartWakeCoordinator {
    private let scheduleEngine: ScheduleEngine
    private let watchConnectivity: WatchConnectivityService
    private let modelContainer: ModelContainer
    private var firedToday: [UUID: Date] = [:]

    var lastTriggerResult: String?

    init(scheduleEngine: ScheduleEngine, watchConnectivity: WatchConnectivityService, modelContainer: ModelContainer) {
        self.scheduleEngine = scheduleEngine
        self.watchConnectivity = watchConnectivity
        self.modelContainer = modelContainer

        watchConnectivity.onSmartWakeTrigger = { [weak self] trigger in
            guard let self else { return }
            Task {
                await self.handleTrigger(trigger)
            }
        }

        watchConnectivity.onHapticPatternChanged = { [weak self] payload in
            guard let self else { return }
            self.handleHapticPatternChange(payload)
        }

        watchConnectivity.onTestTrigger = { [weak self] trigger in
            guard let self else { return }
            Task {
                await self.handleTestTrigger(trigger)
            }
        }
    }

    // MARK: - Trigger Handling

    /// Validates and processes a smart wake trigger from the watch.
    /// Processes immediately using its own ModelContext for background execution.
    private var pendingTrigger: SmartWakeTriggerPayload?

    func handleTrigger(_ trigger: SmartWakeTriggerPayload) async {
        print("[SmartWakeCoordinator] Trigger received for schedule \(trigger.scheduleID), confidence: \(trigger.confidence)")

        // Wait for HomeKit to discover homes (may take a few seconds when woken in background)
        await scheduleEngine.homeKitService.waitForReady()

        let context = ModelContext(modelContainer)
        let processed = await processValidatedTrigger(trigger, modelContext: context)
        if !processed {
            // Store as pending for fallback processing when app comes to foreground
            pendingTrigger = trigger
        }
    }

    /// Fallback: called from SwiftUI context when app becomes active.
    func processPendingTrigger(modelContext: ModelContext) async {
        guard let trigger = pendingTrigger else { return }
        pendingTrigger = nil

        let _ = await processValidatedTrigger(trigger, modelContext: modelContext)
    }

    @discardableResult
    private func processValidatedTrigger(
        _ trigger: SmartWakeTriggerPayload,
        modelContext: ModelContext
    ) async -> Bool {
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
                return false
            }

            // 2. Validate smart wake is enabled
            guard schedule.usesSmartWake else {
                lastTriggerResult = "Smart wake not enabled"
                return false
            }

            // 3. Find next wake time
            guard let wakeUpTime = scheduleEngine.nextOccurrence(for: schedule) else {
                lastTriggerResult = "No upcoming occurrence"
                return false
            }

            // 4. Check trigger is within the smart wake window
            let windowStart = wakeUpTime.addingTimeInterval(
                -Double(schedule.smartWakeWindowMinutes) * 60
            )
            guard triggerDate >= windowStart && triggerDate < wakeUpTime else {
                lastTriggerResult = "Outside wake window"
                print("[SmartWakeCoordinator] Trigger at \(triggerDate) outside window \(windowStart)...\(wakeUpTime)")
                return false
            }

            // 5. Check not already fired today
            if let lastFired = firedToday[scheduleID] {
                let calendar = Calendar.current
                if calendar.isDate(lastFired, inSameDayAs: triggerDate) {
                    lastTriggerResult = "Already fired today"
                    return false
                }
            }

            if trigger.lightsHandledOnWatch == true {
                firedToday[scheduleID] = triggerDate
                schedule.lastSmartWakeTriggerAt = triggerDate
                try? modelContext.save()

                lastTriggerResult = "Smart wake started on watch at \(formatTime(triggerDate))"
                print("[SmartWakeCoordinator] Watch handled smart wake lights for '\(schedule.name)'")
                return true
            }

            // 6. Don't start if engine is already running
            guard !scheduleEngine.isRunning else {
                lastTriggerResult = "Ramp already running"
                return false
            }

            // 7. Start the ramp
            firedToday[scheduleID] = triggerDate
            schedule.lastSmartWakeTriggerAt = triggerDate
            try? modelContext.save()

            await scheduleEngine.startSmartWakeExecution(for: schedule)

            lastTriggerResult = "Smart wake started at \(formatTime(triggerDate))"
            print("[SmartWakeCoordinator] Smart wake ramp started for '\(schedule.name)'")
            return true

        } catch {
            lastTriggerResult = "Error: \(error.localizedDescription)"
            print("[SmartWakeCoordinator] Error processing trigger: \(error)")
            return false
        }
    }

    // MARK: - Haptic Pattern Change (from Watch)

    private func handleHapticPatternChange(_ payload: HapticPatternChangePayload) {
        let context = ModelContext(modelContainer)
        do {
            let descriptor = FetchDescriptor<LightSchedule>()
            let schedules = try context.fetch(descriptor)
            guard let schedule = schedules.first(where: { $0.id == payload.scheduleID }) else {
                print("[SmartWakeCoordinator] Schedule not found for haptic change")
                return
            }
            schedule.hapticPatternRaw = payload.hapticPatternRaw
            try context.save()
            print("[SmartWakeCoordinator] Updated haptic pattern to '\(payload.hapticPatternRaw)' for '\(schedule.name)'")
            // Re-sync to watch so it gets the confirmed update
            syncSchedulesToWatch(modelContext: context)
        } catch {
            print("[SmartWakeCoordinator] Failed to update haptic pattern: \(error)")
        }
    }

    // MARK: - Test Trigger (from Watch)

    /// Handles a test trigger from the watch — bypasses schedule validation.
    private func handleTestTrigger(_ trigger: SmartWakeTriggerPayload) async {
        // Wait for HomeKit to discover homes (may take a few seconds when woken in background)
        await scheduleEngine.homeKitService.waitForReady()

        let context = ModelContext(modelContainer)
        do {
            let descriptor = FetchDescriptor<LightSchedule>()
            let schedules = try context.fetch(descriptor)
            guard let schedule = schedules.first(where: { $0.id == trigger.scheduleID }) else {
                lastTriggerResult = "Test: schedule not found"
                return
            }
            guard !scheduleEngine.isRunning else {
                lastTriggerResult = "Test: ramp already running"
                return
            }

            if trigger.lightsHandledOnWatch == true {
                lastTriggerResult = "Test ramp started on watch for '\(schedule.name)'"
                print("[SmartWakeCoordinator] Watch handled test ramp for '\(schedule.name)'")
                return
            }

            await scheduleEngine.startSmartWakeExecution(for: schedule)
            lastTriggerResult = "Test ramp started for '\(schedule.name)'"
            print("[SmartWakeCoordinator] Test ramp started for '\(schedule.name)'")
        } catch {
            lastTriggerResult = "Test error: \(error.localizedDescription)"
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
        await handleTrigger(trigger)
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
