import Foundation
import HealthKit
import HomeKit
#if os(watchOS)
import WatchKit
#endif

private enum WatchFallbackMode {
    case earlyRamp
    case exactWakeFinalState
}

private struct WatchLightRampPlan {
    let rampDuration: TimeInterval
    let stepInterval: TimeInterval
    let stepCount: Int
    let firstVisibleStep: Int?
}

private struct WatchLightState {
    let brightness: Int
    let hue: Double
    let saturation: Double
}

@Observable
final class SmartWakeSessionController: NSObject {
    let healthStore = HKHealthStore()
    let heuristicEngine = WakeHeuristicEngine()
    let logStore: SmartWakeLogStore

    private(set) var sessionState: SmartWakeSessionState.State = .idle
    private(set) var currentScheduleID: UUID?
    private(set) var errorMessage: String?
    private(set) var isHealthKitAuthorized: Bool = false
    private(set) var isMonitoringActive = false

    private(set) var nextScheduledWakeWindowDescription: String?
    private(set) var didReceivePhoneHandoffAck = false
    private(set) var handoffAckStatus = "No recent trigger"
    private(set) var deferredLocalRampStatus = "Idle"

    /// Set by SmartAlarmScheduler to indicate the extended runtime session is active.
    var isAlarmSessionActive: Bool = false

    /// Set by SmartAlarmScheduler before monitoring starts.
    var hapticPatternType: HapticPattern = .gentle

    private let homeKitService: WatchHomeKitService
    private let lightController: WatchLightController

    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var heartRateQuery: HKAnchoredObjectQuery?
    private var wakeCheckTimer: Timer?
    private var historicalSeedTask: Task<Void, Never>?
    private var lightRampTask: Task<Void, Never>?
    private var deferredLightRampTask: Task<Void, Never>?

    private var currentSchedule: WatchScheduleSnapshot?
    private var wakeUpTime: Date?
    private var windowStartTime: Date?
    private var activeTriggerID: UUID?
    private var activeTriggerSchedule: WatchScheduleSnapshot?
    private var activeTriggerDate: Date?
    private var activeTriggerWakeUpTime: Date?
    private var activeTriggerFallbackMode: WatchFallbackMode?
    private var activeLocalRampTriggerID: UUID?
    private var didLogWakeWindowStart = false

    // Haptic alarm
    private var hapticTimer: Timer?
    private var hapticStartTime: Date?
    private var lastHapticPlayTime: Date?
    private var heartbeatPendingSecondBeat = false
    private let hapticDuration: TimeInterval = 60
    private let historicalSeedLookback: TimeInterval = 7200
    private let watchLightHandoffDelay: TimeInterval = 8

    var onTrigger: ((SmartWakeTriggerPayload) -> Void)?
    var onStateChange: ((SmartWakeSessionState) -> Void)?
    var onLogReadyToTransfer: ((URL) -> Void)?

    init(logStore: SmartWakeLogStore) {
        self.logStore = logStore
        let homeKitService = WatchHomeKitService()
        self.homeKitService = homeKitService
        self.lightController = WatchLightController(homeKitService: homeKitService)
        super.init()

        heuristicEngine.logHandler = { [weak self] level, message in
            self?.log("HEURISTIC", message, level: level)
        }
        homeKitService.logHandler = { [weak self] level, message in
            self?.log("HOMEKIT", message, level: level)
        }
        lightController.logHandler = { [weak self] level, message in
            self?.log("LIGHTS", message, level: level)
        }
    }

    private func log(_ category: String, _ message: String, level: SmartWakeLogLevel = .info) {
        logStore.log(category, message, level: level)
    }

    private func queueActiveLogTransfer() {
        guard let logURL = logStore.activeLogFile?.url else { return }
        onLogReadyToTransfer?(logURL)
    }

    private func formatTimestamp(_ date: Date?) -> String {
        guard let date else { return "--" }
        return Self.timestampFormatter.string(from: date)
    }

    private func formatBPM(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f", value)
    }

    private func describeFallbackMode(_ mode: WatchFallbackMode) -> String {
        switch mode {
        case .earlyRamp:
            "earlyRamp"
        case .exactWakeFinalState:
            "exactWakeFinalState"
        }
    }

    private func describeWriteSummary(_ summary: WatchMultiLightWriteSummary) -> String {
        let failedLights = summary.results
            .filter { !$0.succeeded }
            .map { result in
                let label = result.accessoryName ?? result.accessoryID.uuidString
                if let errorDescription = result.errorDescription {
                    return "\(label): \(errorDescription)"
                }
                return "\(label): unknown error"
            }

        let failureSuffix: String
        if failedLights.isEmpty {
            failureSuffix = ""
        } else {
            failureSuffix = " | failures=\(failedLights.joined(separator: "; "))"
        }

        return "attempted=\(summary.attempted) succeeded=\(summary.succeeded) failed=\(summary.failed)\(failureSuffix)"
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        formatter.timeZone = .current
        return formatter
    }()

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        let heartRate = HKQuantityType(.heartRate)
        let activeEnergy = HKQuantityType(.activeEnergyBurned)
        let workout = HKObjectType.workoutType()

        let readTypes: Set<HKObjectType> = [heartRate, activeEnergy]
        let writeTypes: Set<HKSampleType> = [workout]

