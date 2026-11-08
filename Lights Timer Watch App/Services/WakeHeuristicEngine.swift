import Foundation

/// Both sources carry raw acceleration including gravity. Date is the sensor's
/// timestamp, never callback receipt time. Detector state is separate per source.
nonisolated struct SmartWakeLiveMotionSample: Sendable {
    let date: Date
    let x: Double
    let y: Double
    let z: Double
}

nonisolated struct SmartWakeHeuristicSnapshot: Sendable, Equatable {
    var phaseDescription: String = "Waiting"
    var historicalEventRate: Double = 9.5
    var dLimit: Double = 0
    var raLimit: Double = 0
    var verySensitive: Bool = false
    var historicalEventCount: Int = 0
    let latestHeartRate: Double?
    let baselineHeartRate: Double?
    let baselineReady: Bool
    let baselineSampleCount: Int
    let currentConfidence: Double
    let motionScore: Double
    let stillnessBreakScore: Double
    let heartRateArousal: Double
    let motionEnergy60s: Double
    let motionBurst30s: Int
    let rotationVariance60s: Double
    let postureShift300s: Double
    let hrDelta: Double?
    let hrSlope180s: Double?
    let hrTrend90s: Double
    let hrFreshnessSeconds: Double?
    let motionFreshnessSeconds: Double?
    let recorderBaselineReady: Bool
    let runtimeHeartRateBaseline: Double?
    let hrAvailableMode: Bool
    let hrModeConfidence: Double
    let motionModeConfidence: Double
    let sampleGaps: SmartWakeSampleGapSummary
    let scoreTraceSummary: SmartWakeScoreTraceSummary
    let diagnosticSummary: String

    /// Stable, compact diagnostics included in user-exportable watch logs.
    var movementLogDescription: String {
        String(format: "algorithm=recovered-watch-movement-v1 phase=%@ rate=%.6f/h dLimit=%.9f raLimit=%.9f sensitive=%@ events=%d",
               phaseDescription, historicalEventRate, dLimit, raLimit,
               verySensitive ? "true" : "false", historicalEventCount)
    }

    static let empty = SmartWakeHeuristicSnapshot(
        latestHeartRate: nil,
        baselineHeartRate: nil,
        baselineReady: false,
        baselineSampleCount: 0,
        currentConfidence: 0,
        motionScore: 0,
        stillnessBreakScore: 0,
        heartRateArousal: 0,
        motionEnergy60s: 0,
        motionBurst30s: 0,
        rotationVariance60s: 0,
        postureShift300s: 0,
        hrDelta: nil,
        hrSlope180s: nil,
        hrTrend90s: 0,
        hrFreshnessSeconds: nil,
        motionFreshnessSeconds: nil,
        recorderBaselineReady: false,
        runtimeHeartRateBaseline: nil,
        hrAvailableMode: false,
        hrModeConfidence: 0,
        motionModeConfidence: 0,
        sampleGaps: .empty,
        scoreTraceSummary: .empty,
        diagnosticSummary: "No Smart Wake data yet"
    )
}

nonisolated struct SmartWakeHeuristicDecision: Sendable {
    let shouldTrigger: Bool
    let confidence: Double
    let motionScore: Double
    let hrFreshnessSeconds: Double?
    let motionFreshnessSeconds: Double?
    let sensorProvenance: SmartWakeSensorProvenance
    let snapshot: SmartWakeHeuristicSnapshot
    let triggerReason: String?
}

