import Foundation
import SwiftData

@Observable
final class SmartWakeCoordinator {
    private struct ProcessedHandoffRecord {
        let payload: SmartWakeLightHandoffPayload
        let createdAt: Date
    }

    private let scheduleEngine: ScheduleEngine
    private let watchConnectivity: WatchConnectivityService
    private let modelContainer: ModelContainer

    private var firedToday: [UUID: Date] = [:]
    private var processedHandoffs: [UUID: ProcessedHandoffRecord] = [:]

    private let maxTriggerAge: TimeInterval = 2 * 60 * 60
    private let allowedFutureTriggerSkew: TimeInterval = 2 * 60
    private let handoffRetention: TimeInterval = 24 * 60 * 60
    private let handoffLimit = 256

    var lastTriggerResult: String?
    var lastLightRampOwner: String?

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

    func handleTrigger(_ trigger: SmartWakeTriggerPayload) async {
        print("[SmartWakeCoordinator] Trigger received \(trigger.triggerID) for schedule \(trigger.scheduleID), confidence: \(trigger.confidence)")

        pruneProcessedHandoffs()

        if let existingHandoff = processedHandoffs[trigger.triggerID]?.payload {
            watchConnectivity.sendLightHandoff(existingHandoff)
            lastTriggerResult = "Duplicate trigger ignored"
            lastLightRampOwner = existingHandoff.phoneWillHandleLights ? "Phone" : "Watch"
            return
        }

        let context = ModelContext(modelContainer)
        await processValidatedTrigger(trigger, modelContext: context)
    }

    private func processValidatedTrigger(
        _ trigger: SmartWakeTriggerPayload,
        modelContext: ModelContext
    ) async {
        do {
            if let freshnessFailure = triggerFreshnessFailure(for: trigger.triggerDate) {
                rejectTrigger(trigger, scheduleID: trigger.scheduleID, reason: freshnessFailure)
                return
            }

            let descriptor = FetchDescriptor<LightSchedule>()
            let schedules = try modelContext.fetch(descriptor)

            guard let schedule = schedules.first(where: { $0.id == trigger.scheduleID }) else {
                rejectTrigger(trigger, scheduleID: trigger.scheduleID, reason: "Schedule not found")
                return
            }

            guard schedule.isEnabled else {
                rejectTrigger(trigger, scheduleID: schedule.id, reason: "Schedule disabled")
                return
            }

            guard schedule.usesSmartWake else {
                rejectTrigger(trigger, scheduleID: schedule.id, reason: "Smart wake not enabled")
                return
            }

            guard let occurrence = occurrenceContainingTriggerDate(trigger.triggerDate, for: schedule) else {
                rejectTrigger(trigger, scheduleID: schedule.id, reason: "Outside wake window")
                return
            }

            if let firedOccurrence = firedToday[schedule.id],
               Calendar.current.isDate(firedOccurrence, inSameDayAs: occurrence.wakeUpTime) {
                rejectTrigger(trigger, scheduleID: schedule.id, reason: "Already fired for this wake")
                return
            }

            firedToday[schedule.id] = occurrence.wakeUpTime
            schedule.lastSmartWakeTriggerAt = trigger.triggerDate
            try? modelContext.save()

            guard !scheduleEngine.isRunning else {
                acceptWatchFallback(trigger, scheduleID: schedule.id, reason: "Phone ramp already running")
                return
            }

            switch await scheduleEngine.startSmartWakeExecution(for: schedule) {
            case .phoneCommitted:
                sendHandoff(
                    triggerID: trigger.triggerID,
                    scheduleID: schedule.id,
                    phoneWillHandleLights: true,
                    reason: nil
                )
                lastTriggerResult = "Phone accepted smart wake at \(formatTime(trigger.triggerDate))"
                lastLightRampOwner = "Phone"
            case .watchFallback(let reason):
                acceptWatchFallback(trigger, scheduleID: schedule.id, reason: reason)
            }
        } catch {
            rejectTrigger(trigger, scheduleID: trigger.scheduleID, reason: "Error: \(error.localizedDescription)")
        }
    }

    private func rejectTrigger(
        _ trigger: SmartWakeTriggerPayload,
        scheduleID: UUID,
        reason: String
    ) {
        sendHandoff(
            triggerID: trigger.triggerID,
            scheduleID: scheduleID,
            phoneWillHandleLights: false,
            reason: reason
        )
        lastTriggerResult = reason
        lastLightRampOwner = "Rejected"
        print("[SmartWakeCoordinator] Rejected trigger \(trigger.triggerID): \(reason)")
    }

    private func acceptWatchFallback(
        _ trigger: SmartWakeTriggerPayload,
        scheduleID: UUID,
        reason: String
    ) {
        sendHandoff(
            triggerID: trigger.triggerID,
            scheduleID: scheduleID,
            phoneWillHandleLights: false,
            reason: reason
        )
        lastTriggerResult = "Watch fallback at \(formatTime(trigger.triggerDate)): \(reason)"
        lastLightRampOwner = "Watch"
        print("[SmartWakeCoordinator] Watch fallback for trigger \(trigger.triggerID): \(reason)")
    }