        do {
            try await healthStore.requestAuthorization(toShare: writeTypes, read: readTypes)
            let status = healthStore.authorizationStatus(for: heartRate)
            isHealthKitAuthorized = status == .sharingAuthorized || status != .notDetermined
            log(
                "HEALTHKIT",
                "Authorization request completed. heartRateStatus=\(status.rawValue) authorized=\(isHealthKitAuthorized)"
            )
            return isHealthKitAuthorized
        } catch {
            errorMessage = error.localizedDescription
            isHealthKitAuthorized = false
            log(
                "HEALTHKIT",
                "Authorization request failed: \(error.localizedDescription)",
                level: .error
            )
            return false
        }
    }

    // MARK: - Scheduling Diagnostics

    func updateNextScheduledWakeWindow(schedule: WatchScheduleSnapshot?, wakeUpTime: Date?) {
        guard let schedule, let wakeUpTime else {
            nextScheduledWakeWindowDescription = nil
            log("SCHEDULER", "Cleared next scheduled wake window")
            return
        }

        let windowStart = wakeUpTime.addingTimeInterval(-Double(schedule.smartWakeWindowMinutes) * 60)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        nextScheduledWakeWindowDescription = "\(schedule.name): \(formatter.string(from: windowStart)) - \(formatter.string(from: wakeUpTime))"
        log(
            "SCHEDULER",
            "Updated next wake window for '\(schedule.name)' to \(formatTimestamp(windowStart)) -> \(formatTimestamp(wakeUpTime))"
        )
    }

    // MARK: - Session Lifecycle

    func startMonitoring(
        schedule: WatchScheduleSnapshot,
        wakeUpTime: Date
    ) async {
        guard !isMonitoringActive else {
            log("SESSION", "Ignoring duplicate startMonitoring for '\(schedule.name)'")
            return
        }

        let windowStartTime = wakeUpTime.addingTimeInterval(
            -Double(schedule.smartWakeWindowMinutes) * 60
        )

        errorMessage = nil
        currentSchedule = schedule
        currentScheduleID = schedule.id
        self.wakeUpTime = wakeUpTime
        self.windowStartTime = windowStartTime
        didLogWakeWindowStart = false
        heuristicEngine.configure(wakeWindowStart: windowStartTime)
        log(
            "SESSION",
            "Starting monitoring for '\(schedule.name)' wake=\(formatTimestamp(wakeUpTime)) windowStart=\(formatTimestamp(windowStartTime)) haptic=\(hapticPatternType.displayName)"
        )

        isMonitoringActive = true
        sessionState = .monitoring
        notifyStateChange()

        do {
            try await startWorkoutSession()
            startHeartRateQuery(from: Date())
            startWakeCheckTimer()
            checkForWakeTrigger()
            startHistoricalSeed(
                from: wakeUpTime.addingTimeInterval(-historicalSeedLookback),
                to: Date()
            )
            log("SESSION", "Monitoring started successfully for schedule \(schedule.id.uuidString)")
        } catch {
            failMonitoring("Failed to start session: \(error.localizedDescription)")
        }
    }

    func finishMonitoringAfterTrigger() {
        guard isMonitoringActive || sessionState == .triggered else { return }

        log(
            "SESSION",
            "Finishing monitoring after trigger. Deferred handoff/light fallback may continue."
        )
        tearDownMonitoringSession()
        currentSchedule = nil
        currentScheduleID = nil
        wakeUpTime = nil
        windowStartTime = nil
        didLogWakeWindowStart = false
        isMonitoringActive = false

        Task { [weak self] in
            await self?.endWorkoutSession()
            await MainActor.run {
                guard let self else { return }
                self.sessionState = .idle
                self.notifyStateChange()
                self.log("SESSION", "Monitoring cleanup completed after trigger")
            }
        }
    }

    func stopMonitoring() {
        log("SESSION", "Stopping monitoring manually")
        tearDownMonitoringSession()
        stopHaptics()
        deferredLightRampTask?.cancel()
        deferredLightRampTask = nil
        lightRampTask?.cancel()
        lightRampTask = nil
        activeLocalRampTriggerID = nil
        activeTriggerID = nil
        activeTriggerSchedule = nil
        activeTriggerDate = nil
        activeTriggerWakeUpTime = nil
        activeTriggerFallbackMode = nil

        currentSchedule = nil
        currentScheduleID = nil
        wakeUpTime = nil
        windowStartTime = nil
        didLogWakeWindowStart = false
        isMonitoringActive = false
        errorMessage = nil
        sessionState = .idle
        notifyStateChange()

        Task { [weak self] in
            await self?.endWorkoutSession()
        }

        log("SESSION", "Monitoring stopped")
        queueActiveLogTransfer()
    }

    private func failMonitoring(_ message: String) {
        log("SESSION", "Monitoring failed: \(message)", level: .error)
        tearDownMonitoringSession()
        stopHaptics()
        deferredLightRampTask?.cancel()
        deferredLightRampTask = nil
        lightRampTask?.cancel()
        lightRampTask = nil
        activeLocalRampTriggerID = nil
        activeTriggerID = nil
        activeTriggerSchedule = nil
        activeTriggerDate = nil
        activeTriggerWakeUpTime = nil
        activeTriggerFallbackMode = nil

        currentSchedule = nil
        currentScheduleID = nil
        wakeUpTime = nil
        windowStartTime = nil
        didLogWakeWindowStart = false
        isMonitoringActive = false
        errorMessage = message
        sessionState = .failed
        notifyStateChange()

        Task { [weak self] in
            await self?.endWorkoutSession()
        }

        queueActiveLogTransfer()
    }

    private func tearDownMonitoringSession() {
        wakeCheckTimer?.invalidate()
        wakeCheckTimer = nil

        historicalSeedTask?.cancel()
        historicalSeedTask = nil

        if let query = heartRateQuery {
            healthStore.stop(query)
            heartRateQuery = nil
        }
    }

    // MARK: - Handoff

    func handleLightHandoff(_ payload: SmartWakeLightHandoffPayload) {
        guard payload.triggerID == activeTriggerID else {
            log(
                "HANDOFF",
                "Ignoring stale handoff for trigger \(payload.triggerID.uuidString). active=\(activeTriggerID?.uuidString ?? "nil")",
                level: .warning
            )
            return
        }

        didReceivePhoneHandoffAck = true
        handoffAckStatus = payload.phoneWillHandleLights
            ? "Phone accepted lights"
            : "Phone declined lights\(payload.reason.map { ": \($0)" } ?? "")"

        if payload.phoneWillHandleLights {
            guard activeLocalRampTriggerID == nil else {
                deferredLocalRampStatus = "Watch fallback already started before ack"
                log(
                    "HANDOFF",
                    "Phone accepted lights for \(payload.triggerID.uuidString), but watch fallback had already started",
                    level: .warning
                )
                return
            }

            deferredLightRampTask?.cancel()
            deferredLightRampTask = nil
            deferredLocalRampStatus = "Cancelled by phone handoff"
            log("HANDOFF", "Phone accepted light ownership for \(payload.triggerID.uuidString)")
            queueActiveLogTransfer()
            return
        }

        deferredLightRampTask?.cancel()
        deferredLightRampTask = nil
        log(
            "HANDOFF",
            "Phone declined light ownership for \(payload.triggerID.uuidString). reason=\(payload.reason ?? "unspecified")",
            level: .warning
        )

        guard activeLocalRampTriggerID == nil,
              let schedule = activeTriggerSchedule,
              let fallbackMode = activeTriggerFallbackMode else {
            return
        }

        deferredLocalRampStatus = "Starting immediately after phone decline"
        _ = startLocalLightFallback(
            for: schedule,
            triggerID: payload.triggerID,
            reason: "phone declined",
            mode: fallbackMode
        )
    }

    // MARK: - Workout Session

    private func startWorkoutSession() async throws {
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown

        let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: config
        )

        session.delegate = self
        builder.delegate = self

        workoutSession = session
        workoutBuilder = builder

        session.startActivity(with: Date())
        try await builder.beginCollection(at: Date())
        log("HEALTHKIT", "Workout session started and live collection began")
    }

    private func endWorkoutSession() async {
        workoutSession?.end()
        if let builder = workoutBuilder {
            try? await builder.endCollection(at: Date())
            _ = try? await builder.finishWorkout()
        }
        workoutSession = nil
        workoutBuilder = nil
        log("HEALTHKIT", "Workout session ended")
    }

    // MARK: - Heart Rate Query

    private func startHistoricalSeed(from startDate: Date, to endDate: Date) {
        historicalSeedTask?.cancel()
        log(
            "HEALTHKIT",
            "Starting historical heart-rate seed from \(formatTimestamp(startDate)) to \(formatTimestamp(endDate))"
        )
        historicalSeedTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.seedHistoricalHeartRateSamples(from: startDate, to: endDate)
            } catch is CancellationError {
                await MainActor.run {
                    self.log("HEALTHKIT", "Historical heart-rate seed cancelled", level: .warning)
                }
                return
            } catch {
                await MainActor.run {
                    self.log(
                        "HEALTHKIT",
                        "Historical heart-rate seed failed: \(error.localizedDescription)",
                        level: .error
                    )
                }
            }

            await MainActor.run {
                self.historicalSeedTask = nil
            }
        }
    }

    private func seedHistoricalHeartRateSamples(from startDate: Date, to endDate: Date) async throws {
        let samples = try await fetchHistoricalHeartRateSamples(from: startDate, to: endDate)
        guard isMonitoringActive else { return }

        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let mappedSamples = samples.map { sample in
            (date: sample.startDate, bpm: sample.quantity.doubleValue(for: bpmUnit))
        }
        if let firstSample = mappedSamples.first, let lastSample = mappedSamples.last {
            log(
                "HEALTHKIT",
                "Historical seed loaded \(mappedSamples.count) sample(s) spanning \(formatTimestamp(firstSample.date)) -> \(formatTimestamp(lastSample.date))"
            )
        } else {
            log("HEALTHKIT", "Historical seed returned no samples", level: .warning)
        }
        heuristicEngine.seedHeartRateSamples(mappedSamples, referenceDate: endDate)
        checkForWakeTrigger()
    }

    private func fetchHistoricalHeartRateSamples(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.heartRate),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let quantitySamples = (samples as? [HKQuantitySample]) ?? []
                    continuation.resume(returning: quantitySamples)
                }
            }

            healthStore.execute(query)
        }
    }

    private func startHeartRateQuery(from startDate: Date) {
        let heartRateType = HKQuantityType(.heartRate)
        log("HEALTHKIT", "Starting anchored heart-rate query from \(formatTimestamp(startDate))")

        let query = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: HKQuery.predicateForSamples(withStart: startDate, end: nil),
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, _, _ in
            self?.processHeartRateSamples(samples)
        }

        query.updateHandler = { [weak self] _, samples, _, _, _ in
            self?.processHeartRateSamples(samples)
        }

        healthStore.execute(query)
        heartRateQuery = query
    }

    nonisolated private func processHeartRateSamples(_ samples: [HKSample]?) {
        guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else { return }

        Task { @MainActor in
            let bpmUnit = HKUnit.count().unitDivided(by: .minute())

            for sample in samples {
                let bpm = sample.quantity.doubleValue(for: bpmUnit)
                self.log(
                    "HEALTHKIT",
                    "Live heart-rate sample \(self.formatBPM(bpm)) BPM at \(self.formatTimestamp(sample.startDate))"
                )
                self.heuristicEngine.addHeartRateSample(bpm: bpm, date: sample.startDate)
            }

            self.checkForWakeTrigger()
        }
    }

    // MARK: - Wake Check

    private func startWakeCheckTimer() {
        log("SESSION", "Starting wake-check timer with 10 second cadence")
        wakeCheckTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForWakeTrigger()
            }
        }
    }

    private func checkForWakeTrigger() {
        guard isMonitoringActive,
              let wakeUpTime,
              let windowStartTime,
              let schedule = currentSchedule else { return }

        let now = Date()

        if now >= windowStartTime && !didLogWakeWindowStart {
            didLogWakeWindowStart = true
            log(
                "WAKE_WINDOW",
                "Wake window started for '\(schedule.name)' at \(formatTimestamp(now)). wake=\(formatTimestamp(wakeUpTime))"
            )
        }

        if now >= wakeUpTime {
            if !heuristicEngine.hasTriggered {
                log(
                    "WAKE_WINDOW",
                    "Reached exact wake time \(formatTimestamp(now)) without an early trigger. Forcing trigger."
                )
                fireTrigger(
                    schedule: schedule,
                    confidence: 1.0,
                    fallbackMode: .exactWakeFinalState
                )
            } else {
                log(
                    "WAKE_WINDOW",
                    "Exact wake time reached after a prior trigger. Cleaning up monitoring."
                )
                finishMonitoringAfterTrigger()
            }
            return
        }

        if heuristicEngine.shouldTrigger(inWakeWindow: now >= windowStartTime, now: now) {
            fireTrigger(
                schedule: schedule,
                confidence: heuristicEngine.currentConfidence,
                fallbackMode: .earlyRamp
            )
        }
    }

    private func fireTrigger(
        schedule: WatchScheduleSnapshot,
        confidence: Double,
        fallbackMode: WatchFallbackMode
    ) {
        let triggerDate = Date()
        let triggerID = UUID()

        heuristicEngine.markTriggered(at: triggerDate)
        activeTriggerID = triggerID
        activeTriggerSchedule = schedule
        activeTriggerDate = triggerDate
        activeTriggerWakeUpTime = wakeUpTime
        activeTriggerFallbackMode = fallbackMode
        didReceivePhoneHandoffAck = false
        handoffAckStatus = "Waiting for phone handoff"
        deferredLocalRampStatus = fallbackMode == .earlyRamp
            ? "Deferred watch ramp armed for +8s"
            : "Deferred watch final-state write armed for +8s"

        sessionState = .triggered
        notifyStateChange()

        startHapticRamp()
        scheduleDeferredLocalLightFallback(
            for: schedule,
            triggerID: triggerID,
            mode: fallbackMode
        )

        let payload = SmartWakeTriggerPayload(
            triggerID: triggerID,
            scheduleID: schedule.id,
            triggerDate: triggerDate,
            confidence: confidence,
            heartRateAtTrigger: heuristicEngine.latestHeartRate,
            motionLevel: nil
        )

        onTrigger?(payload)
        finishMonitoringAfterTrigger()

        log(
            "TRIGGER",
            "Trigger fired id=\(triggerID.uuidString) mode=\(describeFallbackMode(fallbackMode)) confidence=\(String(format: "%.3f", confidence)) latestHR=\(formatBPM(heuristicEngine.latestHeartRate))"
        )
    }

    private func notifyStateChange() {
        let state = SmartWakeSessionState(
            state: sessionState,
            scheduleID: currentScheduleID,
            message: errorMessage
        )
        onStateChange?(state)
    }

    // MARK: - Test Haptics

    func startTestHaptics(pattern: HapticPattern) {
        #if os(watchOS)
        stopHaptics()
        hapticPatternType = pattern
        log("HAPTICS", "Starting manual test haptics with pattern=\(pattern.displayName)")
        startHapticRamp()
        #endif
    }

    @discardableResult
    func startTestLights(for schedule: WatchScheduleSnapshot) -> Bool {
        log("LIGHTS", "Starting manual watch light test for '\(schedule.name)'")
        return startLocalLightFallback(
            for: schedule,
            triggerID: nil,
            reason: "manual test",
            mode: .earlyRamp
        )
    }

    // MARK: - HomeKit Lights

    private func scheduleDeferredLocalLightFallback(
        for schedule: WatchScheduleSnapshot,
        triggerID: UUID,
        mode: WatchFallbackMode
    ) {
        deferredLightRampTask?.cancel()
        log(
            "LIGHTS",
            "Armed deferred watch fallback for trigger \(triggerID.uuidString) mode=\(describeFallbackMode(mode)) delay=\(Int(watchLightHandoffDelay))s"
        )
        deferredLightRampTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.watchLightHandoffDelay ?? 8))

            await MainActor.run {
                guard let self,
                      self.activeTriggerID == triggerID,
                      self.activeLocalRampTriggerID == nil else { return }

                self.deferredLocalRampStatus = mode == .earlyRamp
                    ? "Watch ramp started after 8s timeout"
                    : "Watch final-state write started after 8s timeout"
                self.log(
                    "LIGHTS",
                    "Deferred watch fallback timed out waiting for phone handoff. Starting \(self.describeFallbackMode(mode)).",
                    level: .warning
                )
                _ = self.startLocalLightFallback(
                    for: schedule,
                    triggerID: triggerID,
                    reason: "handoff timeout",
                    mode: mode
                )
                self.deferredLightRampTask = nil
            }
        }
    }

    @discardableResult
    private func startLocalLightFallback(
        for schedule: WatchScheduleSnapshot,
        triggerID: UUID?,
        reason: String,
        mode: WatchFallbackMode
    ) -> Bool {
        let identifiers = schedule.lightIdentifiers.compactMap(UUID.init(uuidString:))
        guard !identifiers.isEmpty else {
            deferredLocalRampStatus = "No light identifiers for watch fallback"
            log(
                "LIGHTS",
                "Cannot start watch fallback for '\(schedule.name)': no light identifiers were synced",
                level: .error
            )
            return false
        }

        let rampPlan = makeWatchLightRampPlan(for: schedule)
        if mode == .earlyRamp, rampPlan.firstVisibleStep == nil {
            deferredLocalRampStatus = "No visible watch fallback step"
            log(
                "LIGHTS",
                "Cannot start watch fallback for '\(schedule.name)': no visible step exists in the ramp plan",
                level: .error
            )
            return false
        }

        log(
            "LIGHTS",
            "Starting local watch fallback for '\(schedule.name)' reason=\(reason) mode=\(describeFallbackMode(mode)) identifiers=\(identifiers.count) stepCount=\(rampPlan.stepCount) firstVisibleStep=\(rampPlan.firstVisibleStep.map(String.init) ?? "nil") skipColor=\(schedule.skipColorWrites)"
        )
        activeLocalRampTriggerID = triggerID
        deferredLightRampTask?.cancel()
        deferredLightRampTask = nil
        lightRampTask?.cancel()
        lightRampTask = Task { [weak self] in
            await self?.runLocalLightFallback(
                for: schedule,
                identifiers: identifiers,
                reason: reason,
                mode: mode,
                rampPlan: rampPlan
            )
        }
        return true
    }

    private func runLocalLightFallback(
        for schedule: WatchScheduleSnapshot,
        identifiers: [UUID],
        reason: String,
        mode: WatchFallbackMode,
        rampPlan: WatchLightRampPlan
    ) async {
        log(
            "HOMEKIT",
            "Waiting for HomeKit readiness before \(describeFallbackMode(mode)) fallback"
        )
        await homeKitService.waitForReady()
        log("HOMEKIT", "HomeKit readiness wait completed")

        switch mode {
        case .earlyRamp:
            await runEarlyLocalLightRamp(
                for: schedule,
                identifiers: identifiers,
                reason: reason,
                rampPlan: rampPlan
            )
        case .exactWakeFinalState:
            await applyExactWakeFinalLightState(
                for: schedule,
                identifiers: identifiers,
                reason: reason
            )
        }
    }

    private func runEarlyLocalLightRamp(
        for schedule: WatchScheduleSnapshot,
        identifiers: [UUID],
        reason: String,
        rampPlan: WatchLightRampPlan
    ) async {
        deferredLocalRampStatus = "Watch ramp running (\(reason))"
        log(
            "LIGHTS",
            "Starting watch HomeKit ramp for '\(schedule.name)' reason=\(reason) rampDuration=\(Int(rampPlan.rampDuration))s stepInterval=\(Int(rampPlan.stepInterval))s stepCount=\(rampPlan.stepCount)"
        )

        guard let firstVisibleStep = rampPlan.firstVisibleStep else {
            deferredLocalRampStatus = "No visible watch fallback step"
            log(
                "LIGHTS",
                "Aborting watch HomeKit ramp because no visible step exists",
                level: .error
            )
            return
        }

        let initialState = watchLightState(
            for: schedule,
            step: firstVisibleStep,
            stepCount: rampPlan.stepCount
        )
        let initialWrite = await lightController.applyBestEffortToMultipleLights(
            brightness: initialState.brightness,
            hue: initialState.hue,
            saturation: initialState.saturation,
            powerOn: true,
            skipColor: schedule.skipColorWrites,
            identifiers: identifiers,
            names: schedule.lightNames
        )
        log(
            "LIGHTS",
            "Initial visible step \(firstVisibleStep)/\(rampPlan.stepCount) brightness=\(initialState.brightness) hue=\(String(format: "%.1f", initialState.hue)) saturation=\(String(format: "%.1f", initialState.saturation)) -> \(describeWriteSummary(initialWrite))"
        )
        guard initialWrite.hadAnySuccess else {
            deferredLocalRampStatus = "Watch ramp could not claim any lights"
            log(
                "LIGHTS",
                "Watch fallback could not claim any selected lights on the initial visible step",
                level: .error
            )
            queueActiveLogTransfer()
            return
        }

        if firstVisibleStep < rampPlan.stepCount {
            for step in (firstVisibleStep + 1)...rampPlan.stepCount {
                if Task.isCancelled { return }

                let state = watchLightState(
                    for: schedule,
                    step: step,
                    stepCount: rampPlan.stepCount
                )
                let stepWrite = await lightController.applyBestEffortToMultipleLights(
                    brightness: state.brightness,
                    hue: state.hue,
                    saturation: state.saturation,
                    powerOn: true,
                    skipColor: schedule.skipColorWrites,
                    identifiers: identifiers,
                    names: schedule.lightNames
                )
                log(
                    "LIGHTS",
                    "Ramp step \(step)/\(rampPlan.stepCount) brightness=\(state.brightness) hue=\(String(format: "%.1f", state.hue)) saturation=\(String(format: "%.1f", state.saturation)) -> \(describeWriteSummary(stepWrite))",
                    level: stepWrite.hadAnySuccess ? .info : .warning
                )

                if step < rampPlan.stepCount {
                    try? await Task.sleep(for: .seconds(rampPlan.stepInterval))
                }
            }
        }

        let finalWrite = await lightController.applyBestEffortToMultipleLights(
            brightness: schedule.targetBrightness,
            hue: schedule.endColorHue * 360.0,
            saturation: schedule.endColorSaturation * 100.0,
            powerOn: true,
            skipColor: schedule.skipColorWrites,
            identifiers: identifiers,
            names: schedule.lightNames
        )
        if finalWrite.hadAnySuccess {
            deferredLocalRampStatus = "Watch ramp completed (\(reason))"
            log(
                "LIGHTS",
                "Watch ramp completed with final write -> \(describeWriteSummary(finalWrite))"
            )
        } else {
            deferredLocalRampStatus = "Watch ramp finished without reaching lights"
            log(
                "LIGHTS",
                "Watch ramp finished, but the final write failed for every selected light -> \(describeWriteSummary(finalWrite))",
                level: .error
            )
        }
        queueActiveLogTransfer()
    }

    private func applyExactWakeFinalLightState(
        for schedule: WatchScheduleSnapshot,
        identifiers: [UUID],
        reason: String
    ) async {
        deferredLocalRampStatus = "Applying watch final light state (\(reason))"
        log(
            "LIGHTS",
            "Applying watch final light state for '\(schedule.name)' reason=\(reason) brightness=\(schedule.targetBrightness) hue=\(String(format: "%.1f", schedule.endColorHue * 360.0)) saturation=\(String(format: "%.1f", schedule.endColorSaturation * 100.0))"
        )

        let finalWrite = await lightController.applyBestEffortToMultipleLights(
            brightness: schedule.targetBrightness,
            hue: schedule.endColorHue * 360.0,
            saturation: schedule.endColorSaturation * 100.0,
            powerOn: true,
            skipColor: schedule.skipColorWrites,
            identifiers: identifiers,
            names: schedule.lightNames
        )
        if finalWrite.hadAnySuccess {
            deferredLocalRampStatus = "Watch final light state applied (\(reason))"
            log(
                "LIGHTS",
                "Watch final light state applied -> \(describeWriteSummary(finalWrite))"
            )
        } else {
            deferredLocalRampStatus = "Watch final light state failed"
            log(
                "LIGHTS",
                "Watch final light state failed for every selected light -> \(describeWriteSummary(finalWrite))",
                level: .error
            )
        }
        queueActiveLogTransfer()
    }

    private func makeWatchLightRampPlan(for schedule: WatchScheduleSnapshot) -> WatchLightRampPlan {
        let rampDuration: TimeInterval = 60
        let stepInterval: TimeInterval = 5
        let stepCount = max(Int(rampDuration / stepInterval), 1)
        let firstVisibleStep = (0...stepCount).first(where: { step in
            let progress = min(Double(step) / Double(stepCount), 1.0)
            return watchInterpolateBrightness(target: schedule.targetBrightness, progress: progress) > 0
        })

        return WatchLightRampPlan(
            rampDuration: rampDuration,
            stepInterval: stepInterval,
            stepCount: stepCount,
            firstVisibleStep: firstVisibleStep
        )
    }

    private func watchLightState(
        for schedule: WatchScheduleSnapshot,
        step: Int,
        stepCount: Int
    ) -> WatchLightState {
        let progress = min(Double(step) / Double(stepCount), 1.0)
        let brightness = watchInterpolateBrightness(
            target: schedule.targetBrightness,
            progress: progress
        )
        let hsb = watchInterpolateHSB(
            startHue: schedule.startColorHue,
            startSat: schedule.startColorSaturation,
            startBri: schedule.startColorBrightness,
            endHue: schedule.endColorHue,
            endSat: schedule.endColorSaturation,
            endBri: schedule.endColorBrightness,
            progress: progress
        )

        return WatchLightState(
            brightness: brightness,
            hue: hsb.hue * 360.0,
            saturation: hsb.saturation * 100.0
        )
    }

    // MARK: - Haptic Alarm (WKInterfaceDevice)

    private func startHapticRamp() {
        #if os(watchOS)
        stopHaptics()
        hapticStartTime = Date()
        lastHapticPlayTime = nil
        heartbeatPendingSecondBeat = false

        playHapticForPattern(hapticPatternType, isSecondBeat: false)
        lastHapticPlayTime = Date()

        hapticTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hapticTimerTick()
            }
        }

        log(
            "HAPTICS",
            "Haptic ramp started with pattern=\(hapticPatternType.displayName) duration=\(Int(hapticDuration))s"
        )
        #endif
    }

    private func stopHaptics() {
        hapticTimer?.invalidate()
        hapticTimer = nil
        hapticStartTime = nil
        lastHapticPlayTime = nil
        heartbeatPendingSecondBeat = false
        log("HAPTICS", "Haptic playback stopped")
    }

    #if os(watchOS)
    private func hapticTimerTick() {
        guard let startTime = hapticStartTime else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed >= hapticDuration {
            WKInterfaceDevice.current().play(.notification)
            stopHaptics()
            log("HAPTICS", "Haptic ramp reached completion and played final notification")
            return
        }

        let progress = elapsed / hapticDuration
        let interval = nextInterval(for: hapticPatternType, progress: progress)
        let timeSinceLastPlay = lastHapticPlayTime.map { Date().timeIntervalSince($0) } ?? .infinity

        if hapticPatternType == .heartbeat && heartbeatPendingSecondBeat && timeSinceLastPlay >= 0.3 {
            WKInterfaceDevice.current().play(.click)
            heartbeatPendingSecondBeat = false
            lastHapticPlayTime = Date()
            return
        }

        guard timeSinceLastPlay >= interval else { return }

        playHapticForPattern(hapticPatternType, isSecondBeat: false)
        lastHapticPlayTime = Date()

        if hapticPatternType == .heartbeat {
            heartbeatPendingSecondBeat = true
        }
    }

    private func playHapticForPattern(_ pattern: HapticPattern, isSecondBeat: Bool) {
        let device = WKInterfaceDevice.current()

        switch pattern {
        case .gentle:
            device.play(.click)
        case .pulse:
            device.play(.start)
        case .heartbeat:
            device.play(isSecondBeat ? .click : .directionUp)
        case .alarm:
            device.play(.notification)
        }
    }

    private func nextInterval(for pattern: HapticPattern, progress: Double) -> TimeInterval {
        switch pattern {
        case .gentle:
            return 5.0 - 3.5 * progress
        case .pulse:
            return 3.0 - 2.0 * progress
        case .heartbeat:
            return 4.0 - 2.5 * progress
        case .alarm:
            return 2.0 - 1.3 * progress
        }
    }
    #endif
}

