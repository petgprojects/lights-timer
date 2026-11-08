import Foundation

/// Lights Timer application policy, deliberately separate from recovered rules.
nonisolated enum SmartWakeExecutionPolicy {
    static func sessionStart(windowStart: Date, wakeUpTime: Date) -> Date {
        max(windowStart.addingTimeInterval(-120), wakeUpTime.addingTimeInterval(-1500))
    }

    static func exactWakeDue(now: Date, wakeUpTime: Date, alreadyTriggered: Bool) -> Bool {
        !alreadyTriggered && now >= wakeUpTime
    }

    static func phoneOwnsLights(activeTrigger: UUID?, activeSchedule: UUID?,
                               acknowledgementTrigger: UUID, acknowledgementSchedule: UUID,
                               phoneWillHandleLights: Bool) -> Bool {
        activeTrigger == acknowledgementTrigger && activeSchedule == acknowledgementSchedule && phoneWillHandleLights
    }
}

nonisolated struct SmartWakeCompletedOccurrence: Codable, Equatable, Sendable {
    let scheduleID: UUID
    let wakeUpTime: Date
}

/// Bounded, persisted completion ledger closes the relaunch-before-cleanup gap.
/// It doesn't import legacy heuristic state into the new algorithm.
final class SmartWakeCompletionStore {
    private let defaults: UserDefaults
    private let key = "smartWakeCompletedOccurrences-v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func contains(scheduleID: UUID, wakeUpTime: Date, now: Date = Date()) -> Bool {
        records(now: now).contains(.init(scheduleID: scheduleID, wakeUpTime: wakeUpTime))
    }

    func record(scheduleID: UUID, wakeUpTime: Date, now: Date = Date()) {
        var values = records(now: now)
        let value = SmartWakeCompletedOccurrence(scheduleID: scheduleID, wakeUpTime: wakeUpTime)
        if !values.contains(value) { values.append(value) }
        if let data = try? JSONEncoder().encode(Array(values.suffix(32))) { defaults.set(data, forKey: key) }
    }

    private func records(now: Date) -> [SmartWakeCompletedOccurrence] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([SmartWakeCompletedOccurrence].self, from: data) else { return [] }
        return values.filter { now.timeIntervalSince($0.wakeUpTime) <= 2 * 86400 }
    }
}
