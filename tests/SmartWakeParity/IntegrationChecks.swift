import Foundation

@main
struct IntegrationChecks {
    @MainActor static func main() async throws {
        var names: [String] = []
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            names.append(name)
        }
        let wake = Date(timeIntervalSince1970: 20_000)
        let window = wake.addingTimeInterval(-1800)
        for minutes in [10, 15, 20, 25, 30, 45, 60] {
            let start = SmartWakeExecutionPolicy.sessionStart(windowStart: wake.addingTimeInterval(Double(-minutes * 60)), wakeUpTime: wake)
            let expected = max(wake.addingTimeInterval(Double(-minutes * 60 - 120)), wake.addingTimeInterval(-1500))
            check(start == expected, "runtime schedule for \(minutes)-minute window")
            check(start.addingTimeInterval(1800 - 300) >= wake, "nominal five-minute reserve cannot advance \(minutes)-minute deadline")
        }
        check(!SmartWakeExecutionPolicy.exactWakeDue(now: wake.addingTimeInterval(-0.001), wakeUpTime: wake, alreadyTriggered: false), "no exact fallback before deadline")
        check(SmartWakeExecutionPolicy.exactWakeDue(now: wake, wakeUpTime: wake, alreadyTriggered: false), "fallback includes exact deadline")
        check(SmartWakeExecutionPolicy.exactWakeDue(now: wake.addingTimeInterval(300), wakeUpTime: wake, alreadyTriggered: false), "late startup still forces fallback")
        check(!SmartWakeExecutionPolicy.exactWakeDue(now: wake.addingTimeInterval(300), wakeUpTime: wake, alreadyTriggered: true), "exact fallback suppresses duplicate fire")

        let trigger = UUID(), schedule = UUID()
        check(SmartWakeExecutionPolicy.phoneOwnsLights(activeTrigger: trigger, activeSchedule: schedule,
            acknowledgementTrigger: trigger, acknowledgementSchedule: schedule, phoneWillHandleLights: true), "matching positive acknowledgement owns lights")
        for (t, s, accepted) in [(UUID(), schedule, true), (trigger, UUID(), true), (trigger, schedule, false)] {
            check(!SmartWakeExecutionPolicy.phoneOwnsLights(activeTrigger: trigger, activeSchedule: schedule,
                acknowledgementTrigger: t, acknowledgementSchedule: s, phoneWillHandleLights: accepted), "wrong or negative acknowledgement preserves watch fallback")
        }
        check(!SmartWakeExecutionPolicy.phoneOwnsLights(activeTrigger: nil, activeSchedule: nil,
            acknowledgementTrigger: trigger, acknowledgementSchedule: schedule, phoneWillHandleLights: true), "unsolicited acknowledgement cannot claim lights")

        let suite = "LightsTimer.IntegrationChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SmartWakeCompletionStore(defaults: defaults)
        check(!store.contains(scheduleID: schedule, wakeUpTime: wake, now: wake), "empty completion ledger")
        store.record(scheduleID: schedule, wakeUpTime: wake, now: wake)
        store.record(scheduleID: schedule, wakeUpTime: wake, now: wake)
        let restored = SmartWakeCompletionStore(defaults: defaults)
        check(restored.contains(scheduleID: schedule, wakeUpTime: wake, now: wake), "completion survives store reconstruction before cleanup")
        check(!restored.contains(scheduleID: schedule, wakeUpTime: wake.addingTimeInterval(86400), now: wake), "completion belongs to exact occurrence")
        check(restored.contains(scheduleID: schedule, wakeUpTime: wake, now: wake.addingTimeInterval(172800)), "completion retention boundary inclusive")
        check(!restored.contains(scheduleID: schedule, wakeUpTime: wake, now: wake.addingTimeInterval(172800.001)), "completion ages out after two days")
        let identifiers = (0..<40).map { _ in UUID() }
        for id in identifiers { restored.record(scheduleID: id, wakeUpTime: wake, now: wake) }
        check(!restored.contains(scheduleID: identifiers[7], wakeUpTime: wake, now: wake), "completion ledger evicts beyond 32 entries")
        check(restored.contains(scheduleID: identifiers[8], wakeUpTime: wake, now: wake), "completion ledger retains 32 newest entries")
        check(restored.contains(scheduleID: identifiers[39], wakeUpTime: wake, now: wake), "completion ledger retains latest entry")
        defaults.set(Data("invalid JSON".utf8), forKey: "smartWakeCompletedOccurrences-v1")
        check(!restored.contains(scheduleID: identifiers[39], wakeUpTime: wake, now: wake), "corrupt completion storage degrades safely")