// MARK: - HKWorkoutSessionDelegate

extension SmartWakeSessionController: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            self.log(
                "HEALTHKIT",
                "Workout session state changed from \(fromState.rawValue) to \(toState.rawValue) at \(self.formatTimestamp(date))"
            )
            if toState == .ended, self.isMonitoringActive {
                self.failMonitoring("Workout session ended unexpectedly")
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.log(
                "HEALTHKIT",
                "Workout session delegate reported failure: \(error.localizedDescription)",
                level: .error
            )
            self.failMonitoring(error.localizedDescription)
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension SmartWakeSessionController: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        // Heart rate data is handled by the anchored query.
    }
}

// MARK: - Watch HomeKit

private final class WatchHomeKitService: NSObject, HMHomeManagerDelegate {
    private let homeManager: HMHomeManager

    private(set) var homes: [HMHome] = []
    private(set) var availableLights: [HMAccessory] = []
    var logHandler: ((SmartWakeLogLevel, String) -> Void)?

    override init() {
        homeManager = HMHomeManager()
        super.init()
        homeManager.delegate = self
    }

    func waitForReady(timeout: TimeInterval = 10) async {
        if !homes.isEmpty { return }

        let deadline = Date().addingTimeInterval(timeout)
        log("Waiting for HomeKit homes/accessories to become ready. timeout=\(Int(timeout))s")
        while homes.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if homes.isEmpty {
            log("HomeKit readiness wait timed out with no homes available", level: .warning)
        }
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        MainActor.assumeIsolated {
            homes = manager.homes
            availableLights = homes.flatMap { home in
                home.accessories.filter { accessory in
                    accessory.services.contains { $0.serviceType == HMServiceTypeLightbulb }
                }
            }
            self.log(
                "HomeKit updated. homes=\(self.homes.count) visibleLights=\(self.availableLights.count)"
            )
        }
    }