    private func sendHandoff(
        triggerID: UUID,
        scheduleID: UUID,
        phoneWillHandleLights: Bool,
        reason: String?
    ) {
        let payload = SmartWakeLightHandoffPayload(
            triggerID: triggerID,
            scheduleID: scheduleID,
            phoneWillHandleLights: phoneWillHandleLights,
            reason: reason
        )
        processedHandoffs[triggerID] = ProcessedHandoffRecord(
            payload: payload,
            createdAt: Date()
        )
        pruneProcessedHandoffs()
        watchConnectivity.sendLightHandoff(payload)
    }

    private func occurrenceContainingTriggerDate(
        _ triggerDate: Date,
        for schedule: LightSchedule
    ) -> (wakeUpTime: Date, windowStart: Date)? {
        let calendar = Calendar.current
        let baseDay = calendar.startOfDay(for: triggerDate)
        let offsets = [0, -1, 1]

        for offset in offsets {
            guard let candidateDay = calendar.date(byAdding: .day, value: offset, to: baseDay) else {
                continue
            }

            let weekday = calendar.component(.weekday, from: candidateDay)
            guard let dayOfWeek = DayOfWeek(rawValue: weekday),
                  schedule.activeDays.contains(dayOfWeek) else { continue }

            var components = calendar.dateComponents([.year, .month, .day], from: candidateDay)
            components.hour = schedule.wakeUpHour
            components.minute = schedule.wakeUpMinute
            components.second = 0

            guard let wakeUpTime = calendar.date(from: components) else { continue }
            let windowStart = wakeUpTime.addingTimeInterval(
                -Double(schedule.smartWakeWindowMinutes) * 60
            )

            if triggerDate >= windowStart && triggerDate < wakeUpTime {
                return (wakeUpTime, windowStart)
            }
        }

        return nil
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
            syncSchedulesToWatch(modelContext: context)
        } catch {
            print("[SmartWakeCoordinator] Failed to update haptic pattern: \(error)")
        }
    }

    // MARK: - Test Trigger (from Watch)

    private func handleTestTrigger(_ trigger: SmartWakeTriggerPayload) async {
        let context = ModelContext(modelContainer)

        do {
            let descriptor = FetchDescriptor<LightSchedule>()
            let schedules = try context.fetch(descriptor)
            guard let schedule = schedules.first(where: { $0.id == trigger.scheduleID }) else {
                lastTriggerResult = "Test: schedule not found"
                lastLightRampOwner = "Rejected"
                return
            }

            guard !scheduleEngine.isRunning else {
                lastTriggerResult = "Test: ramp already running"
                lastLightRampOwner = "Rejected"
                return
            }

            if trigger.lightsHandledOnWatch == true {
                lastTriggerResult = "Test ramp started on watch for '\(schedule.name)'"
                lastLightRampOwner = "Watch (test)"
                return
            }

            switch await scheduleEngine.startSmartWakeExecution(for: schedule) {
            case .phoneCommitted:
                lastTriggerResult = "Test ramp started on phone for '\(schedule.name)'"
                lastLightRampOwner = "Phone (test)"
            case .watchFallback(let reason):
                lastTriggerResult = "Test phone ramp failed: \(reason)"
                lastLightRampOwner = "Watch (test fallback)"
            }
        } catch {
            lastTriggerResult = "Test error: \(error.localizedDescription)"
            lastLightRampOwner = "Rejected"
        }
    }

    // MARK: - Schedule Sync

    func syncSchedulesToWatch(modelContext: ModelContext) {
        do {
            let descriptor = FetchDescriptor<LightSchedule>(
                predicate: #Predicate { $0.isEnabled }
            )
            let schedules = try modelContext.fetch(descriptor)
            let snapshots = schedules
                .filter(\.usesSmartWake)
                .map { WatchScheduleSnapshot(from: $0) }
            watchConnectivity.sendSchedules(snapshots)
        } catch {
            print("[SmartWakeCoordinator] Failed to sync schedules: \(error)")
        }
    }

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
        firedToday = firedToday.filter { _, occurrenceDate in
            calendar.isDate(occurrenceDate, inSameDayAs: today)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func triggerFreshnessFailure(for triggerDate: Date, now: Date = Date()) -> String? {
        if now.timeIntervalSince(triggerDate) > maxTriggerAge {
            return "Stale trigger"
        }
        if triggerDate.timeIntervalSince(now) > allowedFutureTriggerSkew {
            return "Trigger date too far in future"
        }
        return nil
    }

    private func pruneProcessedHandoffs(now: Date = Date()) {
        processedHandoffs = processedHandoffs.filter { _, record in
            now.timeIntervalSince(record.createdAt) <= handoffRetention
        }

        guard processedHandoffs.count > handoffLimit else { return }
        let oldestTriggerIDs = processedHandoffs
            .sorted { $0.value.createdAt < $1.value.createdAt }
            .prefix(processedHandoffs.count - handoffLimit)
            .map(\.key)
        for triggerID in oldestTriggerIDs {
            processedHandoffs.removeValue(forKey: triggerID)
        }
    }
}