        let scheduleSnapshot = WatchScheduleSnapshot(id: schedule, name: "Recovery", wakeUpHour: 7, wakeUpMinute: 0,
            activeDaysRaw: [1, 2, 3, 4, 5, 6, 7], oneDayOverrideOriginalWakeDate: wake.addingTimeInterval(3600),
            oneDayOverrideWakeDate: wake, leadTimeMinutes: 20, usesSmartWake: true, smartWakeWindowMinutes: 30,
            targetBrightness: 100, startColorHue: 0, startColorSaturation: 0, startColorBrightness: 0,
            endColorHue: 0, endColorSaturation: 0, endColorBrightness: 1, skipColorWrites: true,
            lightIdentifiers: ["light-id"], lightNames: ["Bedroom"], hapticPatternRaw: "gentle")
        let pending = SmartWakePendingWakeRecord(schedule: scheduleSnapshot, wakeUpTime: wake, windowStart: window,
            baselineStart: window.addingTimeInterval(-7200), scheduledSessionStart: wake.addingTimeInterval(-1500),
            armedAt: Date(timeIntervalSince1970: 10), savedAt: Date(timeIntervalSince1970: 20), isSessionScheduled: false)
        let pendingStore = SmartWakePendingWakeStore(userDefaults: defaults)
        pendingStore.savePendingWakeRecord(pending)
        let recovered = SmartWakePendingWakeStore(userDefaults: defaults).loadPendingWakeRecord()
        check(recovered == pending, "pending occurrence restores full schedule without connectivity hydration")
        check(recovered?.armedAt == Date(timeIntervalSince1970: 10), "recovery preserves actual overnight armedAt")
        check(recovered?.isSessionScheduled == false, "foreground-rearm placeholder never becomes armed by decoding")
        check(recovered?.schedule.oneDayOverrideWakeDate == wake && recovered?.schedule.oneDayOverrideOriginalWakeDate == wake.addingTimeInterval(3600),
              "recovery retains one-day replacement occurrence")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as! [String: Any]
        legacy.removeValue(forKey: "armedAt")
        legacy.removeValue(forKey: "isSessionScheduled")
        let oldPending = try JSONDecoder().decode(SmartWakePendingWakeRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(oldPending.armedAt == pending.scheduledSessionStart, "legacy pending record migrates missing armedAt deterministically")
        check(oldPending.isSessionScheduled, "legacy scheduled occurrence preserves prior ownership schema")
        pendingStore.clearPendingWakeRecord()
        check(pendingStore.loadPendingWakeRecord() == nil, "completed pending occurrence clears persisted recovery state")
        defaults.set(Data("invalid JSON".utf8), forKey: "smartWakePendingWakeRecordData")
        check(pendingStore.loadPendingWakeRecord() == nil, "malformed pending record does not invent occurrence")

        let engine = WakeHeuristicEngine()
        _ = await engine.configure(wakeWindowStart: window, wakeUpTime: wake, armedAt: Date(timeIntervalSince1970: 0), monitoringStartedAt: Date(timeIntervalSince1970: 0))
        let first = await engine.ingestLiveMotionSample(.init(date: window.addingTimeInterval(1), x: 0, y: 0, z: 1))
        check(!first.shouldTrigger && first.snapshot.historicalEventRate == 9.5 && !first.snapshot.verySensitive, "empty history arms ordinary mode")
        let hr = await engine.ingestHeartRateSample(bpm: 250, at: window.addingTimeInterval(2))
        check(!hr.shouldTrigger && !hr.sensorProvenance.usedHeartRate && hr.snapshot.latestHeartRate == 250,
              "heart rate is retained telemetry and never wake evidence")
        check(hr.snapshot.dLimit == first.snapshot.dLimit && hr.snapshot.raLimit == first.snapshot.raLimit,
              "heart rate cannot modify movement thresholds")
        let duplicate = await engine.ingestLiveMotionSample(.init(date: window.addingTimeInterval(1), x: 10, y: 0, z: 1))
        check(!duplicate.shouldTrigger && duplicate.motionScore == 0, "duplicate sensor timestamp is rejected before analyzer")
        let outOfOrder = await engine.ingestLiveMotionSample(.init(date: window, x: 10, y: 0, z: 1))
        check(!outOfOrder.shouldTrigger && outOfOrder.motionScore == 0, "out-of-order sensor timestamp is rejected before analyzer")
        let nonfinite = await engine.ingestLiveMotionSample(.init(date: window.addingTimeInterval(3), x: .nan, y: 0, z: 1))
        check(!nonfinite.shouldTrigger && nonfinite.motionScore == 0, "nonfinite acquisition sample is rejected")
        let timer = await engine.evaluate(at: wake.addingTimeInterval(100))
        check(!timer.shouldTrigger, "timer evaluation does not synthesize stale movement or alter algorithm deadline")
        let lateHR = await engine.ingestHeartRateSample(bpm: 300, at: wake.addingTimeInterval(101))
        check(!lateHR.shouldTrigger, "post-deadline HR still cannot invoke movement rule")
        let deadline = await engine.ingestLiveMotionSample(.init(date: wake.addingTimeInterval(102), x: 0, y: 0, z: 1))
        check(deadline.shouldTrigger, "inactive motion still reaches core deadline check")
        let repeatedDeadline = await engine.ingestLiveMotionSample(.init(date: wake.addingTimeInterval(103), x: 0, y: 0, z: 1))
        check(!repeatedDeadline.shouldTrigger, "core fired latch rejects duplicate deadline")

        _ = await engine.configure(wakeWindowStart: window, wakeUpTime: wake,
            armedAt: Date(timeIntervalSince1970: 0), monitoringStartedAt: window)
        _ = await engine.ingestRecordedHistory(.init(start: 0), latestSample: nil, evaluatedAt: window)
        let quietOvernight = await engine.ingestLiveMotionSample(.init(date: window.addingTimeInterval(1), x: 0, y: 0, z: 1))
        check(quietOvernight.snapshot.historicalEventRate == 0 && quietOvernight.snapshot.verySensitive,
              "non-motion wake-phase event anchors quiet overnight duration without counting movement")
        let quietMovement = await engine.ingestLiveMotionSample(.init(date: window.addingTimeInterval(2), x: 0.2, y: 0, z: 1))
        check(quietMovement.shouldTrigger, "quiet overnight lifecycle selects sensitive movement rule")

        _ = await engine.configure(wakeWindowStart: window, wakeUpTime: wake, armedAt: Date(timeIntervalSince1970: 0), monitoringStartedAt: Date(timeIntervalSince1970: 0))
        let sparse = RecoveredMovementHistory(start: 0, events: [.init(time: 8000, kind: 1, intensity: 0.1)])
        _ = await engine.ingestRecordedHistory(sparse, latestSample: Date(timeIntervalSince1970: 8000), evaluatedAt: window)
        let atBoundary = await engine.ingestLiveMotionSample(.init(date: window, x: 0, y: 0, z: 1))
        check(!atBoundary.shouldTrigger && atBoundary.snapshot.phaseDescription == "sleepy", "exact window boundary stays sleepy")
        let sensitive = await engine.ingestLiveMotionSample(.init(date: window.addingTimeInterval(1), x: 0.2, y: 0, z: 1))
        check(sensitive.shouldTrigger && sensitive.snapshot.verySensitive, "recorded history calibrates before first armed movement")
        await engine.markTriggered(at: window.addingTimeInterval(1))
        let marked = await engine.ingestLiveMotionSample(.init(date: wake.addingTimeInterval(1), x: 0.4, y: 0, z: 1))
        check(!marked.shouldTrigger, "application trigger latch rejects later movement")

        _ = await engine.configure(wakeWindowStart: window, wakeUpTime: wake, armedAt: Date(timeIntervalSince1970: 0), monitoringStartedAt: Date(timeIntervalSince1970: 0))
        let dense = RecoveredMovementHistory(start: 0, sessionEnd: 14400,
            events: (0..<200).map { .init(time: Double($0 * 70 + 100), kind: 1, intensity: 0.4) })
        _ = await engine.ingestRecordedHistory(dense, latestSample: Date(timeIntervalSince1970: 14030), evaluatedAt: window)
        let calibrated = await engine.ingestLiveMotionSample(.init(date: window.addingTimeInterval(1), x: 0, y: 0, z: 1))
        check(calibrated.snapshot.dLimit > 0.39 && !calibrated.snapshot.verySensitive, "eligible dense history calibrates filter")
        _ = await engine.ingestRecordedHistory(sparse, latestSample: Date(timeIntervalSince1970: 8000), evaluatedAt: window.addingTimeInterval(2))
        let frozen = await engine.evaluate(at: window.addingTimeInterval(2))
        check(frozen.snapshot.dLimit == calibrated.snapshot.dLimit && frozen.snapshot.raLimit == calibrated.snapshot.raLimit && !frozen.snapshot.verySensitive,
              "history refresh cannot recalibrate armed rules")
        await engine.reset()
        let reset = await engine.evaluate(at: wake)
        check(!reset.shouldTrigger && reset.snapshot.latestHeartRate == nil && reset.snapshot.motionScore == 0 && reset.snapshot.phaseDescription == "idle",
              "new occurrence clears sensor and alarm state")

        let result: [String: Any] = ["status": "passed", "checks": names.count, "names": names]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}