    func setBrightness(_ value: Int, for accessoryID: UUID, named accessoryName: String? = nil) async throws {
        try await writeValue(
            value,
            for: findCharacteristic(
                type: HMCharacteristicTypeBrightness,
                for: accessoryID,
                named: accessoryName
            )
        )
    }

    func setHue(_ value: Double, for accessoryID: UUID, named accessoryName: String? = nil) async throws {
        try await writeValue(
            value,
            for: findCharacteristic(
                type: HMCharacteristicTypeHue,
                for: accessoryID,
                named: accessoryName
            )
        )
    }

    func setSaturation(_ value: Double, for accessoryID: UUID, named accessoryName: String? = nil) async throws {
        try await writeValue(
            value,
            for: findCharacteristic(
                type: HMCharacteristicTypeSaturation,
                for: accessoryID,
                named: accessoryName
            )
        )
    }

    func setPowerState(_ on: Bool, for accessoryID: UUID, named accessoryName: String? = nil) async throws {
        try await writeValue(
            on,
            for: findCharacteristic(
                type: HMCharacteristicTypePowerState,
                for: accessoryID,
                named: accessoryName
            )
        )
    }

    private func findCharacteristic(
        type: String,
        for accessoryID: UUID,
        named accessoryName: String?
    ) throws -> HMCharacteristic {
        let accessory = availableLights.first(where: { $0.uniqueIdentifier == accessoryID })
            ?? availableLights.first(where: { accessory in
                guard let accessoryName else { return false }
                return accessory.name == accessoryName
            })

        guard let accessory else {
            let available = availableLights.map {
                "\($0.name) [\($0.uniqueIdentifier.uuidString)]"
            }.joined(separator: ", ")
            log(
                "No accessory match for id=\(accessoryID.uuidString) name=\(accessoryName ?? "<nil>"). available=\(available)",
                level: .error
            )
            throw WatchHomeKitServiceError.accessoryNotFound
        }

        guard let service = accessory.services.first(where: { $0.serviceType == HMServiceTypeLightbulb }) else {
            throw WatchHomeKitServiceError.serviceNotFound
        }

        guard let characteristic = service.characteristics.first(where: {
            $0.characteristicType == type
        }) else {
            throw WatchHomeKitServiceError.characteristicNotFound
        }

        return characteristic
    }

