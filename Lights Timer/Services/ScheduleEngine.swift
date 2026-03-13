import Foundation
import HomeKit
import SwiftData
import Combine
import UIKit

@Observable
final class ScheduleEngine {
    enum SmartWakeStartResult {
        case phoneCommitted
        case watchFallback(reason: String)
    }

    private struct SmartWakeRampPlan {
        let identifiers: [UUID]
        let rampDuration: TimeInterval
        let stepInterval: TimeInterval
        let stepCount: Int
        let firstVisibleStep: Int
        let shouldRemoveFallbackScene: Bool
    }

    private struct SmartWakeStepState {
        let progress: Double
        let brightness: Int
        let hue: Double
        let saturation: Double
    }

    let homeKitService: HomeKitService
    private let lightController: LightController
    private let logStore: PhoneLogStore
    private var timerCancellable: AnyCancellable?
    private var smartWakeTask: Task<Void, Never>?
    private(set) var activeSchedule: LightSchedule?
    private var transitionStartTime: Date?
    private var transitionEndTime: Date?

    var isRunning: Bool { activeSchedule != nil }
    var currentProgress: Double = 0
    private var smartWakeBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Sync State
    private(set) var isSyncing: Bool = false
    private(set) var syncStepsCompleted: Int = 0
    private(set) var syncStepsTotal: Int = 0
    private(set) var lastBackgroundSyncAttemptAt: Date?
    private(set) var lastBackgroundSyncSucceededAt: Date?
    private(set) var lastBackgroundSyncError: String?
    private(set) var hasPendingHomeKitRetry: Bool = false

    init(
        homeKitService: HomeKitService,
        lightController: LightController,
        logStore: PhoneLogStore
    ) {
        self.homeKitService = homeKitService
        self.lightController = lightController
        self.logStore = logStore
    }

    // MARK: - Lifecycle Entry Point

    /// Called when the app comes to foreground or when a schedule is saved.
    /// This is the main entry point that orchestrates everything.
    func onAppActive(modelContext: ModelContext) async {
        log("onAppActive started")

        // 1. Check if any schedule is currently in its execution window
        //    and start foreground execution if so
        await checkForActiveSchedules(modelContext: modelContext)

        // 2. Set up background triggers (scenes) for future schedules
        await homeKitService.waitForReady()
        await syncBackgroundScenes(modelContext: modelContext)

        log("onAppActive finished")
    }

    func retryPendingBackgroundSync(modelContext: ModelContext) async {
        guard hasPendingHomeKitRetry, !homeKitService.homes.isEmpty else { return }
        log("Retrying pending HomeKit background sync")
        await syncBackgroundScenes(modelContext: modelContext)
    }

    // MARK: - Foreground Execution (Direct Writes)

    /// Checks all enabled schedules to see if any are currently in their
    /// execution window (between startTime and wakeUpTime). If so, starts
    /// the foreground timer for smooth transitions.
    func checkForActiveSchedules(modelContext: ModelContext) async {
        // Don't interrupt an already-running execution
        if isRunning {
            log("Skipping active schedule check because an execution is already running", level: .warning)
            return
        }

        do {
            let descriptor = FetchDescriptor<LightSchedule>(
                predicate: #Predicate { $0.isEnabled }
            )
            let schedules = try modelContext.fetch(descriptor)
            let now = Date()

            for schedule in schedules {
                guard !schedule.lightIdentifiers.isEmpty else { continue }
                // Smart wake schedules are triggered by the watch, not the normal timer
                guard !schedule.usesSmartWake else { continue }
                guard let wakeUpTime = nextOccurrence(for: schedule) else { continue }

                let leadSeconds = TimeInterval(schedule.leadTimeMinutes * 60)
                let startTime = wakeUpTime.addingTimeInterval(-leadSeconds)

                // Check if we're currently inside the execution window
                if now >= startTime && now < wakeUpTime {
                    startForegroundExecution(
                        for: schedule,
                        startTime: startTime,
                        endTime: wakeUpTime
                    )
                    return
                }
            }
        } catch {
            log("Failed to check schedules: \(error)", level: .error)
        }
    }

