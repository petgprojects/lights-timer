import Foundation
import HealthKit

@Observable
final class SmartWakeSessionController: NSObject {
    let healthStore = HKHealthStore()
    let heuristicEngine = WakeHeuristicEngine()

    private(set) var sessionState: SmartWakeSessionState.State = .idle
    private(set) var currentScheduleID: UUID?
    private(set) var errorMessage: String?
    private(set) var isHealthKitAuthorized: Bool = false

    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var heartRateQuery: HKAnchoredObjectQuery?
    private var wakeCheckTimer: Timer?

    private var wakeUpTime: Date?
    private var windowStartTime: Date?

    var onTrigger: ((SmartWakeTriggerPayload) -> Void)?
    var onStateChange: ((SmartWakeSessionState) -> Void)?

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

    // MARK: - Session Lifecycle

    func startMonitoring(
        scheduleID: UUID,
        wakeUpTime: Date,
        windowMinutes: Int
    ) async {
        guard sessionState == .idle else { return }

        self.currentScheduleID = scheduleID
        self.wakeUpTime = wakeUpTime
        self.windowStartTime = wakeUpTime.addingTimeInterval(-Double(windowMinutes) * 60)

        heuristicEngine.reset()
        sessionState = .monitoring
        notifyStateChange()

        do {
            try await startWorkoutSession()
            startHeartRateQuery()
            startWakeCheckTimer()
            print("[SmartWakeSession] Monitoring started for schedule \(scheduleID)")
        } catch {
            sessionState = .failed
            errorMessage = "Failed to start session: \(error.localizedDescription)"
            notifyStateChange()
        }
    }

    func stopMonitoring() {
        wakeCheckTimer?.invalidate()
        wakeCheckTimer = nil

        if let query = heartRateQuery {
            healthStore.stop(query)
            heartRateQuery = nil
        }

        Task {
            await endWorkoutSession()
        }

        sessionState = .idle
        currentScheduleID = nil
        wakeUpTime = nil
        windowStartTime = nil
        notifyStateChange()
        print("[SmartWakeSession] Monitoring stopped")
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

        self.workoutSession = session
        self.workoutBuilder = builder

        session.startActivity(with: Date())
        try await builder.beginCollection(at: Date())
    }

    private func endWorkoutSession() async {
        workoutSession?.end()
        if let builder = workoutBuilder {
            try? await builder.endCollection(at: Date())
            try? await builder.finishWorkout()
        }
        workoutSession = nil
        workoutBuilder = nil
    }

    // MARK: - Heart Rate Query

    private func startHeartRateQuery() {
        let heartRateType = HKQuantityType(.heartRate)
        let now = Date()

        let query = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: HKQuery.predicateForSamples(withStart: now, end: nil),
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
        guard let samples = samples as? [HKQuantitySample] else { return }

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
            Task { @MainActor in
                self?.checkForWakeTrigger()
            }
        }
    }

    private func checkForWakeTrigger() {
        guard sessionState == .monitoring,
              let wakeUpTime,
              let windowStartTime,
              let scheduleID = currentScheduleID else { return }

        let now = Date()

        // Check if we're past the wake time (force stop)
        if now >= wakeUpTime {
            // Force fire if not already triggered
            if !heuristicEngine.hasTriggered {
                fireTrigger(scheduleID: scheduleID, confidence: 1.0)
            }
            stopMonitoring()
            return
        }

        // Check if we're in the wake window
        let inWindow = now >= windowStartTime

        if heuristicEngine.shouldTrigger(inWakeWindow: inWindow) {
            fireTrigger(
                scheduleID: scheduleID,
                confidence: heuristicEngine.currentConfidence
            )
        }
    }

    private func fireTrigger(scheduleID: UUID, confidence: Double) {
        heuristicEngine.markTriggered()
        sessionState = .triggered
        notifyStateChange()

        let latestHR = heuristicEngine.currentConfidence > 0 ? Double(Int(confidence * 100)) : nil

        let payload = SmartWakeTriggerPayload(
            scheduleID: scheduleID,
            triggerDate: Date(),
            confidence: confidence,
            heartRateAtTrigger: latestHR,
            motionLevel: nil
        )

        onTrigger?(payload)
        print("[SmartWakeSession] Trigger fired! Confidence: \(confidence)")
    }

    private func notifyStateChange() {
        let state = SmartWakeSessionState(
            state: sessionState,
            scheduleID: currentScheduleID,
            message: errorMessage
        )
        onStateChange?(state)
    }
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
            if toState == .ended {
                if self.sessionState == .monitoring {
                    self.sessionState = .failed
                    self.errorMessage = "Workout session ended unexpectedly"
                    self.notifyStateChange()
                }
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.sessionState = .failed
            self.errorMessage = error.localizedDescription
            self.notifyStateChange()
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
        // Heart rate data is handled by the anchored query
    }
}