    private func writeValue(_ value: Any, for characteristic: HMCharacteristic) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(value) { error in
                if let error {
                    self.log(
                        "Characteristic write failed for \(characteristic.characteristicType): \(error.localizedDescription)",
                        level: .error
                    )
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func log(_ message: String, level: SmartWakeLogLevel = .info) {
        logHandler?(level, message)
    }
}

private enum WatchHomeKitServiceError: LocalizedError {
    case accessoryNotFound
    case serviceNotFound
    case characteristicNotFound

    var errorDescription: String? {
        switch self {
        case .accessoryNotFound: "Light accessory not found"
        case .serviceNotFound: "Lightbulb service not found"
        case .characteristicNotFound: "Characteristic not found on light"
        }
    }
}

private struct WatchLightWriteResult {
    let accessoryID: UUID
    let accessoryName: String?
    let succeeded: Bool
    let errorDescription: String?
}

private struct WatchMultiLightWriteSummary {
    let results: [WatchLightWriteResult]

    var attempted: Int { results.count }
    var succeeded: Int { results.filter(\.succeeded).count }
    var failed: Int { attempted - succeeded }
    var hadAnySuccess: Bool { succeeded > 0 }
}

private final class WatchLightController {
    private let homeKitService: WatchHomeKitService
    var logHandler: ((SmartWakeLogLevel, String) -> Void)?

    init(homeKitService: WatchHomeKitService) {
        self.homeKitService = homeKitService
    }

    func applyToMultipleLights(
        brightness: Int,
        hue: Double,
        saturation: Double,
        powerOn: Bool,
        skipColor: Bool,
        identifiers: [UUID],
        names: [String]
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, id) in identifiers.enumerated() {
                let accessoryName = names.indices.contains(index) ? names[index] : nil
                group.addTask {
                    try await self.applyLightState(
                        brightness: brightness,
                        hue: hue,
                        saturation: saturation,
                        powerOn: powerOn,
                        skipColor: skipColor,
                        to: id,
                        named: accessoryName
                    )
                }
            }
            try await group.waitForAll()
        }
    }

