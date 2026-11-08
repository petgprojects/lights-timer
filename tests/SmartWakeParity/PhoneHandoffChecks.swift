import Foundation
import SwiftData

// Only platform effects are replaced. The runner compiles the production
// coordinator and SwiftData models, so validation/ownership logic is not copied.
enum PhoneLogLevel { case info, warning, error }
final class PhoneLogStore {
    func log(_ category: String, _ message: String, level: PhoneLogLevel = .info) {}
}

final class ScheduleEngine {
    enum StartResult {
        case phoneCommitted
        case watchFallback(String)
    }
    var isRunning = false
    var result = StartResult.phoneCommitted
    private(set) var executionCount = 0
    func startSmartWakeExecution(for schedule: LightSchedule) async -> StartResult {
        executionCount += 1
        return result
    }
}

final class WatchConnectivityService {
    var onSmartWakeTrigger: ((SmartWakeTriggerPayload) -> Void)?
    var onHapticPatternChanged: ((HapticPatternChangePayload) -> Void)?
    var onTestTrigger: ((SmartWakeTriggerPayload) -> Void)?
    private(set) var handoffs: [SmartWakeLightHandoffPayload] = []
    private(set) var sentSchedules: [WatchScheduleSnapshot] = []
    func sendLightHandoff(_ handoff: SmartWakeLightHandoffPayload) { handoffs.append(handoff) }
    func sendSchedules(_ snapshots: [WatchScheduleSnapshot]) { sentSchedules = snapshots }
}

@main
struct PhoneHandoffChecks {
    @MainActor
    struct Fixture {
        let container: ModelContainer
        let schedule: LightSchedule
        let coordinator: SmartWakeCoordinator
        let engine: ScheduleEngine
        let connectivity: WatchConnectivityService
        let now: Date

        init(exactWake: Bool = false) throws {
            now = Date()
            let wake = exactWake ? now : now.addingTimeInterval(10 * 60)
            let parts = Calendar.current.dateComponents([.hour, .minute], from: wake)
            container = try ModelContainer(
                for: LightSchedule.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            schedule = LightSchedule(
                name: "Handoff check",
                wakeUpHour: parts.hour!,
                wakeUpMinute: parts.minute!,
                activeDays: Set(DayOfWeek.allCases),
                usesSmartWake: true
            )
            container.mainContext.insert(schedule)
            try container.mainContext.save()
            engine = ScheduleEngine()
            connectivity = WatchConnectivityService()
            coordinator = SmartWakeCoordinator(
                scheduleEngine: engine,
                watchConnectivity: connectivity,
                modelContainer: container,
                logStore: PhoneLogStore()
            )
        }

        func payload(date: Date? = nil, id: UUID? = nil) -> SmartWakeTriggerPayload {
            SmartWakeTriggerPayload(
                scheduleID: id ?? schedule.id,
                triggerDate: date ?? now,
                confidence: 1,
                heartRateAtTrigger: nil,
                motionLevel: 0.2
            )
        }

        func save() throws { try container.mainContext.save() }
    }

    @MainActor
    static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            checks += 1
        }

        let committed = try Fixture()
        let original = committed.payload()
        await committed.coordinator.handleTrigger(original)
        check(committed.engine.executionCount == 1, "valid movement trigger executes lights")
        check(committed.connectivity.handoffs.last?.phoneWillHandleLights == true, "ack follows commitment")
        await committed.coordinator.handleTrigger(original)
        check(committed.engine.executionCount == 1, "duplicate ID does not execute again")
        check(committed.connectivity.handoffs.count == 2 && committed.connectivity.handoffs[0] == committed.connectivity.handoffs[1], "duplicate delivery resends ownership ack")
        await committed.coordinator.handleTrigger(committed.payload())
        check(committed.engine.executionCount == 1, "new trigger ID cannot fire same occurrence again")

        let unavailable = try Fixture()
        unavailable.engine.result = .watchFallback("HomeKit unavailable")
        await unavailable.coordinator.handleTrigger(unavailable.payload())
        check(unavailable.connectivity.handoffs.last?.phoneWillHandleLights == false, "failed phone write defers to watch")
        check(unavailable.connectivity.handoffs.last?.reason == "HomeKit unavailable", "fallback reason preserved")

