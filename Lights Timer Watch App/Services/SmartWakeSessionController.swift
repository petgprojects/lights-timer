import Foundation
import CoreMotion
import HealthKit
import HomeKit
#if os(watchOS)
import WatchKit
#endif

#if os(watchOS)
private struct WatchHapticBeat {
    let delay: TimeInterval
    let type: WKHapticType
}
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
    private(set) var hasConfirmedHRAccess: Bool = false
    private(set) var lastHRSampleDate: Date?
    private(set) var passiveObservationStatus = "Inactive"
    private(set) var lastPassiveHeartRateSampleDescription = "No background sample yet"
    private(set) var heuristicSnapshot = SmartWakeHeuristicSnapshot.empty
    private(set) var lastLiveMotionSampleDescription = "No live motion yet"
    private(set) var lastRecorderBackfillDescription = "No recorder backfill yet"
    private(set) var lastOccurrenceSummaryStatus = "No occurrence summary yet"
    private(set) var motionStatus = "Motion idle"
    private(set) var recorderStatus = "Recorder idle"
    private(set) var isMonitoringActive = false
    private(set) var isMonitoringStartupInProgress = false
    private(set) var isWorkoutSessionRunning = false
    private(set) var isProactiveWorkoutRunning = false
    private(set) var isDegradedMode = false

    private(set) var nextScheduledWakeWindowDescription: String?
    private(set) var didReceivePhoneHandoffAck = false
    private(set) var handoffAckStatus = "No recent trigger"
    private(set) var deferredLocalRampStatus = "Idle"
    #if DEBUG
    private(set) var isNoBuilderValidationActive = false
    private(set) var noBuilderValidationStatus = "Idle"
    private(set) var noBuilderValidationSampleCount = 0
    private(set) var noBuilderValidationLastSampleDescription = "No samples yet"
    private(set) var noBuilderValidationSeedProbeStatus = "Not run"
    private var noBuilderValidationStartedAt: Date?
    private var noBuilderValidationLastSampleAt: Date?
    #endif

    /// Set by SmartAlarmScheduler to indicate the extended runtime session is active.
    var isAlarmSessionActive: Bool = false

    /// Set by SmartAlarmScheduler before monitoring starts.
    var hapticPatternType: HapticPattern = .gentle

    private let homeKitService: WatchHomeKitService
    private let lightController: WatchLightController
    private let motionManager = CMMotionManager()
    private let sensorRecorder = CMSensorRecorder()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "LightsTimer.SmartWakeMotionQueue"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var heartRateQuery: HKAnchoredObjectQuery?
    private var passiveHeartRateObserverQuery: HKObserverQuery?
    private var exactWakeTimer: Timer?
    private var windowStartTimer: Timer?
    private var recorderRefreshTimer: Timer?
    private var recorderBackfillTask: Task<Void, Never>?
    private var lightRampTask: Task<Void, Never>?
    private var deferredLightRampTask: Task<Void, Never>?
    private var workoutRecoveryRetryTask: Task<Void, Never>?
    private var workoutRecoveryRetryAttempts = 0
    private var didLogWorkoutRecoveryRetryExhaustion = false

    private(set) var currentSchedule: WatchScheduleSnapshot?
    private var wakeUpTime: Date?
    private var windowStartTime: Date?
    private var activeTriggerID: UUID?
    private var activeTriggerSchedule: WatchScheduleSnapshot?
    private var activeTriggerDate: Date?
    private var activeTriggerWakeUpTime: Date?
    private var activeTriggerFallbackMode: WatchFallbackMode?
    private var activeTriggerConfidence: Double?
    private var activeTriggerMotionScore: Double?
    private var activeTriggerSensorProvenance: SmartWakeSensorProvenance?
    private var activeLocalRampTriggerID: UUID?
    private var didLogWakeWindowStart = false
    private var armedAt: Date?
    private var currentCalibrationProfile: SmartWakeCalibrationProfile = SmartWakeSharedStore.loadCalibrationProfile()
    private var preparedWakeSignature: String?
    private var didArmRecorderForPreparedWake = false

    // Haptic alarm
    private var hapticTimer: Timer?
    private var hapticStartTime: Date?
    private var lastHapticPlayTime: Date?
    #if os(watchOS)
    private var pendingFollowUpBeats: [WatchHapticBeat] = []
    #endif
    private let hapticDuration: TimeInterval = 60
    private let hapticTimerResolution: TimeInterval = 0.1
    private let recorderLookback: TimeInterval = 7200
    private let recorderLagAllowance: TimeInterval = 180
    private let recorderRefreshInterval: TimeInterval = 60
    private let recorderMaxDuration: TimeInterval = 12 * 60 * 60
    private let watchLightHandoffDelay: TimeInterval = 8
    private let workoutRecoveryRetryDelay: TimeInterval = 8
    private let workoutRecoveryRetryValidationDelay: TimeInterval = 3
    private let maxWorkoutRecoveryRetryAttempts = 2
    private var seenSampleUUIDs = Set<UUID>()
    private var isPassiveObservationEnabled = false

    var onTrigger: ((SmartWakeTriggerPayload) -> Void)?
    var onStateChange: ((SmartWakeSessionState) -> Void)?
    var onPostTriggerWorkComplete: (() -> Void)?
    /// Fires when monitoring ends without a trigger (manual stop or failure).
    /// The scheduler uses this to tear down its extended runtime session and clear stale state.
    var onMonitoringCancelled: (() -> Void)?
    var onHRAccessConfirmed: (() -> Void)?
    var onLogReadyToTransfer: ((URL) -> Void)?
    var onAuthorizationChanged: (() -> Void)?
    var onPresentationStateChanged: (() -> Void)?
    var onOccurrenceSummaryReady: ((SmartWakeOccurrenceSummary) -> Void)?

    init(logStore: SmartWakeLogStore) {
        self.logStore = logStore
        let homeKitService = WatchHomeKitService()
        self.homeKitService = homeKitService
        self.lightController = WatchLightController(homeKitService: homeKitService)
        super.init()

        homeKitService.logHandler = { [weak self] level, message in
            self?.log("HOMEKIT", message, level: level)
        }
        lightController.logHandler = { [weak self] level, message in
            self?.log("LIGHTS", message, level: level)
        }

        motionManager.deviceMotionUpdateInterval = 0.1
    }

    private func log(_ category: String, _ message: String, level: SmartWakeLogLevel = .info) {
        logStore.log(category, message, level: level)
    }

    private func queueActiveLogTransfer() {
        logStore.refreshAvailableLogsIfNeeded()
        if let runtimeLogURL = logStore.runtimeLogFile?.url {
            onLogReadyToTransfer?(runtimeLogURL)
        }
        if let logURL = logStore.activeLogFile?.url,
           logURL != logStore.runtimeLogFile?.url {
            onLogReadyToTransfer?(logURL)
        }
    }

    private func updateLastHRSampleDate(with candidate: Date?) {
        guard let candidate else { return }

        if let lastHRSampleDate {
            self.lastHRSampleDate = max(lastHRSampleDate, candidate)
        } else {
            lastHRSampleDate = candidate
        }
    }

    private func formatTimestamp(_ date: Date?) -> String {
        guard let date else { return "--" }
        return Self.timestampFormatter.string(from: date)
    }

    private func formatBPM(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f", value)
    }

    private func formatInterval(_ interval: TimeInterval) -> String {
        String(format: "%.1fs", interval)
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        let minutes = seconds / 60
        let remainder = seconds % 60

        if minutes == 0 {
            return "\(remainder)s"
        }

        return "\(minutes)m \(remainder)s"
    }

    var lastHRSampleStatus: String {
        guard let lastHRSampleDate else { return "--" }
        return "\(formatElapsed(Date().timeIntervalSince(lastHRSampleDate))) ago"
    }

    var lastMotionSampleStatus: String {
        guard let freshness = heuristicSnapshot.motionFreshnessSeconds else { return "--" }
        return "\(formatElapsed(freshness)) ago"
    }

    var heuristicDiagnosticSummary: String {
        heuristicSnapshot.diagnosticSummary
    }

    var motionAuthorizationStatusDescription: String {
        switch CMSensorRecorder.authorizationStatus() {
        case .authorized:
            return "Authorized"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not Determined"
        @unknown default:
            return "Unknown"
        }
    }

    var motionStatusPayload: SmartWakePermissionStatus {
        let authorizationStatus = CMSensorRecorder.authorizationStatus()
        return SmartWakePermissionStatus(
            heartRateDataActive: hasConfirmedHRAccess,
            watchConnected: true,
            motionAvailable: motionManager.isDeviceMotionAvailable,
            motionAuthorized: authorizationStatus == .authorized,
            recorderAvailable: CMSensorRecorder.isAccelerometerRecordingAvailable(),
            recorderAuthorized: authorizationStatus == .authorized
        )
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
        let readTypes: Set<HKObjectType> = [heartRate]
        #if DEBUG
        let writeTypes: Set<HKSampleType> = [HKObjectType.workoutType()]
        #else
        let writeTypes: Set<HKSampleType> = []
        #endif

        do {
            try await healthStore.requestAuthorization(toShare: writeTypes, read: readTypes)
            let status = healthStore.authorizationStatus(for: heartRate)
            isHealthKitAuthorized = status != .notDetermined
            hasConfirmedHRAccess = await probeHeartRateReadAccess()
            log(
                "HEALTHKIT",
                "Authorization complete. promptCompleted=\(isHealthKitAuthorized) hrDataAccessible=\(hasConfirmedHRAccess)"
            )
            onAuthorizationChanged?()
            return isHealthKitAuthorized
        } catch {
            errorMessage = error.localizedDescription
            isHealthKitAuthorized = false
            hasConfirmedHRAccess = false
            log(
                "HEALTHKIT",
                "Authorization request failed: \(error.localizedDescription)",
                level: .error
            )
            onAuthorizationChanged?()
            return false
        }
    }

    private func probeHeartRateReadAccess() async -> Bool {
        let endDate = Date()
        let startDate = endDate.addingTimeInterval(-86400)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let found = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.heartRate),
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    Task { @MainActor [weak self] in
                        self?.log(
                            "HEALTHKIT",
                            "HealthKit heart-rate probe failed: \(error.localizedDescription)",
                            level: .warning
                        )
                    }
                    continuation.resume(returning: false)
                    return
                }

                let found = ((samples as? [HKQuantitySample])?.isEmpty == false)
                continuation.resume(returning: found)
            }

            healthStore.execute(query)
        }

        log("HEALTHKIT", "HealthKit heart-rate probe: found=\(found)")
        return found
    }

    func configurePassiveHeartRateObservation(enabled: Bool, reason: String) {
        Task { @MainActor [weak self] in
            await self?.setPassiveHeartRateObservationEnabled(enabled: enabled, reason: reason)
        }
    }

    private func setPassiveHeartRateObservationEnabled(enabled: Bool, reason: String) async {
        let heartRateType = HKQuantityType(.heartRate)

        if !enabled {
            if let passiveHeartRateObserverQuery {
                healthStore.stop(passiveHeartRateObserverQuery)
                self.passiveHeartRateObserverQuery = nil
            }

            if isPassiveObservationEnabled {
                do {
                    try await healthStore.disableBackgroundDelivery(for: heartRateType)
                } catch {
                    log(
                        "HEALTHKIT",
                        "Failed to disable passive heart-rate background delivery: \(error.localizedDescription)",
                        level: .warning
                    )
                }
            }

            isPassiveObservationEnabled = false
            passiveObservationStatus = reason
            onPresentationStateChanged?()
            return
        }

        guard isHealthKitAuthorized else {
            passiveObservationStatus = reason
            onPresentationStateChanged?()
            return
        }

        if passiveHeartRateObserverQuery == nil {
            let observerQuery = HKObserverQuery(
                sampleType: heartRateType,
                predicate: nil
            ) { [weak self] _, completionHandler, error in
                Task { @MainActor [weak self] in
                    await self?.handlePassiveHeartRateObserverUpdate(
                        error: error,
                        completionHandler: completionHandler
                    )
                }
            }
            passiveHeartRateObserverQuery = observerQuery
            healthStore.execute(observerQuery)
        }

        do {
            try await healthStore.enableBackgroundDelivery(for: heartRateType, frequency: .hourly)
            isPassiveObservationEnabled = true
            passiveObservationStatus = reason
            onPresentationStateChanged?()
        } catch {
            isPassiveObservationEnabled = false
            passiveObservationStatus = "Background delivery failed"
            log(
                "HEALTHKIT",
                "Failed to enable passive heart-rate background delivery: \(error.localizedDescription)",
                level: .error
            )
            onPresentationStateChanged?()
        }
    }

    private func handlePassiveHeartRateObserverUpdate(
        error: Error?,
        completionHandler: @escaping HKObserverQueryCompletionHandler
    ) async {
        guard isPassiveObservationEnabled else {
            completionHandler()
            return
        }

        if let error {
            passiveObservationStatus = "Background delivery error"
            log(
                "HEALTHKIT",
                "Passive heart-rate observer error: \(error.localizedDescription)",
                level: .warning
            )
            onPresentationStateChanged?()
            completionHandler()
            return
        }

        do {
            if let sample = try await fetchLatestHeartRateSample() {
                let bpmUnit = HKUnit.count().unitDivided(by: .minute())
                let bpm = sample.quantity.doubleValue(for: bpmUnit)
                lastPassiveHeartRateSampleDescription = "\(formatBPM(bpm)) BPM at \(formatTimestamp(sample.startDate))"
                passiveObservationStatus = "Hourly background delivery active"

                if !hasConfirmedHRAccess {
                    hasConfirmedHRAccess = true
                    log("HEALTHKIT", "HR access confirmed via passive background delivery")
                    onHRAccessConfirmed?()
                }
                onPresentationStateChanged?()
            }
        } catch {
            passiveObservationStatus = "Background fetch failed"
            log(
                "HEALTHKIT",
                "Passive background heart-rate fetch failed: \(error.localizedDescription)",
                level: .warning
            )
            onPresentationStateChanged?()
        }

        completionHandler()
    }

    private func fetchLatestHeartRateSample() async throws -> HKQuantitySample? {
        try await withCheckedThrowingContinuation { continuation in
            let sampleType = HKQuantityType(.heartRate)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let sample = (samples as? [HKQuantitySample])?.first
                    continuation.resume(returning: sample)
                }
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Scheduling Diagnostics

    func updateNextScheduledWakeWindow(schedule: WatchScheduleSnapshot?, wakeUpTime: Date?) {
        guard let schedule, let wakeUpTime else {
            nextScheduledWakeWindowDescription = nil
            log("SCHEDULER", "Cleared next scheduled wake window")
            onPresentationStateChanged?()
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
        onPresentationStateChanged?()
    }

    // MARK: - Session Lifecycle

    func prepareArmedWake(
        schedule: WatchScheduleSnapshot,
        wakeUpTime: Date,
        windowStart: Date,
        armedAt: Date,
        calibrationProfile: SmartWakeCalibrationProfile
    ) {
        self.armedAt = armedAt
        currentCalibrationProfile = calibrationProfile.clamped()
        let signature = "\(schedule.id.uuidString)-\(wakeUpTime.timeIntervalSince1970)"

        if preparedWakeSignature == signature && didArmRecorderForPreparedWake {
            return
        }
        refreshMotionCapabilityStatus()
        let didArmRecorder = startRecordedMotionCaptureIfPossible(
            schedule: schedule,
            wakeUpTime: wakeUpTime,
            windowStart: windowStart,
            armedAt: armedAt
        )
        preparedWakeSignature = signature
        didArmRecorderForPreparedWake = didArmRecorder
    }

    func startMonitoring(
        schedule: WatchScheduleSnapshot,
        wakeUpTime: Date,
        armedAt: Date?,
        calibrationProfile: SmartWakeCalibrationProfile
    ) async {
        #if DEBUG
        guard !isNoBuilderValidationActive else {
            log(
                "SESSION",
                "Ignoring startMonitoring for '\(schedule.name)' while no-builder validation is active",
                level: .warning
            )
            return
        }
        #endif

        guard !isMonitoringActive, !isMonitoringStartupInProgress else {
            log("SESSION", "Ignoring duplicate startMonitoring for '\(schedule.name)'")
            return
        }

        let windowStartTime = wakeUpTime.addingTimeInterval(
            -Double(schedule.smartWakeWindowMinutes) * 60
        )
        let effectiveArmedAt = armedAt ?? Date()

        prepareArmedWake(
            schedule: schedule,
            wakeUpTime: wakeUpTime,
            windowStart: windowStartTime,
            armedAt: effectiveArmedAt,
            calibrationProfile: calibrationProfile
        )

        errorMessage = nil
        currentSchedule = schedule
        currentScheduleID = schedule.id
        self.wakeUpTime = wakeUpTime
        self.windowStartTime = windowStartTime
        self.armedAt = effectiveArmedAt
        resetWorkoutRecoveryRetryState()
        lastHRSampleDate = nil
        didLogWakeWindowStart = false
        heuristicSnapshot = await heuristicEngine.configure(
            wakeWindowStart: windowStartTime,
            wakeUpTime: wakeUpTime,
            calibrationProfile: currentCalibrationProfile
        )
        seenSampleUUIDs.removeAll()

        log(
            "SESSION",
            "Starting motion-first monitoring for '\(schedule.name)' wake=\(formatTimestamp(wakeUpTime)) windowStart=\(formatTimestamp(windowStartTime)) armedAt=\(formatTimestamp(effectiveArmedAt)) haptic=\(hapticPatternType.displayName)"
        )

        isMonitoringStartupInProgress = true
        isMonitoringActive = true
        isDegradedMode = false
        sessionState = .monitoring
        notifyStateChange()

        startHeartRateQuery(from: Date(), until: wakeUpTime)
        startLiveMotionUpdates()
        scheduleExactWakeTimer()
        scheduleWindowStartTimer()
        scheduleRecorderRefreshTimer()
        await refreshRecorderBackfill(reason: "session-start")

        isMonitoringStartupInProgress = false
        notifyStateChange()
        checkForWakeTrigger()

        log(
            "SESSION",
            "Motion-first monitoring active for '\(schedule.name)'. motionAvailable=\(motionManager.isDeviceMotionAvailable) recorderStatus='\(recorderStatus)'"
        )
    }

    func finishMonitoringAfterTrigger() {
        guard isMonitoringActive || sessionState == .triggered else { return }

        log(
            "SESSION",
            "Finishing monitoring after trigger. Haptics, handoff, and watch fallback remain active until post-trigger work completes."
        )
        tearDownMonitoringSession()
        currentSchedule = nil
        currentScheduleID = nil
        wakeUpTime = nil
        windowStartTime = nil
        didLogWakeWindowStart = false
        isMonitoringActive = false

        Task { [weak self] in
            await self?.waitForPostTriggerWork()
            await MainActor.run {
                guard let self else { return }
                self.log("SESSION", "Post-trigger work complete — ending any remaining diagnostic workout session")
            }
            await self?.endWorkoutSession()
            await MainActor.run {
                guard let self else { return }
                self.clearTriggerContext()
                self.sessionState = .idle
                self.notifyStateChange()
                self.onPostTriggerWorkComplete?()
                self.log("SESSION", "Monitoring cleanup completed after trigger")
            }
        }
    }

    private func waitForPostTriggerWork() async {
        // Poll until haptics, deferred handoff, and light ramp are all done.
        // Haptics: max 60s. Deferred handoff: 8s. Light ramp: ~60s after that.
        // Worst case total: ~130s. Poll interval kept short to avoid unnecessary delay.
        let maxWait: TimeInterval = 180
        let pollInterval: TimeInterval = 2
        let deadline = Date().addingTimeInterval(maxWait)

        while Date() < deadline {
            let done = await MainActor.run {
                hapticTimer == nil && deferredLightRampTask == nil && lightRampTask == nil
            }
            if done { return }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        await MainActor.run {
            log("SESSION", "Post-trigger work wait timed out after \(Int(maxWait))s — proceeding with cleanup", level: .warning)
        }
    }

    func stopMonitoring() {
        persistCurrentOccurrenceSummary(fallbackReason: "monitoring stopped")
        log("SESSION", "Stopping monitoring manually")
        tearDownMonitoringSession()
        stopHaptics()
        deferredLightRampTask?.cancel()
        deferredLightRampTask = nil
        lightRampTask?.cancel()
        lightRampTask = nil
        clearTriggerContext()

        currentSchedule = nil
        currentScheduleID = nil
        wakeUpTime = nil
        windowStartTime = nil
        didLogWakeWindowStart = false
        isMonitoringActive = false
        isDegradedMode = false
        errorMessage = nil
        sessionState = .idle
        notifyStateChange()
        onMonitoringCancelled?()

        Task { [weak self] in
            await self?.endWorkoutSession()
        }

        log("SESSION", "Monitoring stopped")
        queueActiveLogTransfer()
    }

    private func failMonitoring(_ message: String) {
        persistCurrentOccurrenceSummary(fallbackReason: message)
        log("SESSION", "Monitoring failed: \(message)", level: .error)
        tearDownMonitoringSession()
        stopHaptics()
        deferredLightRampTask?.cancel()
        deferredLightRampTask = nil
        lightRampTask?.cancel()
        lightRampTask = nil
        clearTriggerContext()

        currentSchedule = nil
        currentScheduleID = nil
        wakeUpTime = nil
        windowStartTime = nil
        didLogWakeWindowStart = false
        isMonitoringActive = false
        isDegradedMode = false
        errorMessage = message
        sessionState = .failed
        notifyStateChange()
        onMonitoringCancelled?()

        Task { [weak self] in
            await self?.endWorkoutSession()
        }

        queueActiveLogTransfer()
    }

    private func tearDownMonitoringSession() {
        invalidateMonitoringTimers()
        stopLiveMotionUpdates()
        recorderBackfillTask?.cancel()
        recorderBackfillTask = nil
        preparedWakeSignature = nil
        didArmRecorderForPreparedWake = false

        stopHeartRateQuery()
        seenSampleUUIDs.removeAll()
        lastHRSampleDate = nil
        isMonitoringStartupInProgress = false
        resetWorkoutRecoveryRetryState()
    }

    private func clearTriggerContext() {
        activeLocalRampTriggerID = nil
        activeTriggerID = nil
        activeTriggerSchedule = nil
        activeTriggerDate = nil
        activeTriggerWakeUpTime = nil
        activeTriggerFallbackMode = nil
        activeTriggerConfidence = nil
        activeTriggerMotionScore = nil
        activeTriggerSensorProvenance = nil
    }

    private func refreshMotionCapabilityStatus() {
        let authorizationStatus = CMSensorRecorder.authorizationStatus()
        motionStatus = motionManager.isDeviceMotionAvailable
            ? "Live motion available"
            : "Live motion unavailable"

        if !CMSensorRecorder.isAccelerometerRecordingAvailable() {
            recorderStatus = "Recorder unavailable on this watch"
        } else {
            switch authorizationStatus {
            case .authorized:
                recorderStatus = "Recorder authorized"
            case .denied:
                recorderStatus = "Recorder access denied"
            case .restricted:
                recorderStatus = "Recorder access restricted"
            case .notDetermined:
                recorderStatus = "Recorder access not determined"
            @unknown default:
                recorderStatus = "Recorder access unknown"
            }
        }

        onAuthorizationChanged?()
        onPresentationStateChanged?()
    }

    @discardableResult
    private func startRecordedMotionCaptureIfPossible(
        schedule: WatchScheduleSnapshot,
        wakeUpTime: Date,
        windowStart: Date,
        armedAt: Date
    ) -> Bool {
        refreshMotionCapabilityStatus()

        guard CMSensorRecorder.isAccelerometerRecordingAvailable() else {
            log("MOTION", "Skipping recorder start for '\(schedule.name)' because accelerometer recording is unavailable", level: .warning)
            return false
        }

        let authorizationStatus = CMSensorRecorder.authorizationStatus()
        guard authorizationStatus != .denied, authorizationStatus != .restricted else {
            log(
                "MOTION",
                "Skipping recorder start for '\(schedule.name)' because motion recording access is unavailable (\(motionAuthorizationStatusDescription))",
                level: .warning
            )
            return false
        }

        let duration = wakeUpTime.timeIntervalSince(armedAt)
        guard duration > 0 else {
            recorderStatus = "Wake already passed"
            return false
        }

        guard duration <= recorderMaxDuration else {
            recorderStatus = "Wake is more than 12h away"
            log(
                "MOTION",
                "Skipping recorder start for '\(schedule.name)' because wake is beyond the 12h recorder limit. armedAt=\(formatTimestamp(armedAt)) wake=\(formatTimestamp(wakeUpTime)) windowStart=\(formatTimestamp(windowStart))",
                level: .warning
            )
            return false
        }

        let requestedDuration = min(duration + recorderLagAllowance, recorderMaxDuration)
        sensorRecorder.recordAccelerometer(forDuration: requestedDuration)
        recorderStatus = "Recorder armed for \(formatElapsed(requestedDuration))"
        log(
            "MOTION",
            "Started accelerometer recorder for '\(schedule.name)' duration=\(formatElapsed(requestedDuration)) wake=\(formatTimestamp(wakeUpTime))"
        )
        onPresentationStateChanged?()
        return true
    }

    private func startLiveMotionUpdates() {
        refreshMotionCapabilityStatus()
        guard motionManager.isDeviceMotionAvailable else {
            motionStatus = "Live motion unavailable"
            isDegradedMode = true
            onPresentationStateChanged?()
            return
        }

        motionManager.stopDeviceMotionUpdates()
        motionManager.deviceMotionUpdateInterval = 0.1
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.motionStatus = "Motion error: \(error.localizedDescription)"
                    self?.isDegradedMode = true
                    self?.log(
                        "MOTION",
                        "Device motion update failed: \(error.localizedDescription)",
                        level: .warning
                    )
                    self?.onPresentationStateChanged?()
                }
                return
            }

            guard let motion else { return }
            let sample = SmartWakeLiveMotionSample(
                date: Date(),
                userAccelerationMagnitude: Self.vectorMagnitude(
                    x: motion.userAcceleration.x,
                    y: motion.userAcceleration.y,
                    z: motion.userAcceleration.z
                ),
                rotationMagnitude: Self.vectorMagnitude(
                    x: motion.rotationRate.x,
                    y: motion.rotationRate.y,
                    z: motion.rotationRate.z
                ),
                gravityX: motion.gravity.x,
                gravityY: motion.gravity.y,
                gravityZ: motion.gravity.z,
                pitch: motion.attitude.pitch,
                roll: motion.attitude.roll,
                yaw: motion.attitude.yaw
            )

            Task { @MainActor [weak self] in
                await self?.handleLiveMotionSample(sample)
            }
        }

        motionStatus = "Live motion active (10 Hz)"
        onPresentationStateChanged?()
        log("MOTION", "Started live device-motion updates at 10 Hz")
    }

    private func stopLiveMotionUpdates() {
        motionManager.stopDeviceMotionUpdates()
        motionStatus = "Motion idle"
        onPresentationStateChanged?()
    }

    private func scheduleRecorderRefreshTimer() {
        recorderRefreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: recorderRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshRecorderBackfill(reason: "periodic-refresh")
            }
        }
        recorderRefreshTimer = timer
    }

    private func refreshRecorderBackfill(reason: String) async {
        guard let windowStartTime, let wakeUpTime else { return }

        let queryStart = max(
            armedAt ?? windowStartTime.addingTimeInterval(-recorderLookback),
            windowStartTime.addingTimeInterval(-recorderLookback)
        )
        let queryEnd = min(
            Date().addingTimeInterval(-recorderLagAllowance),
            wakeUpTime
        )

        guard queryEnd > queryStart else {
            lastRecorderBackfillDescription = "Recorder backfill not ready yet"
            onPresentationStateChanged?()
            return
        }

        recorderBackfillTask?.cancel()
        recorderBackfillTask = Task { [weak self] in
            guard let self else { return }
            let bins = await self.loadRecordedMotionBins(from: queryStart, to: queryEnd)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.isMonitoringActive || self.isMonitoringStartupInProgress else { return }
                Task { [weak self] in
                    guard let self else { return }
                    let snapshot = await self.heuristicEngine.ingestRecordedMotionBins(
                        bins,
                        evaluatedAt: Date()
                    )
                    await MainActor.run {
                        self.heuristicSnapshot = snapshot
                        self.lastRecorderBackfillDescription = bins.isEmpty
                            ? "No recorder bins from \(self.formatTimestamp(queryStart)) to \(self.formatTimestamp(queryEnd))"
                            : "Loaded \(bins.count) recorder bin(s) through \(self.formatTimestamp(queryEnd))"
                        self.recorderStatus = bins.isEmpty
                            ? "Recorder backfill empty"
                            : "Recorder backfill refreshed"
                        if self.logStore.runtimeDiagnosticsEnabled {
                            self.log(
                                "MOTION",
                                "Recorder backfill (\(reason)) start=\(self.formatTimestamp(queryStart)) end=\(self.formatTimestamp(queryEnd)) bins=\(bins.count)"
                            )
                        }
                        self.onPresentationStateChanged?()
                        self.checkForWakeTrigger()
                    }
                }
            }
        }
    }

    private func handleLiveMotionSample(_ sample: SmartWakeLiveMotionSample) async {
        guard isMonitoringActive || isMonitoringStartupInProgress else { return }
        lastLiveMotionSampleDescription = "\(String(format: "%.3f", sample.userAccelerationMagnitude)) g at \(formatTimestamp(sample.date))"

        let decision = await heuristicEngine.ingestLiveMotionSample(sample)
        applyHeuristicDecision(decision, source: "live-motion")
    }

    private func applyHeuristicDecision(
        _ decision: SmartWakeHeuristicDecision,
        source: String
    ) {
        heuristicSnapshot = decision.snapshot
        if logStore.runtimeDiagnosticsEnabled {
            log(
                "HEURISTIC",
                "\(source) confidence=\(String(format: "%.3f", decision.confidence)) motionScore=\(String(format: "%.3f", decision.motionScore)) hrFreshness=\(decision.hrFreshnessSeconds.map { String(format: "%.0fs", $0) } ?? "--") motionFreshness=\(decision.motionFreshnessSeconds.map { String(format: "%.1fs", $0) } ?? "--")"
            )
        }
        onPresentationStateChanged?()

        guard decision.shouldTrigger,
              sessionState == .monitoring,
              activeTriggerID == nil,
              let schedule = currentSchedule else { return }

        log(
            "HEURISTIC",
            "Trigger decision accepted from \(source): \(decision.triggerReason ?? "motion evidence threshold crossed")"
        )
        fireTrigger(
            schedule: schedule,
            confidence: decision.confidence,
            motionScore: decision.motionScore,
            sensorProvenance: decision.sensorProvenance,
            fallbackMode: .earlyRamp
        )
    }

    private func persistCurrentOccurrenceSummary(fallbackReason: String) {
        guard let currentSchedule,
              let wakeUpTime,
              let windowStartTime else { return }

        let capturedTriggerDate = activeTriggerDate
        let capturedTriggerConfidence = activeTriggerConfidence
        let capturedMotionScore = activeTriggerMotionScore
        let capturedSensorProvenance = activeTriggerSensorProvenance
        let capturedSnapshot = heuristicSnapshot
        let capturedArmedAt = armedAt
        let triggerMode: SmartWakeTriggerMode = activeTriggerDate == nil ? .exactWakeFallback : .earlyMotionTrigger
        let provenance = capturedSensorProvenance ?? SmartWakeSensorProvenance(
            usedLiveMotion: true,
            usedRecordedMotionBaseline: capturedSnapshot.recorderBaselineReady,
            usedHeartRate: capturedSnapshot.latestHeartRate != nil,
            heartRateWasStale: (capturedSnapshot.hrFreshnessSeconds ?? .infinity) > 90,
            triggerMode: triggerMode
        )

        Task { [weak self] in
            guard let self else { return }
            let summary = await self.heuristicEngine.makeOccurrenceSummary(
                scheduleID: currentSchedule.id,
                scheduleName: currentSchedule.name,
                armedAt: capturedArmedAt,
                wakeWindowStart: windowStartTime,
                wakeUpTime: wakeUpTime,
                triggerDate: capturedTriggerDate,
                triggerConfidence: capturedTriggerConfidence,
                motionScore: capturedMotionScore,
                hrFreshnessSeconds: capturedSnapshot.hrFreshnessSeconds,
                motionFreshnessSeconds: capturedSnapshot.motionFreshnessSeconds,
                sensorProvenance: provenance,
                fallbackReason: fallbackReason
            )
            await MainActor.run {
                self.persistOccurrenceSummary(summary)
            }
        }
    }

    private func persistOccurrenceSummary(_ summary: SmartWakeOccurrenceSummary) {
        let fileManager = FileManager.default
        let supportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let directoryURL = supportURL.appendingPathComponent(
            "SmartWakeOccurrences",
            isDirectory: true
        )
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmssZ"
        let fileURL = directoryURL.appendingPathComponent(
            "occurrence-\(formatter.string(from: summary.createdAt)).json"
        )

        do {
            let data = try JSONEncoder().encode(summary)
            try data.write(to: fileURL, options: .atomic)
            lastOccurrenceSummaryStatus = "Saved \(fileURL.lastPathComponent)"
            pruneOccurrenceSummaries(in: directoryURL)
            onOccurrenceSummaryReady?(summary)
            log(
                "SESSION",
                "Persisted Smart Wake occurrence summary \(summary.id.uuidString) fallbackReason='\(summary.fallbackReason ?? "none")'"
            )
        } catch {
            lastOccurrenceSummaryStatus = "Failed to save occurrence summary"
            log(
                "SESSION",
                "Failed to persist occurrence summary: \(error.localizedDescription)",
                level: .error
            )
        }
        onPresentationStateChanged?()
    }

    private func pruneOccurrenceSummaries(in directoryURL: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let summaries = urls
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        for url in summaries.dropFirst(30) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func loadRecordedMotionBins(
        from startDate: Date,
        to endDate: Date
    ) async -> [SmartWakeRecordedMotionBin] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: Self.recordedMotionBins(from: startDate, to: endDate)
                )
            }
        }
    }

    nonisolated private static func recordedMotionBins(
        from startDate: Date,
        to endDate: Date
    ) -> [SmartWakeRecordedMotionBin] {
        let recorder = CMSensorRecorder()
        guard let dataList = recorder.accelerometerData(from: startDate, to: endDate) else {
            return []
        }

        var bins: [Int64: (sum: Double, count: Int)] = [:]

        var iterator = NSFastEnumerationIterator(dataList)
        while let sample = iterator.next() as? CMRecordedAccelerometerData {
            let magnitude = vectorMagnitude(
                x: sample.acceleration.x,
                y: sample.acceleration.y,
                z: sample.acceleration.z
            )
            let key = Int64(floor(sample.startDate.timeIntervalSince1970))
            var aggregate = bins[key] ?? (sum: 0, count: 0)
            aggregate.sum += magnitude
            aggregate.count += 1
            bins[key] = aggregate
        }

        return bins.keys.sorted().compactMap { key in
            guard let aggregate = bins[key], aggregate.count > 0 else { return nil }
            return SmartWakeRecordedMotionBin(
                secondStart: Date(timeIntervalSince1970: TimeInterval(key)),
                averageAccelerationMagnitude: aggregate.sum / Double(aggregate.count),
                sampleCount: aggregate.count
            )
        }
    }

    nonisolated private static func vectorMagnitude(x: Double, y: Double, z: Double) -> Double {
        sqrt((x * x) + (y * y) + (z * z))
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
        isProactiveWorkoutRunning = false
        isWorkoutSessionRunning = true
        log("HEALTHKIT", "Workout session start request completed; awaiting running state")
    }

    private func endWorkoutSession() async {
        workoutSession?.end()
        if let builder = workoutBuilder {
            try? await builder.endCollection(at: Date())
            _ = try? await builder.finishWorkout()
        }
        workoutSession = nil
        workoutBuilder = nil
        isProactiveWorkoutRunning = false
        isWorkoutSessionRunning = false
        log("HEALTHKIT", "Workout session ended")
    }

    private func clearWorkoutSessionReference(
        reason: String,
        level: SmartWakeLogLevel = .warning
    ) {
        if workoutSession != nil || workoutBuilder != nil {
            log("HEALTHKIT", reason, level: level)
        }
        workoutSession?.end()
        workoutSession = nil
        workoutBuilder = nil
        isProactiveWorkoutRunning = false
        isWorkoutSessionRunning = false
    }

    func preStartWorkoutSession() {
        #if DEBUG
        guard !isNoBuilderValidationActive else {
            log(
                "HEALTHKIT",
                "Skipping proactive workout start while no-builder validation is active",
                level: .warning
            )
            return
        }
        #endif

        guard !isMonitoringActive, !isMonitoringStartupInProgress else {
            log(
                "HEALTHKIT",
                "Skipping proactive workout start because monitoring is already in progress",
                level: .warning
            )
            return
        }

        guard !isProactiveWorkoutRunning, !isWorkoutSessionRunning else {
            log("HEALTHKIT", "Proactive workout already running — skipping")
            return
        }

        guard isHealthKitAuthorized else {
            log(
                "HEALTHKIT",
                "HealthKit prompt not completed — skipping proactive workout start",
                level: .warning
            )
            return
        }

        if workoutSession != nil {
            log("HEALTHKIT", "Cleaning up stale workout session reference before proactive start", level: .warning)
            workoutSession?.end()
            workoutSession = nil
            if workoutBuilder != nil {
                log(
                    "HEALTHKIT",
                    "Unexpected non-nil workoutBuilder during proactive cleanup — nilling without teardown",
                    level: .error
                )
            }
            workoutBuilder = nil
            isWorkoutSessionRunning = false
        }

        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            session.delegate = self
            workoutSession = session
            workoutBuilder = nil

            let startDate = Date()
            session.startActivity(with: startDate)
            isProactiveWorkoutRunning = true
            isWorkoutSessionRunning = true
            log(
                "HEALTHKIT",
                "Proactive no-builder workout session started at \(formatTimestamp(startDate))"
            )
        } catch {
            workoutSession = nil
            workoutBuilder = nil
            isProactiveWorkoutRunning = false
            isWorkoutSessionRunning = false
            log(
                "HEALTHKIT",
                "Failed to start proactive no-builder workout session: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    func stopProactiveWorkout() {
        guard isProactiveWorkoutRunning || workoutSession != nil else { return }

        log("HEALTHKIT", "Stopping proactive workout session")
        stopHeartRateQuery()
        workoutSession?.end()
        workoutSession = nil
        if workoutBuilder != nil {
            log(
                "HEALTHKIT",
                "Unexpected non-nil workoutBuilder while stopping proactive workout — clearing without teardown",
                level: .error
            )
        }
        workoutBuilder = nil
        isProactiveWorkoutRunning = false
        isWorkoutSessionRunning = false
        seenSampleUUIDs.removeAll()
    }

    private func isWorkoutSessionUsable() -> Bool {
        workoutSession != nil && isWorkoutSessionRunning
    }

    private func resetWorkoutRecoveryRetryState() {
        workoutRecoveryRetryTask?.cancel()
        workoutRecoveryRetryTask = nil
        workoutRecoveryRetryAttempts = 0
        didLogWorkoutRecoveryRetryExhaustion = false
    }

    private func scheduleWorkoutRecoveryRetryIfNeeded(reason: String) {
        guard isMonitoringActive, isDegradedMode, sessionState == .monitoring else { return }
        guard activeTriggerID == nil else { return }
        guard workoutRecoveryRetryTask == nil else { return }
        guard let wakeUpTime else { return }

        let timeRemaining = wakeUpTime.timeIntervalSinceNow
        guard timeRemaining > 1 else {
            if !didLogWorkoutRecoveryRetryExhaustion {
                didLogWorkoutRecoveryRetryExhaustion = true
                log(
                    "SESSION",
                    "Skipping workout recovery retry because wake time is imminent",
                    level: .warning
                )
            }
            return
        }

        guard workoutRecoveryRetryAttempts < maxWorkoutRecoveryRetryAttempts else {
            if !didLogWorkoutRecoveryRetryExhaustion {
                didLogWorkoutRecoveryRetryExhaustion = true
                log(
                    "SESSION",
                    "Workout recovery retry budget exhausted; remaining in degraded mode until wake time",
                    level: .warning
                )
            }
            return
        }

        let attempt = workoutRecoveryRetryAttempts + 1
        workoutRecoveryRetryAttempts = attempt
        let delay = min(workoutRecoveryRetryDelay, timeRemaining - 1)

        log(
            "SESSION",
            "Scheduling workout recovery retry \(attempt)/\(maxWorkoutRecoveryRetryAttempts) in \(formatInterval(delay)) (\(reason))",
            level: .warning
        )

        workoutRecoveryRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                self.workoutRecoveryRetryTask = nil
                return
            }

            guard self.isMonitoringActive,
                  self.isDegradedMode,
                  self.sessionState == .monitoring,
                  self.activeTriggerID == nil,
                  let wakeUpTime = self.wakeUpTime,
                  Date() < wakeUpTime else {
                self.workoutRecoveryRetryTask = nil
                return
            }

            self.clearWorkoutSessionReference(
                reason: "Clearing failed workout state before recovery retry \(attempt)",
                level: .warning
            )
            self.log(
                "SESSION",
                "Retrying workout startup while degraded monitoring is active (attempt \(attempt)/\(self.maxWorkoutRecoveryRetryAttempts))",
                level: .warning
            )

            do {
                try await self.startWorkoutSession()
                self.log(
                    "SESSION",
                    "Workout recovery retry \(attempt) start request completed; waiting \(self.formatInterval(self.workoutRecoveryRetryValidationDelay)) for a stable running state"
                )
            } catch {
                self.workoutRecoveryRetryTask = nil
                self.clearWorkoutSessionReference(
                    reason: "Clearing workout state after recovery retry \(attempt) failed",
                    level: .warning
                )
                self.log(
                    "SESSION",
                    "Workout recovery retry \(attempt) failed: \(error.localizedDescription)",
                    level: .warning
                )
                self.scheduleWorkoutRecoveryRetryIfNeeded(reason: "retry \(attempt) failed")
                return
            }

            do {
                try await Task.sleep(for: .seconds(self.workoutRecoveryRetryValidationDelay))
            } catch {
                self.workoutRecoveryRetryTask = nil
                return
            }

            self.workoutRecoveryRetryTask = nil

            guard self.isMonitoringActive, self.sessionState == .monitoring else { return }

            if self.isDegradedMode {
                self.clearWorkoutSessionReference(
                    reason: "Clearing workout state after recovery retry \(attempt) did not stabilize",
                    level: .warning
                )
                self.log(
                    "SESSION",
                    "Workout recovery retry \(attempt) did not recover live workout execution",
                    level: .warning
                )
                self.scheduleWorkoutRecoveryRetryIfNeeded(reason: "retry \(attempt) did not stabilize")
            } else {
                self.log(
                    "SESSION",
                    "Workout recovery retry \(attempt) stabilized; full monitoring resumed"
                )
            }
        }
    }

    func attemptForegroundWorkoutRecoveryIfNeeded(reason: String) {
        guard isMonitoringActive, isDegradedMode, sessionState == .monitoring else { return }
        guard activeTriggerID == nil else { return }
        guard let wakeUpTime, Date() < wakeUpTime else { return }

        if workoutRecoveryRetryTask != nil {
            log(
                "SESSION",
                "Cancelling delayed workout recovery retry in favor of immediate foreground attempt (\(reason))",
                level: .warning
            )
        }
        workoutRecoveryRetryTask?.cancel()
        workoutRecoveryRetryTask = nil

        clearWorkoutSessionReference(
            reason: "Clearing degraded workout state before foreground recovery attempt",
            level: .warning
        )
        log(
            "SESSION",
            "Attempting immediate workout recovery from foreground (\(reason))",
            level: .warning
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.startWorkoutSession()
                self.log(
                    "SESSION",
                    "Foreground workout recovery start request completed; awaiting running state"
                )
            } catch {
                self.clearWorkoutSessionReference(
                    reason: "Clearing workout state after foreground recovery failure",
                    level: .warning
                )
                self.log(
                    "SESSION",
                    "Foreground workout recovery failed: \(error.localizedDescription)",
                    level: .warning
                )
                self.scheduleWorkoutRecoveryRetryIfNeeded(
                    reason: "foreground recovery failed"
                )
            }
        }
    }

    // MARK: - Heart Rate Query

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

    private func startHeartRateQuery(from startDate: Date, until endDate: Date?) {
        let heartRateType = HKQuantityType(.heartRate)
        stopHeartRateQuery()
        let queryEndDate = endDate.map { max(startDate.addingTimeInterval(300), $0.addingTimeInterval(300)) }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: queryEndDate)
        log(
            "HEALTHKIT",
            "Starting anchored heart-rate query from \(formatTimestamp(startDate)) to \(formatTimestamp(queryEndDate))"
        )

        let query = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, _, _ in
            self?.processHeartRateSamples(samples, source: "initial-query")
        }

        query.updateHandler = { [weak self] _, samples, _, _, _ in
            self?.processHeartRateSamples(samples, source: "live")
        }

        healthStore.execute(query)
        heartRateQuery = query
    }

    nonisolated private func processHeartRateSamples(_ samples: [HKSample]?, source: String) {
        guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else { return }

        Task { @MainActor in
            #if DEBUG
            if self.isNoBuilderValidationActive {
                let bpmUnit = HKUnit.count().unitDivided(by: .minute())
                self.processNoBuilderValidationSamples(samples, bpmUnit: bpmUnit)
                return
            }
            #endif

            guard self.isMonitoringActive || self.isMonitoringStartupInProgress else { return }

            let maxDate = Date().addingTimeInterval(120)
            let timelySamples = samples.filter { $0.startDate <= maxDate }
            let filteredFutureCount = samples.count - timelySamples.count
            if filteredFutureCount > 0 {
                self.log(
                    "HEALTHKIT",
                    "Filtered \(filteredFutureCount) future-dated sample(s) from \(source) batch of \(samples.count)",
                    level: .warning
                )
            }

            let uniqueSamples = timelySamples.filter { self.seenSampleUUIDs.insert($0.uuid).inserted }
            guard !uniqueSamples.isEmpty else { return }
            self.updateLastHRSampleDate(with: uniqueSamples.lazy.map(\.startDate).max())

            if !self.hasConfirmedHRAccess {
                self.hasConfirmedHRAccess = true
                self.log("HEALTHKIT", "HR access confirmed via live sample")
                self.onHRAccessConfirmed?()
            }

            let bpmUnit = HKUnit.count().unitDivided(by: .minute())
            let orderedSamples = uniqueSamples.sorted { $0.startDate < $1.startDate }

            Task { [weak self] in
                guard let self else { return }
                var lastDecision: SmartWakeHeuristicDecision?

                for sample in orderedSamples {
                    let bpm = sample.quantity.doubleValue(for: bpmUnit)
                    if self.logStore.runtimeDiagnosticsEnabled {
                        self.log(
                            "HEALTHKIT",
                            "Heart-rate sample (\(source)) \(self.formatBPM(bpm)) BPM at \(self.formatTimestamp(sample.startDate))"
                        )
                    }
                    lastDecision = await self.heuristicEngine.ingestHeartRateSample(
                        bpm: bpm,
                        at: sample.startDate
                    )
                }

                guard let lastDecision else { return }
                await MainActor.run {
                    self.applyHeuristicDecision(lastDecision, source: "heart-rate")
                }
            }
        }
    }

    private func stopHeartRateQuery() {
        if let query = heartRateQuery {
            healthStore.stop(query)
            heartRateQuery = nil
        }
    }

    // MARK: - Wake Check

    private func invalidateMonitoringTimers() {
        exactWakeTimer?.invalidate()
        exactWakeTimer = nil
        windowStartTimer?.invalidate()
        windowStartTimer = nil
        recorderRefreshTimer?.invalidate()
        recorderRefreshTimer = nil
    }

    private func scheduleOneShotTimer(
        _ keyPath: ReferenceWritableKeyPath<SmartWakeSessionController, Timer?>,
        fireDate: Date,
        logLabel: String,
        action: @escaping (SmartWakeSessionController) -> Void
    ) {
        self[keyPath: keyPath]?.invalidate()

        let interval = max(0, fireDate.timeIntervalSinceNow)
        log(
            "SESSION",
            "Scheduling \(logLabel) timer for \(formatTimestamp(fireDate)) (in \(formatInterval(interval)))"
        )
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self[keyPath: keyPath] = nil
                action(self)
            }
        }
        self[keyPath: keyPath] = timer
    }

    private func scheduleExactWakeTimer() {
        guard let wakeUpTime else { return }
        scheduleOneShotTimer(
            \.exactWakeTimer,
            fireDate: wakeUpTime,
            logLabel: "exact-wake"
        ) { controller in
            controller.checkForWakeTrigger()
        }
    }

    private func scheduleWindowStartTimer() {
        guard let windowStartTime else { return }
        guard windowStartTime > Date() else { return }

        scheduleOneShotTimer(
            \.windowStartTimer,
            fireDate: windowStartTime,
            logLabel: "wake-window-start"
        ) { controller in
            controller.checkForWakeTrigger()
        }
    }

    /// Called by the scheduler when the extended runtime session is about to
    /// expire or has been invalidated. Runs an immediate wake check so the
    /// watch can still force-fire before background execution is lost.
    func forceImmediateWakeCheck() {
        guard let wakeUpTime, let currentSchedule else { return }

        let now = Date()
        if now >= wakeUpTime, activeTriggerID == nil {
            log(
                "WAKE_WINDOW",
                "Emergency force-fire at \(formatTimestamp(now)) — session loss before monitoring fully committed",
                level: .warning
            )
            fireTrigger(
                schedule: currentSchedule,
                confidence: 1.0,
                motionScore: heuristicSnapshot.motionScore,
                sensorProvenance: .exactWakeFallback,
                fallbackMode: .exactWakeFinalState
            )
        } else if isMonitoringActive {
            checkForWakeTrigger()
        }
    }

    /// Clears monitoring state without marking the wake as completed, so a
    /// later foreground pass can still re-arm the same occurrence if needed.
    func tearDownMonitoringWithoutCompletion() {
        log("SESSION", "Tearing down monitoring after session loss (occurrence not completed)")
        tearDownMonitoringSession()
        stopHaptics()
        deferredLightRampTask?.cancel()
        deferredLightRampTask = nil
        lightRampTask?.cancel()
        lightRampTask = nil
        clearTriggerContext()
        isMonitoringActive = false
        isDegradedMode = false
        sessionState = .idle
        notifyStateChange()

        Task { [weak self] in
            await self?.endWorkoutSession()
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
            if activeTriggerID == nil {
                log(
                    "WAKE_WINDOW",
                    "Reached exact wake time \(formatTimestamp(now)) without an early trigger. Forcing trigger."
                )
                fireTrigger(
                    schedule: schedule,
                    confidence: 1.0,
                    motionScore: heuristicSnapshot.motionScore,
                    sensorProvenance: .exactWakeFallback,
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

        Task { [weak self] in
            guard let self else { return }
            let decision = await self.heuristicEngine.evaluate(at: now)
            await MainActor.run {
                self.applyHeuristicDecision(decision, source: "timer")
            }
        }
    }

    private func fireTrigger(
        schedule: WatchScheduleSnapshot,
        confidence: Double,
        motionScore: Double?,
        sensorProvenance: SmartWakeSensorProvenance,
        fallbackMode: WatchFallbackMode
    ) {
        let triggerDate = Date()
        let triggerID = UUID()

        Task {
            await heuristicEngine.markTriggered(at: triggerDate)
        }
        activeTriggerID = triggerID
        activeTriggerSchedule = schedule
        activeTriggerDate = triggerDate
        activeTriggerWakeUpTime = wakeUpTime
        activeTriggerFallbackMode = fallbackMode
        activeTriggerConfidence = confidence
        activeTriggerMotionScore = motionScore
        activeTriggerSensorProvenance = sensorProvenance
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
            heartRateAtTrigger: heuristicSnapshot.latestHeartRate,
            motionLevel: heuristicSnapshot.motionEnergy60s,
            motionScore: motionScore,
            hrFreshnessSeconds: heuristicSnapshot.hrFreshnessSeconds,
            motionFreshnessSeconds: heuristicSnapshot.motionFreshnessSeconds,
            sensorProvenance: sensorProvenance
        )

        persistCurrentOccurrenceSummary(
            fallbackReason: fallbackMode == .earlyRamp ? "early trigger" : "exact wake fallback"
        )
        onTrigger?(payload)
        finishMonitoringAfterTrigger()

        log(
            "TRIGGER",
            "Trigger fired id=\(triggerID.uuidString) mode=\(describeFallbackMode(fallbackMode)) confidence=\(String(format: "%.3f", confidence)) motionScore=\(String(format: "%.3f", motionScore ?? 0)) latestHR=\(formatBPM(heuristicSnapshot.latestHeartRate))"
        )
    }

    private func notifyStateChange() {
        let state = SmartWakeSessionState(
            state: sessionState,
            scheduleID: currentScheduleID,
            message: errorMessage
        )
        onStateChange?(state)
        onPresentationStateChanged?()
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

    #if DEBUG
    func startNoBuilderValidation() async {
        guard !isMonitoringActive, !isMonitoringStartupInProgress, !isProactiveWorkoutRunning else {
            noBuilderValidationStatus = "Monitoring active. Stop monitoring first."
            log(
                "VALIDATION",
                "Refusing to start no-builder validation while another workout path is active",
                level: .warning
            )
            return
        }

        guard !isNoBuilderValidationActive else {
            noBuilderValidationStatus = "Already running"
            log("VALIDATION", "Ignoring duplicate no-builder validation start", level: .warning)
            return
        }

        if !isHealthKitAuthorized {
            let authorized = await requestAuthorization()
            guard authorized else {
                noBuilderValidationStatus = "Health access request failed"
                log(
                    "VALIDATION",
                    "Cannot start no-builder validation because HealthKit authorization failed",
                    level: .error
                )
                return
            }
        }

        noBuilderValidationSampleCount = 0
        noBuilderValidationLastSampleDescription = "No samples yet"
        noBuilderValidationSeedProbeStatus = "Not run"
        noBuilderValidationLastSampleAt = nil
        noBuilderValidationStatus = "Starting..."

        stopHeartRateQuery()
        if workoutSession != nil {
            await endWorkoutSession()
        }

        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            session.delegate = self

            workoutSession = session
            workoutBuilder = nil
            isWorkoutSessionRunning = true
            isNoBuilderValidationActive = true

            let startDate = Date()
            noBuilderValidationStartedAt = startDate
            noBuilderValidationStatus = "Active — waiting for samples"
            log(
                "VALIDATION",
                "Started no-builder workout validation at \(formatTimestamp(startDate)). Send the app to background and watch for heart-rate samples."
            )

            session.startActivity(with: startDate)
            startHeartRateQuery(from: startDate, until: nil)
        } catch {
            workoutSession = nil
            workoutBuilder = nil
            isWorkoutSessionRunning = false
            isNoBuilderValidationActive = false
            noBuilderValidationStartedAt = nil
            noBuilderValidationStatus = "Start failed: \(error.localizedDescription)"
            log(
                "VALIDATION",
                "Failed to start no-builder workout validation: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    func stopNoBuilderValidation() {
        guard isNoBuilderValidationActive else {
            noBuilderValidationStatus = "No active validation session"
            log("VALIDATION", "Ignoring stop request with no active no-builder validation", level: .warning)
            return
        }

        let startedAt = noBuilderValidationStartedAt
        let sampleCount = noBuilderValidationSampleCount
        isNoBuilderValidationActive = false
        noBuilderValidationStatus = "Stopping..."
        log("VALIDATION", "Stopping no-builder workout validation")
        stopHeartRateQuery()

        Task { [weak self] in
            await self?.endWorkoutSession()
            await MainActor.run {
                guard let self else { return }
                self.finishNoBuilderValidationStop(startedAt: startedAt, sampleCount: sampleCount)
            }
        }
    }

    func runNoBuilderValidationSeedProbe() async {
        guard isNoBuilderValidationActive, let startedAt = noBuilderValidationStartedAt else {
            noBuilderValidationSeedProbeStatus = "Start validation first"
            log(
                "VALIDATION",
                "Ignoring 2h seed probe because no-builder validation is not active",
                level: .warning
            )
            return
        }

        noBuilderValidationSeedProbeStatus = "Running..."
        let endDate = Date()
        let queryStart = endDate.addingTimeInterval(-7200)
        log(
            "VALIDATION",
            "Running 2h seed probe from \(formatTimestamp(queryStart)) to \(formatTimestamp(endDate))"
        )

        do {
            let samples = try await fetchHistoricalHeartRateSamples(from: queryStart, to: endDate)
            let freshSamples = samples.filter { $0.startDate >= startedAt }
            let latestFreshSample = freshSamples.last?.startDate
            let summary = freshSamples.isEmpty
                ? "Fresh 0 / total \(samples.count)"
                : "Fresh \(freshSamples.count) / total \(samples.count), latest \(formatTimestamp(latestFreshSample))"

            noBuilderValidationSeedProbeStatus = summary
            log(
                "VALIDATION",
                "2h seed probe complete. total=\(samples.count) freshSinceStart=\(freshSamples.count) latestFresh=\(formatTimestamp(latestFreshSample))"
            )
        } catch {
            noBuilderValidationSeedProbeStatus = "Probe failed: \(error.localizedDescription)"
            log(
                "VALIDATION",
                "2h seed probe failed: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    private func processNoBuilderValidationSamples(_ samples: [HKQuantitySample], bpmUnit: HKUnit) {
        let orderedSamples = samples.sorted { $0.startDate < $1.startDate }

        for sample in orderedSamples {
            let bpm = sample.quantity.doubleValue(for: bpmUnit)
            let gapDescription: String
            if let lastSampleAt = noBuilderValidationLastSampleAt {
                let gap = sample.startDate.timeIntervalSince(lastSampleAt)
                gapDescription = " gap=\(formatInterval(gap))"
            } else {
                gapDescription = ""
            }

            noBuilderValidationSampleCount += 1
            noBuilderValidationLastSampleAt = sample.startDate
            noBuilderValidationLastSampleDescription = "\(formatBPM(bpm)) BPM at \(formatTimestamp(sample.startDate))"
            noBuilderValidationStatus = "Active — \(noBuilderValidationSampleCount) sample(s)"
            log(
                "VALIDATION",
                "No-builder sample #\(noBuilderValidationSampleCount) \(formatBPM(bpm)) BPM at \(formatTimestamp(sample.startDate))\(gapDescription)"
            )
        }
    }

    private func finishNoBuilderValidationStop(startedAt: Date?, sampleCount: Int) {
        let elapsed = startedAt.map { formatElapsed(Date().timeIntervalSince($0)) } ?? "--"
        isNoBuilderValidationActive = false
        noBuilderValidationStartedAt = nil
        noBuilderValidationLastSampleAt = nil
        noBuilderValidationStatus = "Stopped — \(sampleCount) sample(s) over \(elapsed)"
        log(
            "VALIDATION",
            "No-builder workout validation stopped after \(elapsed). totalSamples=\(sampleCount)"
        )
        queueActiveLogTransfer()
    }
    #endif

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
            guard !Task.isCancelled else { return }

            await MainActor.run {
                // Re-check cancellation inside MainActor.run: a phone ACK may have
                // cancelled this task after the check above but before this block runs.
                guard !Task.isCancelled else { return }
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

        await MainActor.run {
            lightRampTask = nil
            // Keep activeLocalRampTriggerID set — it guards against late handoffs
            // restarting fallback. Cleared in final post-trigger cleanup.
            log("LIGHTS", "Local light fallback task completed")
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
        pendingFollowUpBeats = []

        playHaptic(primaryHapticType(for: hapticPatternType))
        lastHapticPlayTime = Date()
        pendingFollowUpBeats = followUpBeats(for: hapticPatternType)

        hapticTimer = Timer.scheduledTimer(withTimeInterval: hapticTimerResolution, repeats: true) { [weak self] _ in
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
        #if os(watchOS)
        pendingFollowUpBeats = []
        #endif
        log("HAPTICS", "Haptic playback stopped")
    }

    #if os(watchOS)
    private func hapticTimerTick() {
        guard let startTime = hapticStartTime else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed >= hapticDuration {
            playHaptic(finalHapticType(for: hapticPatternType))
            stopHaptics()
            log("HAPTICS", "Haptic ramp reached completion and played final completion haptic")
            return
        }

        let progress = elapsed / hapticDuration
        let interval = nextInterval(for: hapticPatternType, progress: progress)
        let timeSinceLastPlay = lastHapticPlayTime.map { Date().timeIntervalSince($0) } ?? .infinity

        if let followUpBeat = pendingFollowUpBeats.first, timeSinceLastPlay >= followUpBeat.delay {
            playHaptic(followUpBeat.type)
            pendingFollowUpBeats.removeFirst()
            lastHapticPlayTime = Date()
            return
        }

        guard pendingFollowUpBeats.isEmpty else { return }
        guard timeSinceLastPlay >= interval else { return }

        playHaptic(primaryHapticType(for: hapticPatternType))
        lastHapticPlayTime = Date()
        pendingFollowUpBeats = followUpBeats(for: hapticPatternType)
    }

    private func playHaptic(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    private func primaryHapticType(for pattern: HapticPattern) -> WKHapticType {
        switch pattern {
        case .gentle:
            .click
        case .pulse:
            .start
        case .heartbeat:
            .directionUp
        case .alarm:
            .notification
        case .critical:
            .failure
        }
    }

    private func followUpBeats(for pattern: HapticPattern) -> [WatchHapticBeat] {
        switch pattern {
        case .gentle, .pulse:
            []
        case .heartbeat:
            [WatchHapticBeat(delay: 0.3, type: .click)]
        case .alarm:
            [WatchHapticBeat(delay: 0.25, type: .retry)]
        case .critical:
            [
                WatchHapticBeat(delay: 0.16, type: .notification),
                WatchHapticBeat(delay: 0.18, type: .retry)
            ]
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
            return 0.9 - 0.55 * progress
        case .critical:
            return 0.6 - 0.35 * progress
        }
    }

    private func finalHapticType(for pattern: HapticPattern) -> WKHapticType {
        switch pattern {
        case .critical:
            .failure
        case .gentle, .pulse, .heartbeat, .alarm:
            .notification
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
            guard workoutSession === self.workoutSession else {
                self.log(
                    "HEALTHKIT",
                    "Ignoring state change from stale workout session",
                    level: .warning
                )
                return
            }
            if toState == .running {
                self.isWorkoutSessionRunning = true
                if self.isMonitoringActive && self.isDegradedMode {
                    self.isDegradedMode = false
                    self.log(
                        "SESSION",
                        "Workout session entered running state during degraded monitoring — resuming full monitoring"
                    )
                } else if self.isMonitoringStartupInProgress {
                    self.log(
                        "SESSION",
                        "Workout session entered running state during monitoring startup"
                    )
                }
                return
            }
            if toState == .ended {
                self.isWorkoutSessionRunning = false
                #if DEBUG
                if self.isNoBuilderValidationActive {
                    let sampleCount = self.noBuilderValidationSampleCount
                    let startedAt = self.noBuilderValidationStartedAt
                    self.finishNoBuilderValidationStop(startedAt: startedAt, sampleCount: sampleCount)
                    self.log(
                        "VALIDATION",
                        "No-builder validation session ended externally",
                        level: .warning
                    )
                    return
                }
                #endif
                if self.isProactiveWorkoutRunning,
                   !self.isMonitoringActive,
                   !self.isMonitoringStartupInProgress {
                    self.isProactiveWorkoutRunning = false
                    self.log(
                        "HEALTHKIT",
                        "Proactive workout session ended before monitoring started",
                        level: .warning
                    )
                    return
                }
                if self.isMonitoringStartupInProgress && !self.isMonitoringActive {
                    self.isDegradedMode = true
                    self.log(
                        "SESSION",
                        "Workout session ended during monitoring startup — marking degraded startup result",
                        level: .warning
                    )
                    return
                }
                if self.isMonitoringActive && !self.isDegradedMode {
                    self.log(
                        "SESSION",
                        "Workout session ended during monitoring — switching to degraded mode",
                        level: .warning
                    )
                    self.isDegradedMode = true
                    // Keep monitoring alive — sample-driven checks and the
                    // exact-wake/window/seed timers remain active.
                    self.scheduleWorkoutRecoveryRetryIfNeeded(
                        reason: "workout session ended during monitoring"
                    )
                }
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
            guard workoutSession === self.workoutSession else {
                self.log(
                    "HEALTHKIT",
                    "Ignoring failure from stale workout session",
                    level: .warning
                )
                return
            }
            self.isWorkoutSessionRunning = false
            #if DEBUG
            if self.isNoBuilderValidationActive {
                let sampleCount = self.noBuilderValidationSampleCount
                let startedAt = self.noBuilderValidationStartedAt
                self.noBuilderValidationSeedProbeStatus = "Session failed: \(error.localizedDescription)"
                self.finishNoBuilderValidationStop(startedAt: startedAt, sampleCount: sampleCount)
                self.log(
                    "VALIDATION",
                    "No-builder validation session failed: \(error.localizedDescription)",
                    level: .error
                )
                return
            }
            #endif
            if self.isProactiveWorkoutRunning,
               !self.isMonitoringActive,
               !self.isMonitoringStartupInProgress {
                self.isProactiveWorkoutRunning = false
                self.log(
                    "HEALTHKIT",
                    "Proactive workout session failed before monitoring started: \(error.localizedDescription)",
                    level: .error
                )
                return
            }
            if self.isMonitoringStartupInProgress && !self.isMonitoringActive {
                self.isDegradedMode = true
                self.log(
                    "SESSION",
                    "Workout session failed during monitoring startup — marking degraded startup result",
                    level: .warning
                )
                return
            }
            if self.isMonitoringActive && !self.isDegradedMode {
                self.log(
                    "SESSION",
                    "Workout session failed during monitoring — switching to degraded mode",
                    level: .warning
                )
                self.isDegradedMode = true
                self.scheduleWorkoutRecoveryRetryIfNeeded(
                    reason: "workout session failed during monitoring"
                )
            }
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