    func applyBestEffortToMultipleLights(
        brightness: Int,
        hue: Double,
        saturation: Double,
        powerOn: Bool,
        skipColor: Bool,
        identifiers: [UUID],
        names: [String]
    ) async -> WatchMultiLightWriteSummary {
        await withTaskGroup(of: WatchLightWriteResult.self) { group in
            for (index, id) in identifiers.enumerated() {
                let accessoryName = names.indices.contains(index) ? names[index] : nil
                group.addTask {
                    do {
                        try await self.applyLightState(
                            brightness: brightness,
                            hue: hue,
                            saturation: saturation,
                            powerOn: powerOn,
                            skipColor: skipColor,
                            to: id,
                            named: accessoryName
                        )
                        return WatchLightWriteResult(
                            accessoryID: id,
                            accessoryName: accessoryName,
                            succeeded: true,
                            errorDescription: nil
                        )
                    } catch {
                        await MainActor.run {
                            self.log(
                                "Failed to apply light state to \(accessoryName ?? id.uuidString): \(error.localizedDescription)",
                                level: .error
                            )
                        }
                        return WatchLightWriteResult(
                            accessoryID: id,
                            accessoryName: accessoryName,
                            succeeded: false,
                            errorDescription: error.localizedDescription
                        )
                    }
                }
            }

            var results: [WatchLightWriteResult] = []
            for await result in group {
                results.append(result)
            }

            return WatchMultiLightWriteSummary(results: results)
        }
    }