        let busy = try Fixture()
        busy.engine.isRunning = true
        await busy.coordinator.handleTrigger(busy.payload())
        check(busy.engine.executionCount == 0 && busy.connectivity.handoffs.last?.phoneWillHandleLights == false, "busy phone defers without second ramp")

        let exact = try Fixture(exactWake: true)
        await exact.coordinator.handleTrigger(exact.payload())
        check(exact.engine.executionCount == 1 && exact.connectivity.handoffs.last?.phoneWillHandleLights == true, "exact-wake fallback can obtain phone ownership")

        let rejected = try Fixture()
        await rejected.coordinator.handleTrigger(rejected.payload(date: rejected.now.addingTimeInterval(-7_201)))
        check(rejected.connectivity.handoffs.last?.reason == "Stale trigger", "stale trigger rejected")
        await rejected.coordinator.handleTrigger(rejected.payload(date: rejected.now.addingTimeInterval(180)))
        check(rejected.connectivity.handoffs.last?.reason == "Trigger date too far in future", "future trigger rejected")
        await rejected.coordinator.handleTrigger(rejected.payload(date: rejected.now.addingTimeInterval(-1_800)))
        check(rejected.connectivity.handoffs.last?.reason == "Outside wake window", "outside window rejected")
        await rejected.coordinator.handleTrigger(rejected.payload(id: UUID()))
        check(rejected.connectivity.handoffs.last?.reason == "Schedule not found", "unknown schedule rejected")
        check(rejected.engine.executionCount == 0, "rejected triggers never write lights")

        let disabled = try Fixture()
        disabled.schedule.isEnabled = false
        try disabled.save()
        await disabled.coordinator.handleTrigger(disabled.payload())
        check(disabled.engine.executionCount == 0 && disabled.connectivity.handoffs.last?.reason == "Schedule disabled", "disabled schedule rejected")

        let ordinary = try Fixture()
        ordinary.schedule.usesSmartWake = false
        try ordinary.save()
        await ordinary.coordinator.handleTrigger(ordinary.payload())
        check(ordinary.engine.executionCount == 0 && ordinary.connectivity.handoffs.last?.reason == "Smart wake not enabled", "ordinary schedule rejected")

        let changed = try Fixture()
        // The original occurrence is outside this trigger's window. Only the
        // persisted replacement occurrence can accept the trigger.
        let currentHour = Calendar.current.component(.hour, from: changed.now)
        let originalHour = currentHour < 12 ? currentHour + 8 : currentHour - 8
        let originalWake = Calendar.current.date(bySettingHour: originalHour, minute: 0, second: 0, of: changed.now)!
        changed.schedule.wakeUpHour = originalHour
        changed.schedule.wakeUpMinute = 0
        changed.schedule.oneDayOverrideOriginalWakeDate = originalWake
        changed.schedule.oneDayOverrideWakeDate = changed.now.addingTimeInterval(10 * 60)
        try changed.save()
        await changed.coordinator.handleTrigger(changed.payload())
        check(changed.engine.executionCount == 1, "one-day replacement wake accepts trigger")
        check(changed.connectivity.handoffs.last?.phoneWillHandleLights == true, "one-day replacement preserves phone ownership")

        let sync = try Fixture()
        let nonSmart = LightSchedule(name: "Ordinary", usesSmartWake: false)
        let inactive = LightSchedule(name: "Disabled", usesSmartWake: true)
        inactive.isEnabled = false
        sync.container.mainContext.insert(nonSmart)
        sync.container.mainContext.insert(inactive)
        try sync.save()
        sync.coordinator.syncSchedulesToWatch(modelContext: sync.container.mainContext)
        check(sync.connectivity.sentSchedules.map(\.id) == [sync.schedule.id], "sync contains only enabled smart wake schedules")

        print("\(checks) phone coordinator integration checks passed")
    }
}