/// Concurrency boundary around the exact core. HR is telemetry only. Timers do
/// not synthesize accelerometer notifications or re-evaluate old movements.
actor WakeHeuristicEngine {
    private var analyzer = RecoveredMovementAnalyzer()
    private var rules: RecoveredAlarmRules?
    private var wakePhaseEvent: RecoveredMovementEvent?
    private var latestMotionDate: Date?
    private var latestHRDate: Date?
    private var latestHR: Double?
    private var latestIntensity: Double = 0
    private var peakIntensity: Double = 0
    private var latestReason: RecoveredWakeReason?
    private var hasTriggered = false
    private var historyReady = false
    private var longestMotionGap: Double = 0
    private var motionGaps = 0
    private var longestHRGap: Double = 0
    private var hrGaps = 0
    private var recorderLag: Double?

    func configure(wakeWindowStart: Date, wakeUpTime: Date, armedAt: Date, monitoringStartedAt: Date) -> SmartWakeHeuristicSnapshot {
        reset()
        // RUNTIME.md: beginWakeupPhase records a session event before history.
        // It establishes effectiveEnd without counting as movement (ALARM.md).
        // Kind 0 is our non-motion lifecycle event; no vendor event is fabricated.
        wakePhaseEvent = RecoveredMovementEvent(time: monitoringStartedAt.timeIntervalSince1970, kind: 0, intensity: 0)
        rules = RecoveredAlarmRules(
            alarmTime: wakeUpTime.timeIntervalSince1970,
            windowSeconds: wakeUpTime.timeIntervalSince(wakeWindowStart),
            history: RecoveredMovementHistory(start: armedAt.timeIntervalSince1970, events: [wakePhaseEvent!])
        )
        return snapshot(at: min(Date(), wakeUpTime))
    }

    func ingestRecordedHistory(_ history: RecoveredMovementHistory, latestSample: Date?, evaluatedAt: Date) -> SmartWakeHeuristicSnapshot {
        // Calibration occurs on the sleepy -> armed transition, exactly once.
        // Subsequent history refreshes must not recalibrate an already armed rule.
        var sessionHistory = history
        if let wakePhaseEvent { sessionHistory.events.append(wakePhaseEvent) }
        rules?.history = sessionHistory
        historyReady = true
        recorderLag = latestSample.map { max(0, evaluatedAt.timeIntervalSince($0)) }
        return snapshot(at: evaluatedAt)
    }

    func ingestLiveMotionSample(_ sample: SmartWakeLiveMotionSample) -> SmartWakeHeuristicDecision {
        // Acquisition policy rejects duplicate/out-of-order callbacks before they
        // reach the parity core; no gap resets or resampling are introduced.
        guard sample.x.isFinite, sample.y.isFinite, sample.z.isFinite,
              sample.date.timeIntervalSince1970.isFinite,
              latestMotionDate.map({ sample.date > $0 }) ?? true else {
            return decision(at: sample.date, reason: nil)
        }
        if let previous = latestMotionDate {
            let gap = sample.date.timeIntervalSince(previous)
            longestMotionGap = max(longestMotionGap, gap)
            if gap > 2 { motionGaps += 1 }
        }
        latestMotionDate = sample.date
        let movement = analyzer.update(RecoveredMotionSample(
            time: sample.date.timeIntervalSince1970,
            acceleration: RecoveredAcceleration(x: sample.x, y: sample.y, z: sample.z)
        ))
        latestIntensity = movement.intensity
        peakIntensity = max(peakIntensity, latestIntensity)
        // Execution policy deliberately does not pass the vendor's five-minute
        // expiration reserve as an early deadline. Exact wake remains independent.
        let reason = hasTriggered ? nil : rules?.receive(movement, forceRuntime: false)
        if let reason { latestReason = reason }
        return decision(at: sample.date, reason: reason)
    }

    func ingestHeartRateSample(bpm: Double, at date: Date) -> SmartWakeHeuristicDecision {
        if bpm.isFinite, latestHRDate.map({ date > $0 }) ?? true {
            if let previous = latestHRDate {
                let gap = date.timeIntervalSince(previous)
                longestHRGap = max(longestHRGap, gap)
                if gap > 90 { hrGaps += 1 }
            }
            latestHRDate = date
            latestHR = bpm
        }
        return decision(at: date, reason: nil)
    }

    func evaluate(at date: Date) -> SmartWakeHeuristicDecision {
        decision(at: date, reason: nil)
    }

    func markTriggered(at _: Date) { hasTriggered = true }

    func makeOccurrenceSummary(
        scheduleID: UUID,
        scheduleName: String,
        armedAt: Date?,
        wakeWindowStart: Date,
        wakeUpTime: Date,
        triggerDate: Date?,
        triggerConfidence: Double?,
        motionScore: Double?,
        hrFreshnessSeconds: Double?,
        motionFreshnessSeconds: Double?,
        sensorProvenance: SmartWakeSensorProvenance?,
        fallbackReason: String?,
        createdAt: Date = Date()
    ) -> SmartWakeOccurrenceSummary {
        let snapshot = snapshot(at: triggerDate ?? min(Date(), wakeUpTime))
        return SmartWakeOccurrenceSummary(
            id: UUID(),
            scheduleID: scheduleID,
            scheduleName: scheduleName,
            wakeWindowStart: wakeWindowStart,
            wakeUpTime: wakeUpTime,
            armedAt: armedAt,
            triggerDate: triggerDate,
            triggerConfidence: triggerConfidence,
            motionScore: motionScore,
            hrFreshnessSeconds: hrFreshnessSeconds,
            motionFreshnessSeconds: motionFreshnessSeconds,
            sensorProvenance: sensorProvenance,
            scoreTraceSummary: snapshot.scoreTraceSummary,
            sampleGaps: snapshot.sampleGaps,
            fallbackReason: fallbackReason,
            createdAt: createdAt,
            movementTraceSummary: SmartWakeMovementTraceSummary(
                phaseDescription: snapshot.phaseDescription,
                historicalEventRate: snapshot.historicalEventRate,
                dLimit: snapshot.dLimit, raLimit: snapshot.raLimit,
                verySensitive: snapshot.verySensitive,
                historicalEventCount: snapshot.historicalEventCount
            )
        )
    }

    func reset() {
        analyzer = RecoveredMovementAnalyzer()
        rules = nil
        wakePhaseEvent = nil
        latestMotionDate = nil
        latestHRDate = nil
        latestHR = nil
        latestIntensity = 0
        peakIntensity = 0
        latestReason = nil
        hasTriggered = false
        historyReady = false
        longestMotionGap = 0
        motionGaps = 0
        longestHRGap = 0
        hrGaps = 0
        recorderLag = nil
    }

    private func decision(at date: Date, reason: RecoveredWakeReason?) -> SmartWakeHeuristicDecision {
        let value = snapshot(at: date)
        return SmartWakeHeuristicDecision(
            shouldTrigger: reason != nil && !hasTriggered,
            confidence: reason == nil ? 0 : 1, // Rule result, not a probability.
            motionScore: latestIntensity,
            hrFreshnessSeconds: value.hrFreshnessSeconds,
            motionFreshnessSeconds: value.motionFreshnessSeconds,
            sensorProvenance: SmartWakeSensorProvenance(
                usedLiveMotion: latestMotionDate != nil,
                usedRecordedMotionBaseline: (rules?.history.events.contains { $0.kind == 1 || $0.kind == 2 } ?? false),
                usedHeartRate: false, heartRateWasStale: false,
                triggerMode: .earlyMotionTrigger
            ),
            snapshot: value,
            triggerReason: reason.map { String(describing: $0) }
        )
    }

    private func snapshot(at date: Date) -> SmartWakeHeuristicSnapshot {
        let hrAge = latestHRDate.map { max(0, date.timeIntervalSince($0)) }
        let motionAge = latestMotionDate.map { max(0, date.timeIntervalSince($0)) }
        let rate = rules?.history.movementsPerHour() ?? 9.5
        let fast = rules?.filter.dLimit ?? 0
        let slow = rules?.filter.raLimit ?? 0
        let phase = rules.map { String(describing: $0.phase) } ?? "idle"
        var result = SmartWakeHeuristicSnapshot(
            latestHeartRate: latestHR, baselineHeartRate: nil, baselineReady: historyReady,
            baselineSampleCount: rules?.history.events.filter { $0.kind == 1 || $0.kind == 2 }.count ?? 0,
            currentConfidence: latestReason == nil ? 0 : 1,
            motionScore: latestIntensity, stillnessBreakScore: 0, heartRateArousal: 0,
            motionEnergy60s: latestIntensity, motionBurst30s: 0, rotationVariance60s: 0,
            postureShift300s: 0, hrDelta: nil, hrSlope180s: nil, hrTrend90s: 0,
            hrFreshnessSeconds: hrAge, motionFreshnessSeconds: motionAge,
            recorderBaselineReady: (rules?.history.events.contains { $0.kind == 1 || $0.kind == 2 } ?? false),
            runtimeHeartRateBaseline: nil, hrAvailableMode: false,
            hrModeConfidence: 0, motionModeConfidence: 0,
            sampleGaps: SmartWakeSampleGapSummary(
                longestHeartRateGapSeconds: longestHRGap,
                heartRateGapEventsOver90Seconds: hrGaps,
                longestMotionGapSeconds: longestMotionGap,
                motionGapEventsOver2Seconds: motionGaps,
                recorderBackfillLagSeconds: recorderLag
            ),
            scoreTraceSummary: SmartWakeScoreTraceSummary(
                peakCompositeConfidence: latestReason == nil ? 0 : 1,
                peakMotionScore: peakIntensity, peakStillnessBreakScore: 0, peakHeartRateArousal: 0,
                latestCompositeConfidence: latestReason == nil ? 0 : 1,
                latestMotionScore: latestIntensity, latestStillnessBreakScore: 0, latestHeartRateArousal: 0
            ),
            diagnosticSummary: String(format: "Movement %@ · %.2f events/h · D %.5f / R %.5f", phase, rate, fast, slow)
        )
        result.phaseDescription = phase
        result.historicalEventRate = rate
        result.dLimit = fast
        result.raLimit = slow
        result.verySensitive = rules?.sensitive ?? false
        result.historicalEventCount = rules?.history.events.filter { $0.kind == 1 || $0.kind == 2 }.count ?? 0
        return result
    }
}