    private func applyLightState(
        brightness: Int,
        hue: Double,
        saturation: Double,
        powerOn: Bool,
        skipColor: Bool,
        to accessoryID: UUID,
        named accessoryName: String?
    ) async throws {
        guard powerOn else {
            try await homeKitService.setPowerState(false, for: accessoryID, named: accessoryName)
            return
        }

        if brightness <= 0 {
            try? await homeKitService.setBrightness(0, for: accessoryID, named: accessoryName)
            try await homeKitService.setPowerState(false, for: accessoryID, named: accessoryName)
            return
        }

        try? await homeKitService.setBrightness(brightness, for: accessoryID, named: accessoryName)

        if !skipColor {
            do {
                try await homeKitService.setHue(hue, for: accessoryID, named: accessoryName)
                try await homeKitService.setSaturation(
                    saturation,
                    for: accessoryID,
                    named: accessoryName
                )
            } catch WatchHomeKitServiceError.characteristicNotFound {
                // White-only bulbs do not expose hue/saturation.
            }
        }

        try await homeKitService.setPowerState(true, for: accessoryID, named: accessoryName)
        try await homeKitService.setBrightness(brightness, for: accessoryID, named: accessoryName)
    }

    private func log(_ message: String, level: SmartWakeLogLevel = .info) {
        logHandler?(level, message)
    }
}

private func watchInterpolateHSB(
    startHue: Double,
    startSat: Double,
    startBri: Double,
    endHue: Double,
    endSat: Double,
    endBri: Double,
    progress: Double
) -> (hue: Double, saturation: Double, brightness: Double) {
    let t = min(max(progress, 0), 1)

    var deltaHue = endHue - startHue
    if deltaHue > 0.5 {
        deltaHue -= 1.0
    } else if deltaHue < -0.5 {
        deltaHue += 1.0
    }

    var hue = startHue + deltaHue * t
    if hue < 0 { hue += 1.0 }
    if hue > 1 { hue -= 1.0 }

    let saturation = startSat + (endSat - startSat) * t
    let brightness = startBri + (endBri - startBri) * t

    return (hue: hue, saturation: saturation, brightness: brightness)
}

private func watchInterpolateBrightness(target: Int, progress: Double) -> Int {
    let t = min(max(progress, 0), 1)
    return Int(Double(target) * t)
}