    /// Starts the foreground timer for smooth light transitions.
    /// Called with pre-calculated start/end times.
    func startForegroundExecution(for schedule: LightSchedule, startTime: Date, endTime: Date) {
        activeSchedule = schedule
        transitionStartTime = startTime
        transitionEndTime = endTime

        log("Starting foreground execution for '\(schedule.name)' until \(formatTimestamp(endTime))")

        timerCancellable = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.tickForegroundExecution()
                }
            }

        // Execute immediately as well
        Task {
            await tickForegroundExecution()
        }
    }

    func stopForegroundExecution() {
        timerCancellable?.cancel()
        timerCancellable = nil
        smartWakeTask?.cancel()
        smartWakeTask = nil
        activeSchedule = nil
        transitionStartTime = nil
        transitionEndTime = nil
        currentProgress = 0
        if smartWakeBackgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(smartWakeBackgroundTaskID)
            smartWakeBackgroundTaskID = .invalid
        }
        log("Stopped foreground execution")
    }

    private func tickForegroundExecution() async {
        guard let schedule = activeSchedule,
              let startTime = transitionStartTime,
              let endTime = transitionEndTime else { return }

        let now = Date()
        let progress = calculateProgress(startTime: startTime, endTime: endTime, now: now)
        currentProgress = progress

        if progress >= 1.0 {
            // Final step: set to target values
            let identifiers = schedule.lightIdentifiers.compactMap { UUID(uuidString: $0) }
            try? await lightController.applyToMultipleLights(
                brightness: schedule.targetBrightness,
                hue: schedule.endColorHue * 360.0,
                saturation: schedule.endColorSaturation * 100.0,
                powerOn: true,
                skipColor: schedule.skipColorWrites,
                identifiers: identifiers
            )
            stopForegroundExecution()
            return
        }

        guard progress > 0 else { return }

        let hsb = interpolateHSB(
            startHue: schedule.startColorHue,
            startSat: schedule.startColorSaturation,
            startBri: schedule.startColorBrightness,
            endHue: schedule.endColorHue,
            endSat: schedule.endColorSaturation,
            endBri: schedule.endColorBrightness,
            progress: progress
        )
        let brightness = interpolateBrightness(
            target: schedule.targetBrightness,
            progress: progress
        )

        let identifiers = schedule.lightIdentifiers.compactMap { UUID(uuidString: $0) }

        log("Tick: progress=\(String(format: "%.1f%%", progress * 100)), brightness=\(brightness)")

        do {
            try await lightController.applyToMultipleLights(
                brightness: brightness,
                hue: hsb.hue * 360.0,
                saturation: hsb.saturation * 100.0,
                powerOn: true,
                skipColor: schedule.skipColorWrites,
                identifiers: identifiers
            )
        } catch {
            log("Failed to apply light state: \(error)", level: .error)
        }
    }

    // MARK: - Test Execution

    /// Starts a test run of the full light ramp from now to now + leadTimeMinutes.
    func startTestExecution(for schedule: LightSchedule) {
        guard !isRunning else {
            log("Already running, ignoring test", level: .warning)
            return
        }
        log("Starting test execution for '\(schedule.name)' lasting \(schedule.leadTimeMinutes) minute(s)")
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(TimeInterval(schedule.leadTimeMinutes * 60))
        startForegroundExecution(for: schedule, startTime: startTime, endTime: endTime)
    }

    // MARK: - Smart Wake Execution

    /// Starts a rapid smart-wake ramp from 0% to target brightness.
    /// Uses available background execution time for a smooth ramp (up to 60 seconds).
    /// Falls back to setting final values immediately if background time is very short.
    func startSmartWakeExecution(for schedule: LightSchedule) async -> SmartWakeStartResult {
        guard !isRunning else {
            log("Already running, ignoring smart wake trigger", level: .warning)
            return .watchFallback(reason: "Phone ramp already running")
        }

        log(
            "Attempting smart wake execution for '\(schedule.name)' with backgroundTimeRemaining=\(Int(UIApplication.shared.backgroundTimeRemaining))s"
        )

        await homeKitService.waitForReady(timeout: 6)
        guard !homeKitService.homes.isEmpty else {
            log("HomeKit homes unavailable, cannot start smart wake", level: .warning)
            return .watchFallback(reason: "HomeKit homes unavailable")
        }

        let identifiers = schedule.lightIdentifiers.compactMap { UUID(uuidString: $0) }
        guard !identifiers.isEmpty else {
            log("No light identifiers, cannot start smart wake", level: .warning)
            return .watchFallback(reason: "No light identifiers")
        }

        guard let rampPlan = makeSmartWakeRampPlan(for: schedule, identifiers: identifiers) else {
            log("No visible smart wake step, cannot start smart wake", level: .warning)
            return .watchFallback(reason: "No visible smart wake step")
        }

        log(
            "Smart wake ramp plan for '\(schedule.name)': duration=\(Int(rampPlan.rampDuration))s, stepInterval=\(Int(rampPlan.stepInterval))s, stepCount=\(rampPlan.stepCount), firstVisibleStep=\(rampPlan.firstVisibleStep), lights=\(rampPlan.identifiers.count), removeFallbackScene=\(rampPlan.shouldRemoveFallbackScene)"
        )

        activeSchedule = schedule

        // Request background execution time
        smartWakeBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SmartWakeRamp") {
            UIApplication.shared.endBackgroundTask(self.smartWakeBackgroundTaskID)
            self.smartWakeBackgroundTaskID = .invalid
        }

        // Determine ramp duration based on available background time
        let initialState = smartWakeStepState(
            for: schedule,
            step: rampPlan.firstVisibleStep,
            stepCount: rampPlan.stepCount
        )
        let initialWrite = await lightController.applyBestEffortToMultipleLights(
            brightness: initialState.brightness,
            hue: initialState.hue,
            saturation: initialState.saturation,
            powerOn: true,
            skipColor: schedule.skipColorWrites,
            identifiers: rampPlan.identifiers
        )
        log(
            "Smart wake ownership write for '\(schedule.name)': attempted=\(initialWrite.attempted), succeeded=\(initialWrite.succeeded), brightness=\(initialState.brightness), progress=\(String(format: "%.0f%%", initialState.progress * 100))"
        )
        guard initialWrite.hadAnySuccess else {
            log("Phone could not claim any selected lights for '\(schedule.name)'", level: .warning)
            stopForegroundExecution()
            return .watchFallback(reason: "Phone could not claim any selected lights")
        }

        let commitTime = Date()
        let virtualStartTime = commitTime.addingTimeInterval(
            -rampPlan.rampDuration * initialState.progress
        )
        transitionStartTime = virtualStartTime
        transitionEndTime = virtualStartTime.addingTimeInterval(rampPlan.rampDuration)
        currentProgress = initialState.progress

        smartWakeTask = Task { [weak self] in
            await self?.runSmartWakeExecution(
                for: schedule,
                rampPlan: rampPlan,
                startingStep: rampPlan.firstVisibleStep + 1
            )
        }
        return .phoneCommitted
    }

    private func runSmartWakeExecution(
        for schedule: LightSchedule,
        rampPlan: SmartWakeRampPlan,
        startingStep: Int
    ) async {
        log("Smart wake ramp: \(Int(rampPlan.rampDuration))s, \(rampPlan.stepCount) steps for '\(schedule.name)'")

        if startingStep <= rampPlan.stepCount {
            for step in startingStep...rampPlan.stepCount {
                guard !Task.isCancelled, isRunning else { break }

                let remaining = UIApplication.shared.backgroundTimeRemaining
                if remaining < 6 && remaining < 100 {
                    log("Background time low (\(Int(remaining))s), jumping to final state", level: .warning)
                    break
                }

                let state = smartWakeStepState(
                    for: schedule,
                    step: step,
                    stepCount: rampPlan.stepCount
                )
                currentProgress = state.progress

                log(
                    "Smart wake step \(step)/\(rampPlan.stepCount): brightness=\(state.brightness), progress=\(String(format: "%.0f%%", state.progress * 100))"
                )

                let stepWrite = await lightController.applyBestEffortToMultipleLights(
                    brightness: state.brightness,
                    hue: state.hue,
                    saturation: state.saturation,
                    powerOn: true,
                    skipColor: schedule.skipColorWrites,
                    identifiers: rampPlan.identifiers
                )
                log(
                    "Smart wake step \(step) write summary: attempted=\(stepWrite.attempted), succeeded=\(stepWrite.succeeded)"
                )
                if !stepWrite.hadAnySuccess {
                    log("Smart wake step \(step) did not reach any selected lights", level: .warning)
                }

                if step < rampPlan.stepCount {
                    try? await Task.sleep(for: .seconds(rampPlan.stepInterval))
                }
            }
        }

        if !Task.isCancelled {
            let finalWrite = await lightController.applyBestEffortToMultipleLights(
                brightness: schedule.targetBrightness,
                hue: schedule.endColorHue * 360.0,
                saturation: schedule.endColorSaturation * 100.0,
                powerOn: true,
                skipColor: schedule.skipColorWrites,
                identifiers: rampPlan.identifiers
            )
            log(
                "Smart wake final write summary: attempted=\(finalWrite.attempted), succeeded=\(finalWrite.succeeded), brightness=\(schedule.targetBrightness)"
            )
            if !finalWrite.hadAnySuccess {
                log("Smart wake final write did not reach any selected lights", level: .warning)
            }

            if rampPlan.shouldRemoveFallbackScene && finalWrite.hadAnySuccess {
                log("Phone ramp completed successfully; removing fallback scenes for '\(schedule.name)'")
                await cleanupScenesForSchedule(schedule.id)
            }
        }

        stopForegroundExecution()
    }

    /// Removes background scenes and triggers for a specific schedule.
    private func cleanupScenesForSchedule(_ scheduleID: UUID) async {
        let shortID = String(scheduleID.uuidString.prefix(8))
        let prefix = "LT_\(shortID)_"

        log("Cleaning up scenes for schedule prefix \(prefix)")

        for home in homeKitService.homes {
            let triggers = home.triggers.filter { $0.name.hasPrefix(prefix) }
            for trigger in triggers {
                try? await removeTrigger(trigger, from: home)
            }
            let scenes = home.actionSets.filter { $0.name.hasPrefix(prefix) }
            for scene in scenes {
                try? await removeActionSet(scene, from: home)
            }
        }
    }

    private func makeSmartWakeRampPlan(
        for schedule: LightSchedule,
        identifiers: [UUID]
    ) -> SmartWakeRampPlan? {
        let availableTime = UIApplication.shared.backgroundTimeRemaining
        let rampDuration: TimeInterval
        let shouldRemoveFallbackScene: Bool
        if availableTime > 120 {
            rampDuration = 60
            shouldRemoveFallbackScene = true
        } else {
            rampDuration = max(min(availableTime - 8, 60), 3)
            shouldRemoveFallbackScene = false
        }

        let stepInterval: TimeInterval = 5
        let stepCount = max(Int(rampDuration / stepInterval), 1)
        guard let firstVisibleStep = (0...stepCount).first(where: { step in
            let progress = min(Double(step) / Double(stepCount), 1.0)
            return interpolateBrightness(target: schedule.targetBrightness, progress: progress) > 0
        }) else {
            return nil
        }

        return SmartWakeRampPlan(
            identifiers: identifiers,
            rampDuration: rampDuration,
            stepInterval: stepInterval,
            stepCount: stepCount,
            firstVisibleStep: firstVisibleStep,
            shouldRemoveFallbackScene: shouldRemoveFallbackScene
        )
    }

    private func smartWakeStepState(
        for schedule: LightSchedule,
        step: Int,
        stepCount: Int
    ) -> SmartWakeStepState {
        let progress = min(Double(step) / Double(stepCount), 1.0)
        let brightness = interpolateBrightness(
            target: schedule.targetBrightness,
            progress: progress
        )
        let hsb = interpolateHSB(
            startHue: schedule.startColorHue,
            startSat: schedule.startColorSaturation,
            startBri: schedule.startColorBrightness,
            endHue: schedule.endColorHue,
            endSat: schedule.endColorSaturation,
            endBri: schedule.endColorBrightness,
            progress: progress
        )

        return SmartWakeStepState(
            progress: progress,
            brightness: brightness,
            hue: hsb.hue * 360.0,
            saturation: hsb.saturation * 100.0
        )
    }

    // MARK: - Background Scenes (HMActionSet + HMTimerTrigger)

    /// Creates HomeKit scenes and timer triggers for background execution.
    /// Each scene sets all target lights to a specific brightness/color step.
    /// Scenes are spaced 1 minute apart (the minimum reliable interval per the user).
    func syncBackgroundScenes(modelContext: ModelContext) async {
        lastBackgroundSyncAttemptAt = Date()

        guard !homeKitService.homes.isEmpty else {
            hasPendingHomeKitRetry = true
            lastBackgroundSyncError = "Waiting for HomeKit homes"
            log("No HomeKit homes available, skipping scene sync", level: .warning)
            return
        }

        guard !isSyncing else {
            log("Sync already in progress, skipping", level: .warning)
            return
        }

        isSyncing = true
        syncStepsCompleted = 0
        syncStepsTotal = 0

        defer {
            isSyncing = false
            syncStepsCompleted = 0
            syncStepsTotal = 0
        }

        do {
            hasPendingHomeKitRetry = false
            // Clean up old scenes and triggers we previously created
            await cleanupOldScenesAndTriggers()

            let descriptor = FetchDescriptor<LightSchedule>(
                predicate: #Predicate { $0.isEnabled }
            )
            let schedules = try modelContext.fetch(descriptor)

            // Pre-calculate total steps for progress tracking
            let now = Date()
            var totalSteps = 0
            for schedule in schedules {
                guard !schedule.lightIdentifiers.isEmpty,
                      let wakeUpTime = nextOccurrence(for: schedule) else { continue }
                if schedule.usesSmartWake {
                    // Smart wake: single fallback scene at wake time
                    if wakeUpTime > now { totalSteps += 1 }
                } else {
                    let startTime = wakeUpTime.addingTimeInterval(-TimeInterval(schedule.leadTimeMinutes * 60))
                    for step in 1...schedule.leadTimeMinutes {
                        let fireDate = startTime.addingTimeInterval(Double(step - 1) * 60.0)
                        if fireDate > now { totalSteps += 1 }
                    }
                }
            }
            syncStepsTotal = totalSteps

            for schedule in schedules {
                await createScenesForSchedule(schedule)
            }

            lastBackgroundSyncSucceededAt = Date()
            lastBackgroundSyncError = nil
            log("Finished background scene sync")
        } catch {
            lastBackgroundSyncError = error.localizedDescription
            log("Failed to sync scenes: \(error)", level: .error)
        }
    }

    private func cleanupOldScenesAndTriggers() async {
        log("Cleaning up old HomeKit scenes and triggers")
        for home in homeKitService.homes {
            // Remove old triggers
            let oldTriggers = home.triggers.filter { $0.name.hasPrefix("LT_") }
            for trigger in oldTriggers {
                do {
                    try await removeTrigger(trigger, from: home)
                } catch {
                    log("Failed to remove trigger: \(error)", level: .error)
                }
            }

            // Remove old action sets (scenes)
            let oldScenes = home.actionSets.filter { $0.name.hasPrefix("LT_") }
            for scene in oldScenes {
                do {
                    try await removeActionSet(scene, from: home)
                } catch {
                    log("Failed to remove scene: \(error)", level: .error)
                }
            }
        }
    }

    private func createScenesForSchedule(_ schedule: LightSchedule) async {
        guard let wakeUpTime = nextOccurrence(for: schedule) else {
            log("No next occurrence for '\(schedule.name)'", level: .warning)
            return
        }

        let identifiers = schedule.lightIdentifiers.compactMap { UUID(uuidString: $0) }
        guard !identifiers.isEmpty else { return }

        // Find the home containing these lights
        guard let home = homeKitService.homes.first(where: { home in
            home.accessories.contains { accessory in
                identifiers.contains(accessory.uniqueIdentifier)
            }
        }) else {
            log("No home found with target lights", level: .warning)
            return
        }

        let shortID = String(schedule.id.uuidString.prefix(8))

        // Smart wake schedules: only create a single fallback scene at wake time.
        // The watch handles the actual trigger; this is a safety net if the watch is unavailable.
        if schedule.usesSmartWake {
            let now = Date()
            guard wakeUpTime > now else { return }

            let sceneName = "LT_\(shortID)_fallback"
            log("Creating fallback scene for smart wake '\(schedule.name)' at \(formatTimestamp(wakeUpTime))")

            do {
                let actionSet = try await addActionSet(withName: sceneName, to: home)

                for accessoryID in identifiers {
                    guard let accessory = home.accessories.first(where: {
                        $0.uniqueIdentifier == accessoryID
                    }) else { continue }
                    guard let service = accessory.services.first(where: {
                        $0.serviceType == HMServiceTypeLightbulb
                    }) else { continue }

                    if let char = service.characteristics.first(where: {
                        $0.characteristicType == HMCharacteristicTypePowerState
                    }) {
                        let action = HMCharacteristicWriteAction(characteristic: char, targetValue: true as NSNumber)
                        try await addAction(action, to: actionSet)
                    }
                    if let char = service.characteristics.first(where: {
                        $0.characteristicType == HMCharacteristicTypeBrightness
                    }) {
                        let action = HMCharacteristicWriteAction(characteristic: char, targetValue: schedule.targetBrightness as NSNumber)
                        try await addAction(action, to: actionSet)
                    }
                    // Skip color writes to preserve Adaptive Lighting
                    if !schedule.skipColorWrites {
                        if let char = service.characteristics.first(where: {
                            $0.characteristicType == HMCharacteristicTypeHue
                        }) {
                            let action = HMCharacteristicWriteAction(characteristic: char, targetValue: (schedule.endColorHue * 360.0) as NSNumber)
                            try await addAction(action, to: actionSet)
                        }
                        if let char = service.characteristics.first(where: {
                            $0.characteristicType == HMCharacteristicTypeSaturation
                        }) {
                            let action = HMCharacteristicWriteAction(characteristic: char, targetValue: (schedule.endColorSaturation * 100.0) as NSNumber)
                            try await addAction(action, to: actionSet)
                        }
                    }
                }

                let trigger = HMTimerTrigger(name: sceneName, fireDate: wakeUpTime, timeZone: .current, recurrence: nil, recurrenceCalendar: nil)
                try await addTrigger(trigger, to: home)
                try await addActionSetToTrigger(actionSet, trigger: trigger)
                try await enableTrigger(trigger)
                syncStepsCompleted += 1
            } catch {
                log("Failed to create fallback scene \(sceneName): \(error)", level: .error)
                syncStepsCompleted += 1
            }

            log("Finished creating fallback scene for '\(schedule.name)'")
            return
        }

        // Normal schedules: create gradual ramp scenes spaced 1 minute apart
        let leadSeconds = TimeInterval(schedule.leadTimeMinutes * 60)
        let startTime = wakeUpTime.addingTimeInterval(-leadSeconds)
        let stepCount = schedule.leadTimeMinutes
        let now = Date()

        log("Creating \(stepCount) scenes for '\(schedule.name)' starting at \(formatTimestamp(startTime))")

        for step in 1...stepCount {
            let progress = Double(step) / Double(stepCount)
            let fireDate = startTime.addingTimeInterval(Double(step - 1) * 60.0)

            // Skip steps that are already in the past
            guard fireDate > now else { continue }

            let brightness = interpolateBrightness(
                target: schedule.targetBrightness,
                progress: progress
            )
            let hsb = interpolateHSB(
                startHue: schedule.startColorHue,
                startSat: schedule.startColorSaturation,
                startBri: schedule.startColorBrightness,
                endHue: schedule.endColorHue,
                endSat: schedule.endColorSaturation,
                endBri: schedule.endColorBrightness,
                progress: progress
            )

            let sceneName = "LT_\(shortID)_\(step)"

            do {
                // 1. Create the scene (action set) on the home
                let actionSet = try await addActionSet(withName: sceneName, to: home)

                // 2. Add actions for each light
                for accessoryID in identifiers {
                    guard let accessory = home.accessories.first(where: {
                        $0.uniqueIdentifier == accessoryID
                    }) else { continue }

                    guard let service = accessory.services.first(where: {
                        $0.serviceType == HMServiceTypeLightbulb
                    }) else { continue }

                    // Power on
                    if let char = service.characteristics.first(where: {
                        $0.characteristicType == HMCharacteristicTypePowerState
                    }) {
                        let action = HMCharacteristicWriteAction(
                            characteristic: char, targetValue: true as NSNumber
                        )
                        try await addAction(action, to: actionSet)
                    }

                    // Brightness
                    if let char = service.characteristics.first(where: {
                        $0.characteristicType == HMCharacteristicTypeBrightness
                    }) {
                        let action = HMCharacteristicWriteAction(
                            characteristic: char, targetValue: brightness as NSNumber
                        )
                        try await addAction(action, to: actionSet)
                    }

                    // Skip color writes to preserve Adaptive Lighting
                    if !schedule.skipColorWrites {
                        // Hue (color lights only)
                        if let char = service.characteristics.first(where: {
                            $0.characteristicType == HMCharacteristicTypeHue
                        }) {
                            let action = HMCharacteristicWriteAction(
                                characteristic: char, targetValue: (hsb.hue * 360.0) as NSNumber
                            )
                            try await addAction(action, to: actionSet)
                        }

                        // Saturation (color lights only)
                        if let char = service.characteristics.first(where: {
                            $0.characteristicType == HMCharacteristicTypeSaturation
                        }) {
                            let action = HMCharacteristicWriteAction(
                                characteristic: char, targetValue: (hsb.saturation * 100.0) as NSNumber
                            )
                            try await addAction(action, to: actionSet)
                        }
                    }
                }

                // 3. Create a timer trigger for this scene
                let trigger = HMTimerTrigger(
                    name: sceneName,
                    fireDate: fireDate,
                    timeZone: .current,
                    recurrence: nil,
                    recurrenceCalendar: nil
                )

                try await addTrigger(trigger, to: home)
                try await addActionSetToTrigger(actionSet, trigger: trigger)
                try await enableTrigger(trigger)

                syncStepsCompleted += 1
            } catch {
                log("Failed to create scene \(sceneName): \(error)", level: .error)
                syncStepsCompleted += 1
            }
        }

        log("Finished creating scenes for '\(schedule.name)'")
    }

    // MARK: - Helpers

    func nextOccurrence(for schedule: LightSchedule) -> Date? {
        let calendar = Calendar.current
        let now = Date()
        let activeDays = schedule.activeDays

        guard !activeDays.isEmpty else { return nil }

        for dayOffset in 0..<8 {
            guard let candidateDate = calendar.date(byAdding: .day, value: dayOffset, to: now) else {
                continue
            }

            let weekday = calendar.component(.weekday, from: candidateDate)
            guard let dayOfWeek = DayOfWeek(rawValue: weekday),
                  activeDays.contains(dayOfWeek) else { continue }

            var components = calendar.dateComponents([.year, .month, .day], from: candidateDate)
            components.hour = schedule.wakeUpHour
            components.minute = schedule.wakeUpMinute
            components.second = 0

            guard let wakeUpTime = calendar.date(from: components) else { continue }

            // For today, only count if the wake-up time hasn't passed yet
            if wakeUpTime > now {
                return wakeUpTime
            }
        }

        return nil
    }

    func calculateProgress(startTime: Date, endTime: Date, now: Date) -> Double {
        let total = endTime.timeIntervalSince(startTime)
        guard total > 0 else { return 1.0 }
        let elapsed = now.timeIntervalSince(startTime)
        return min(max(elapsed / total, 0), 1.0)
    }

    // MARK: - Async HomeKit Wrappers

    private func removeTrigger(_ trigger: HMTrigger, from home: HMHome) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.removeTrigger(trigger) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func removeActionSet(_ actionSet: HMActionSet, from home: HMHome) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.removeActionSet(actionSet) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func addTrigger(_ trigger: HMTimerTrigger, to home: HMHome) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.addTrigger(trigger) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func addActionSet(withName name: String, to home: HMHome) async throws -> HMActionSet {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HMActionSet, Error>) in
            home.addActionSet(withName: name) { actionSet, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let actionSet {
                    continuation.resume(returning: actionSet)
                } else {
                    continuation.resume(throwing: HomeKitServiceError.serviceNotFound)
                }
            }
        }
    }

    private func addAction(_ action: HMAction, to actionSet: HMActionSet) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            actionSet.addAction(action) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func addActionSetToTrigger(_ actionSet: HMActionSet, trigger: HMTrigger) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.addActionSet(actionSet) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func enableTrigger(_ trigger: HMTrigger) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.enable(true) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func log(_ message: String, level: PhoneLogLevel = .info) {
        logStore.log("ScheduleEngine", message, level: level)
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
