import Foundation
import HealthKit
import HomeKit
#if os(watchOS)
import WatchKit
#endif

@Observable
final class SmartWakeSessionController: NSObject {
    let healthStore = HKHealthStore()
    let heuristicEngine = WakeHeuristicEngine()

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
    private var lightRampTask: Task<Void, Never>?
    private var deferredLightRampTask: Task<Void, Never>?

    private var currentSchedule: WatchScheduleSnapshot?
    private var wakeUpTime: Date?
    private var windowStartTime: Date?
    private var activeTriggerID: UUID?
    private var activeTriggerSchedule: WatchScheduleSnapshot?
    private var activeLocalRampTriggerID: UUID?

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

    override init() {
        let homeKitService = WatchHomeKitService()
        self.homeKitService = homeKitService
        self.lightController = WatchLightController(homeKitService: homeKitService)
        super.init()
    }

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
            return isHealthKitAuthorized
        } catch {
            errorMessage = error.localizedDescription
            isHealthKitAuthorized = false
            return false
        }
    }

    // MARK: - Scheduling Diagnostics

    func updateNextScheduledWakeWindow(schedule: WatchScheduleSnapshot?, wakeUpTime: Date?) {
        guard let schedule, let wakeUpTime else {
            nextScheduledWakeWindowDescription = nil
            return
        }

        let windowStart = wakeUpTime.addingTimeInterval(-Double(schedule.smartWakeWindowMinutes) * 60)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        nextScheduledWakeWindowDescription = "\(schedule.name): \(formatter.string(from: windowStart)) - \(formatter.string(from: wakeUpTime))"
    }

    // MARK: - Session Lifecycle

    func startMonitoring(
        schedule: WatchScheduleSnapshot,
        wakeUpTime: Date
    ) async {
        guard !isMonitoringActive else { return }

        let windowStartTime = wakeUpTime.addingTimeInterval(
            -Double(schedule.smartWakeWindowMinutes) * 60
        )

        errorMessage = nil
        currentSchedule = schedule
        currentScheduleID = schedule.id
        self.wakeUpTime = wakeUpTime
        self.windowStartTime = windowStartTime
        heuristicEngine.configure(wakeWindowStart: windowStartTime)

        isMonitoringActive = true
        sessionState = .monitoring
        notifyStateChange()

        do {
            async let historicalSeed: Void = seedHistoricalHeartRateSamples(
                from: wakeUpTime.addingTimeInterval(-historicalSeedLookback),
                to: Date()
            )

            try await startWorkoutSession()
            startHeartRateQuery(from: Date())
            try await historicalSeed
            startWakeCheckTimer()
            checkForWakeTrigger()
            print("[SmartWakeSession] Monitoring started for schedule \(schedule.id)")
        } catch {
            failMonitoring("Failed to start session: \(error.localizedDescription)")
        }
    }

    func finishMonitoringAfterTrigger() {
        guard isMonitoringActive || sessionState == .triggered else { return }

        tearDownMonitoringSession()
        currentSchedule = nil
        currentScheduleID = nil
        wakeUpTime = nil
        windowStartTime = nil
        isMonitoringActive = false

        Task { [weak self] in
            await self?.endWorkoutSession()
            await MainActor.run {
                guard let self else { return }
                self.sessionState = .idle
                self.notifyStateChange()
                print("[SmartWakeSession] Monitoring finished after trigger")
            }
        }
    }

    func stopMonitoring() {
        tearDownMonitoringSession()
        stopHaptics()
        deferredLightRampTask?.cancel()
        deferredLightRampTask = nil
        lightRampTask?.cancel()
        lightRampTask = nil
        activeLocalRampTriggerID = nil
        activeTriggerID = nil
        activeTriggerSchedule = nil

        currentSchedule = nil
        currentScheduleID = nil
        wakeUpTime = nil
        windowStartTime = nil
        isMonitoringActive = false
        errorMessage = nil
        sessionState = .idle
        notifyStateChange()

        Task { [weak self] in
            await self?.endWorkoutSession()
        }

        print("[SmartWakeSession] Monitoring stopped")
    }

    private func failMonitoring(_ message: String) {
        tearDownMonitoringSession()
        stopHaptics()
        deferredLightRampTask?.cancel()
        deferredLightRampTask = nil
        lightRampTask?.cancel()
        lightRampTask = nil
        activeLocalRampTriggerID = nil

        currentSchedule = nil
        currentScheduleID = nil
        wakeUpTime = nil
        windowStartTime = nil
        isMonitoringActive = false
        errorMessage = message
        sessionState = .failed
        notifyStateChange()

        Task { [weak self] in
            await self?.endWorkoutSession()
        }
    }

    private func tearDownMonitoringSession() {
        wakeCheckTimer?.invalidate()
        wakeCheckTimer = nil

        if let query = heartRateQuery {
            healthStore.stop(query)
            heartRateQuery = nil
        }
    }

    // MARK: - Handoff

    func handleLightHandoff(_ payload: SmartWakeLightHandoffPayload) {
        guard payload.triggerID == activeTriggerID else {
            print("[SmartWakeSession] Ignoring handoff for stale trigger \(payload.triggerID)")
            return
        }

        didReceivePhoneHandoffAck = true
        handoffAckStatus = payload.phoneWillHandleLights
            ? "Phone accepted lights"
            : "Phone declined lights\(payload.reason.map { ": \($0)" } ?? "")"

        if payload.phoneWillHandleLights {
            guard activeLocalRampTriggerID == nil else {
                deferredLocalRampStatus = "Watch ramp already started before ack"
                return
            }

            deferredLightRampTask?.cancel()
            deferredLightRampTask = nil
            deferredLocalRampStatus = "Cancelled by phone handoff"
            print("[SmartWakeSession] Phone accepted light ownership for \(payload.triggerID)")
            return
        }

        deferredLightRampTask?.cancel()
        deferredLightRampTask = nil

        guard activeLocalRampTriggerID == nil,
              let schedule = activeTriggerSchedule else {
            return
        }

        deferredLocalRampStatus = "Starting immediately after phone decline"
        _ = startLocalLightRamp(
            for: schedule,
            triggerID: payload.triggerID,
            reason: "phone declined"
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
    }

    private func endWorkoutSession() async {
        workoutSession?.end()
        if let builder = workoutBuilder {
            try? await builder.endCollection(at: Date())
            _ = try? await builder.finishWorkout()
        }
        workoutSession = nil
        workoutBuilder = nil
    }

    // MARK: - Heart Rate Query

    private func seedHistoricalHeartRateSamples(from startDate: Date, to endDate: Date) async throws {
        let samples = try await fetchHistoricalHeartRateSamples(from: startDate, to: endDate)
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let mappedSamples = samples.map { sample in
            (date: sample.startDate, bpm: sample.quantity.doubleValue(for: bpmUnit))
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
                self.heuristicEngine.addHeartRateSample(bpm: bpm, date: sample.startDate)
            }

            self.checkForWakeTrigger()
        }
    }

    // MARK: - Wake Check

    private func startWakeCheckTimer() {
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

        if now >= wakeUpTime {
            if !heuristicEngine.hasTriggered {
                fireTrigger(schedule: schedule, confidence: 1.0)
            } else {
                finishMonitoringAfterTrigger()
            }
            return
        }

        if heuristicEngine.shouldTrigger(inWakeWindow: now >= windowStartTime, now: now) {
            fireTrigger(schedule: schedule, confidence: heuristicEngine.currentConfidence)
        }
    }

    private func fireTrigger(schedule: WatchScheduleSnapshot, confidence: Double) {
        let triggerDate = Date()
        let triggerID = UUID()

        heuristicEngine.markTriggered(at: triggerDate)
        activeTriggerID = triggerID
        activeTriggerSchedule = schedule
        didReceivePhoneHandoffAck = false
        handoffAckStatus = "Waiting for phone handoff"
        deferredLocalRampStatus = "Deferred watch ramp armed for +8s"

        sessionState = .triggered
        notifyStateChange()

        startHapticRamp()
        scheduleDeferredLocalLightRamp(for: schedule, triggerID: triggerID)

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

        print("[SmartWakeSession] Trigger fired \(triggerID) with confidence \(confidence)")
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
        startHapticRamp()
        #endif
    }

    @discardableResult
    func startTestLights(for schedule: WatchScheduleSnapshot) -> Bool {
        startLocalLightRamp(for: schedule, triggerID: nil, reason: "manual test")
    }

    // MARK: - HomeKit Lights

    private func scheduleDeferredLocalLightRamp(for schedule: WatchScheduleSnapshot, triggerID: UUID) {
        deferredLightRampTask?.cancel()
        deferredLightRampTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.watchLightHandoffDelay ?? 8))

            await MainActor.run {
                guard let self,
                      self.activeTriggerID == triggerID,
                      self.activeLocalRampTriggerID == nil else { return }

                self.deferredLocalRampStatus = "Watch ramp started after 8s timeout"
                _ = self.startLocalLightRamp(
                    for: schedule,
                    triggerID: triggerID,
                    reason: "handoff timeout"
                )
                self.deferredLightRampTask = nil
            }
        }
    }

    @discardableResult
    private func startLocalLightRamp(
        for schedule: WatchScheduleSnapshot,
        triggerID: UUID?,
        reason: String
    ) -> Bool {
        let identifiers = schedule.lightIdentifiers.compactMap(UUID.init(uuidString:))
        guard !identifiers.isEmpty else {
            deferredLocalRampStatus = "No light identifiers for watch fallback"
            print("[SmartWakeSession] No light identifiers available for '\(schedule.name)'")
            return false
        }

        activeLocalRampTriggerID = triggerID
        deferredLightRampTask?.cancel()
        deferredLightRampTask = nil
        lightRampTask?.cancel()
        lightRampTask = Task { [weak self] in
            await self?.runLocalLightRamp(
                for: schedule,
                identifiers: identifiers,
                reason: reason
            )
        }
        return true
    }

    private func runLocalLightRamp(
        for schedule: WatchScheduleSnapshot,
        identifiers: [UUID],
        reason: String
    ) async {
        await homeKitService.waitForReady()

        let rampDuration: TimeInterval = 60
        let stepInterval: TimeInterval = 5
        let stepCount = max(Int(rampDuration / stepInterval), 1)

        deferredLocalRampStatus = "Watch ramp running (\(reason))"
        print("[SmartWakeSession] Starting watch HomeKit ramp for '\(schedule.name)' (\(reason))")

        for step in 0...stepCount {
            if Task.isCancelled { return }

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

            do {
                try await lightController.applyToMultipleLights(
                    brightness: brightness,
                    hue: hsb.hue * 360.0,
                    saturation: hsb.saturation * 100.0,
                    powerOn: true,
                    skipColor: schedule.skipColorWrites,
                    identifiers: identifiers,
                    names: schedule.lightNames
                )
            } catch {
                print("[SmartWakeSession] Watch HomeKit write failed at step \(step): \(error)")
            }

            if step < stepCount {
                try? await Task.sleep(for: .seconds(stepInterval))
            }
        }

        do {
            try await lightController.applyToMultipleLights(
                brightness: schedule.targetBrightness,
                hue: schedule.endColorHue * 360.0,
                saturation: schedule.endColorSaturation * 100.0,
                powerOn: true,
                skipColor: schedule.skipColorWrites,
                identifiers: identifiers,
                names: schedule.lightNames
            )
        } catch {
            print("[SmartWakeSession] Watch HomeKit final write failed: \(error)")
        }
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

        print("[SmartWakeSession] Haptic ramp started: \(hapticPatternType.displayName), 60s via WKInterfaceDevice")
        #endif
    }

    private func stopHaptics() {
        hapticTimer?.invalidate()
        hapticTimer = nil
        hapticStartTime = nil
        lastHapticPlayTime = nil
        heartbeatPendingSecondBeat = false
    }

    #if os(watchOS)
    private func hapticTimerTick() {
        guard let startTime = hapticStartTime else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed >= hapticDuration {
            WKInterfaceDevice.current().play(.notification)
            stopHaptics()
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

    override init() {
        homeManager = HMHomeManager()
        super.init()
        homeManager.delegate = self
    }

    func waitForReady(timeout: TimeInterval = 10) async {
        if !homes.isEmpty { return }

        let deadline = Date().addingTimeInterval(timeout)
        while homes.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
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
            print("[WatchHomeKit] No accessory match for id=\(accessoryID.uuidString), name=\(accessoryName ?? "<nil>"). Available lights: \(available)")
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
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
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

private final class WatchLightController {
    private let homeKitService: WatchHomeKitService

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
                    guard powerOn else {
                        try await self.homeKitService.setPowerState(
                            false,
                            for: id,
                            named: accessoryName
                        )
                        return
                    }

                    if brightness <= 0 {
                        try? await self.homeKitService.setBrightness(
                            0,
                            for: id,
                            named: accessoryName
                        )
                        try await self.homeKitService.setPowerState(
                            false,
                            for: id,
                            named: accessoryName
                        )
                        return
                    }

                    try? await self.homeKitService.setBrightness(
                        brightness,
                        for: id,
                        named: accessoryName
                    )

                    if !skipColor {
                        do {
                            try await self.homeKitService.setHue(
                                hue,
                                for: id,
                                named: accessoryName
                            )
                            try await self.homeKitService.setSaturation(
                                saturation,
                                for: id,
                                named: accessoryName
                            )
                        } catch WatchHomeKitServiceError.characteristicNotFound {
                            // White-only bulbs do not expose hue/saturation.
                        }
                    }

                    try await self.homeKitService.setPowerState(
                        true,
                        for: id,
                        named: accessoryName
                    )
                    try await self.homeKitService.setBrightness(
                        brightness,
                        for: id,
                        named: accessoryName
                    )
                }
            }
            try await group.waitForAll()
        }
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
