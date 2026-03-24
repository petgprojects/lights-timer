import Foundation

struct SmartWakeLiveMotionSample: Sendable {
    let date: Date
    let userAccelerationMagnitude: Double
    let rotationMagnitude: Double
    let gravityX: Double
    let gravityY: Double
    let gravityZ: Double
    let pitch: Double
    let roll: Double
    let yaw: Double
}

struct SmartWakeRecordedMotionBin: Sendable {
    let secondStart: Date
    let averageAccelerationMagnitude: Double
    let sampleCount: Int
}

struct SmartWakeHeuristicSnapshot: Sendable, Equatable {
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
    let hrFreshnessSeconds: Double?
    let motionFreshnessSeconds: Double?
    let recorderBaselineReady: Bool
    let sampleGaps: SmartWakeSampleGapSummary
    let scoreTraceSummary: SmartWakeScoreTraceSummary
    let diagnosticSummary: String

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
        hrFreshnessSeconds: nil,
        motionFreshnessSeconds: nil,
        recorderBaselineReady: false,
        sampleGaps: .empty,
        scoreTraceSummary: .empty,
        diagnosticSummary: "No Smart Wake data yet"
    )
}

struct SmartWakeHeuristicDecision: Sendable {
    let shouldTrigger: Bool
    let confidence: Double
    let motionScore: Double
    let hrFreshnessSeconds: Double?
    let motionFreshnessSeconds: Double?
    let sensorProvenance: SmartWakeSensorProvenance
    let snapshot: SmartWakeHeuristicSnapshot
    let triggerReason: String?
}

actor WakeHeuristicEngine {
    private struct HeartRateSample: Sendable {
        let date: Date
        let bpm: Double
    }

    private struct LiveMotionBin: Sendable {
        let secondStart: Date
        var energySum: Double = 0
        var sampleCount: Int = 0
        var burstCount: Int = 0
        var rotationSum: Double = 0
        var rotationSquaredSum: Double = 0
        var gravityXSum: Double = 0
        var gravityYSum: Double = 0
        var gravityZSum: Double = 0
        var pitchSum: Double = 0
        var rollSum: Double = 0
        var yawSum: Double = 0

        var averageEnergy: Double {
            guard sampleCount > 0 else { return 0 }
            return energySum / Double(sampleCount)
        }

        var rotationVariance: Double {
            guard sampleCount > 0 else { return 0 }
            let mean = rotationSum / Double(sampleCount)
            let secondMoment = rotationSquaredSum / Double(sampleCount)
            return max(0, secondMoment - (mean * mean))
        }

        var averageGravity: (Double, Double, Double)? {
            guard sampleCount > 0 else { return nil }
            let count = Double(sampleCount)
            return (gravityXSum / count, gravityYSum / count, gravityZSum / count)
        }

        var averageAttitude: (Double, Double, Double)? {
            guard sampleCount > 0 else { return nil }
            let count = Double(sampleCount)
            return (pitchSum / count, rollSum / count, yawSum / count)
        }
    }

    private struct ScoreTrace {
        var peakCompositeConfidence: Double = 0
        var peakMotionScore: Double = 0
        var peakStillnessBreakScore: Double = 0
        var peakHeartRateArousal: Double = 0
        var latestCompositeConfidence: Double = 0
        var latestMotionScore: Double = 0
        var latestStillnessBreakScore: Double = 0
        var latestHeartRateArousal: Double = 0

        mutating func record(
            compositeConfidence: Double,
            motionScore: Double,
            stillnessBreakScore: Double,
            heartRateArousal: Double
        ) {
            peakCompositeConfidence = max(peakCompositeConfidence, compositeConfidence)
            peakMotionScore = max(peakMotionScore, motionScore)
            peakStillnessBreakScore = max(peakStillnessBreakScore, stillnessBreakScore)
            peakHeartRateArousal = max(peakHeartRateArousal, heartRateArousal)
            latestCompositeConfidence = compositeConfidence
            latestMotionScore = motionScore
            latestStillnessBreakScore = stillnessBreakScore
            latestHeartRateArousal = heartRateArousal
        }

        var summary: SmartWakeScoreTraceSummary {
            SmartWakeScoreTraceSummary(
                peakCompositeConfidence: peakCompositeConfidence,
                peakMotionScore: peakMotionScore,
                peakStillnessBreakScore: peakStillnessBreakScore,
                peakHeartRateArousal: peakHeartRateArousal,
                latestCompositeConfidence: latestCompositeConfidence,
                latestMotionScore: latestMotionScore,
                latestStillnessBreakScore: latestStillnessBreakScore,
                latestHeartRateArousal: latestHeartRateArousal
            )
        }
    }

    private let retainedWindow: TimeInterval = 4 * 60 * 60
    private let motionBurstSeparation: TimeInterval = 0.7
    private let motionBurstMagnitudeThreshold: Double = 0.16
    private let motionEnergyReference: Double = 0.045
    private let rotationVarianceReference: Double = 0.03
    private let postureShiftReference: Double = 0.55
    private let heartRateDeltaReference: Double = 9.0
    private let heartRateSlopeReference: Double = 2.4
    private let wakeWindowEarlyPhase: TimeInterval = 5 * 60
    private let wakeWindowFinalPhase: TimeInterval = 10 * 60
    private let wakeWindowMotionOnlyPhase: TimeInterval = 3 * 60

    private var wakeWindowStart: Date?
    private var wakeUpTime: Date?
    private var calibrationProfile: SmartWakeCalibrationProfile = .default
    private var liveMotionBins: [LiveMotionBin] = []
    private var liveMotionBinKeys = Set<Int64>()
    private var recordedMotionBins: [SmartWakeRecordedMotionBin] = []
    private var recordedMotionBinKeys = Set<Int64>()
    private var heartRateSamples: [HeartRateSample] = []
    private var latestMotionSampleDate: Date?
    private var latestHeartRateSampleDate: Date?
    private var lastMotionBurstDate: Date?
    private var hasTriggered = false
    private var scoreTrace = ScoreTrace()
    private var longestHeartRateGapSeconds: Double = 0
    private var heartRateGapEventsOver90Seconds = 0
    private var longestMotionGapSeconds: Double = 0
    private var motionGapEventsOver2Seconds = 0
    private var recorderBackfillLagSeconds: Double?

    func configure(
        wakeWindowStart: Date,
        wakeUpTime: Date,
        calibrationProfile: SmartWakeCalibrationProfile
    ) -> SmartWakeHeuristicSnapshot {
        reset()
        self.wakeWindowStart = wakeWindowStart
        self.wakeUpTime = wakeUpTime
        self.calibrationProfile = calibrationProfile.clamped()
        return snapshot(at: min(Date(), wakeUpTime))
    }

    func ingestRecordedMotionBins(
        _ bins: [SmartWakeRecordedMotionBin],
        evaluatedAt: Date
    ) -> SmartWakeHeuristicSnapshot {
        guard !bins.isEmpty else { return snapshot(at: evaluatedAt) }

        for bin in bins.sorted(by: { $0.secondStart < $1.secondStart }) {
            let key = secondKey(for: bin.secondStart)
            guard recordedMotionBinKeys.insert(key).inserted else { continue }
            recordedMotionBins.append(bin)
        }
        recordedMotionBins.sort { $0.secondStart < $1.secondStart }
        if let latestRecorded = recordedMotionBins.last?.secondStart {
            recorderBackfillLagSeconds = max(0, evaluatedAt.timeIntervalSince(latestRecorded))
        }

        pruneState(referenceDate: evaluatedAt)
        return snapshot(at: evaluatedAt)
    }

    func ingestLiveMotionSample(_ sample: SmartWakeLiveMotionSample) -> SmartWakeHeuristicDecision {
        if let latestMotionSampleDate {
            let gap = sample.date.timeIntervalSince(latestMotionSampleDate)
            if gap > 0 {
                longestMotionGapSeconds = max(longestMotionGapSeconds, gap)
                if gap > 2 {
                    motionGapEventsOver2Seconds += 1
                }
            }
        }
        latestMotionSampleDate = sample.date

        let isBurst: Bool
        if sample.userAccelerationMagnitude >= motionBurstMagnitudeThreshold {
            if let lastMotionBurstDate,
               sample.date.timeIntervalSince(lastMotionBurstDate) <= motionBurstSeparation {
                isBurst = false
            } else {
                isBurst = true
                lastMotionBurstDate = sample.date
            }
        } else {
            isBurst = false
        }

        let secondStart = flooredSecond(for: sample.date)
        let key = secondKey(for: secondStart)
        if let lastIndex = liveMotionBins.indices.last, liveMotionBinKeys.contains(key),
           liveMotionBins[lastIndex].secondStart == secondStart {
            updateLiveMotionBin(
                at: lastIndex,
                sample: sample,
                isBurst: isBurst
            )
        } else if let existingIndex = liveMotionBins.firstIndex(where: { $0.secondStart == secondStart }) {
            updateLiveMotionBin(
                at: existingIndex,
                sample: sample,
                isBurst: isBurst
            )
        } else {
            liveMotionBinKeys.insert(key)
            liveMotionBins.append(
                makeLiveMotionBin(
                    secondStart: secondStart,
                    sample: sample,
                    isBurst: isBurst
                )
            )
        }

        pruneState(referenceDate: sample.date)
        return makeDecision(now: sample.date)
    }

    func ingestHeartRateSample(bpm: Double, at date: Date) -> SmartWakeHeuristicDecision {
        if let latestHeartRateSampleDate {
            let gap = date.timeIntervalSince(latestHeartRateSampleDate)
            if gap > 0 {
                longestHeartRateGapSeconds = max(longestHeartRateGapSeconds, gap)
                if gap > 90 {
                    heartRateGapEventsOver90Seconds += 1
                }
            }
        }
        latestHeartRateSampleDate = date
        heartRateSamples.append(HeartRateSample(date: date, bpm: bpm))
        heartRateSamples.sort { $0.date < $1.date }
        pruneState(referenceDate: date)
        return makeDecision(now: date)
    }

    func evaluate(at date: Date) -> SmartWakeHeuristicDecision {
        pruneState(referenceDate: date)
        return makeDecision(now: date)
    }

    func markTriggered(at _: Date) {
        hasTriggered = true
    }

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
            createdAt: createdAt
        )
    }

    func reset() {
        wakeWindowStart = nil
        wakeUpTime = nil
        calibrationProfile = .default
        liveMotionBins.removeAll()
        liveMotionBinKeys.removeAll()
        recordedMotionBins.removeAll()
        recordedMotionBinKeys.removeAll()
        heartRateSamples.removeAll()
        latestMotionSampleDate = nil
        latestHeartRateSampleDate = nil
        lastMotionBurstDate = nil
        hasTriggered = false
        scoreTrace = ScoreTrace()
        longestHeartRateGapSeconds = 0
        heartRateGapEventsOver90Seconds = 0
        longestMotionGapSeconds = 0
        motionGapEventsOver2Seconds = 0
        recorderBackfillLagSeconds = nil
    }

    private func makeDecision(now: Date) -> SmartWakeHeuristicDecision {
        let currentSnapshot = snapshot(at: now)
        let hrFreshnessSeconds = currentSnapshot.hrFreshnessSeconds
        let motionFreshnessSeconds = currentSnapshot.motionFreshnessSeconds
        let sensorProvenance = SmartWakeSensorProvenance(
            usedLiveMotion: latestMotionSampleDate != nil,
            usedRecordedMotionBaseline: currentSnapshot.recorderBaselineReady,
            usedHeartRate: latestHeartRateSampleDate != nil,
            heartRateWasStale: (hrFreshnessSeconds ?? .infinity) > 90,
            triggerMode: .earlyMotionTrigger
        )

        guard !hasTriggered,
              let wakeWindowStart,
              let wakeUpTime,
              now >= wakeWindowStart,
              now < wakeUpTime else {
            return SmartWakeHeuristicDecision(
                shouldTrigger: false,
                confidence: currentSnapshot.currentConfidence,
                motionScore: currentSnapshot.motionScore,
                hrFreshnessSeconds: hrFreshnessSeconds,
                motionFreshnessSeconds: motionFreshnessSeconds,
                sensorProvenance: sensorProvenance,
                snapshot: currentSnapshot,
                triggerReason: nil
            )
        }

        let threshold = triggerThreshold(now: now)
        let hrIsStale = (hrFreshnessSeconds ?? .infinity) > 90
        let strongMotionOnlyWindow = wakeUpTime.timeIntervalSince(now) <= wakeWindowMotionOnlyPhase
            && hrIsStale
            && currentSnapshot.motionScore >= calibrationProfile.strongMotionScore
        let hasMotionEvidence = currentSnapshot.motionScore >= calibrationProfile.minimumMotionScore
        let shouldTrigger = strongMotionOnlyWindow
            || (hasMotionEvidence && currentSnapshot.currentConfidence >= threshold)

        return SmartWakeHeuristicDecision(
            shouldTrigger: shouldTrigger,
            confidence: currentSnapshot.currentConfidence,
            motionScore: currentSnapshot.motionScore,
            hrFreshnessSeconds: hrFreshnessSeconds,
            motionFreshnessSeconds: motionFreshnessSeconds,
            sensorProvenance: sensorProvenance,
            snapshot: currentSnapshot,
            triggerReason: triggerReason(
                shouldTrigger: shouldTrigger,
                strongMotionOnlyWindow: strongMotionOnlyWindow,
                threshold: threshold
            )
        )
    }

    private func triggerReason(
        shouldTrigger: Bool,
        strongMotionOnlyWindow: Bool,
        threshold: Double
    ) -> String? {
        guard shouldTrigger else { return nil }
        if strongMotionOnlyWindow {
            return "Final 3 minutes: strong motion-only evidence with stale HR"
        }
        return String(format: "Composite confidence crossed %.2f", threshold)
    }

    private func snapshot(at now: Date) -> SmartWakeHeuristicSnapshot {
        let baselineHeartRate = calibrationProfile.sleepHeartRateBaselineBPM
        let baselineReady = wakeWindowStart != nil && wakeUpTime != nil
        let live60s = liveBins(inLast: 60, now: now)
        let live30s = liveBins(inLast: 30, now: now)
        let live90s = liveBins(inLast: 90, now: now)
        let prior5m = liveBins(inRangeFrom: 30, to: 300, now: now)
        let current30s = liveBins(inLast: 30, now: now)
        let recorded90m = recordedBins(inLast: 90 * 60, now: now)
        let recentHRSamples = heartRateSamples.filter {
            now.timeIntervalSince($0.date) <= retainedWindow
        }

        let motionEnergy60s = weightedAverageEnergy(live60s)
        let motionBurst30s = live30s.reduce(0) { $0 + $1.burstCount }
        let rotationVariance60s = combinedRotationVariance(live60s)
        let postureShift300s = postureShiftScore(currentBins: current30s, priorBins: prior5m)
        let current90sEnergy = weightedAverageEnergy(live90s)
        let recordedBaseline = median(recorded90m.map(\.averageAccelerationMagnitude))
        let recorderBaselineReady = recordedBaseline != nil
        let stillnessBreakScore = stillnessBreakScore(
            currentEnergy90s: current90sEnergy,
            recordedBaseline90m: recordedBaseline
        )
        let motionFreshnessSeconds = latestMotionSampleDate.map { max(0, now.timeIntervalSince($0)) }
        let motionFreshnessPenalty = freshnessPenalty(
            freshnessSeconds: motionFreshnessSeconds,
            grace: 2,
            fullPenaltyAt: 8
        )

        let energyScore = normalizedScore(motionEnergy60s, reference: motionEnergyReference)
        let burstScore = normalizedScore(Double(motionBurst30s), reference: 10)
        let rotationScore = normalizedScore(rotationVariance60s, reference: rotationVarianceReference)
        let postureScore = normalizedScore(postureShift300s, reference: postureShiftReference)
        let motionArousal = clamp(
            0.35 * energyScore
                + 0.25 * burstScore
                + 0.20 * rotationScore
                + 0.20 * postureScore
                - (motionFreshnessPenalty * 0.35)
        )
        let motionScore = clamp(
            0.75 * motionArousal + 0.25 * stillnessBreakScore - (motionFreshnessPenalty * 0.15)
        )

        let latestHeartRate = recentHRSamples.last?.bpm
        let hrFreshnessSeconds = recentHRSamples.last.map { max(0, now.timeIntervalSince($0.date)) }
        let hrFreshnessPenalty = freshnessPenalty(
            freshnessSeconds: hrFreshnessSeconds,
            grace: 90,
            fullPenaltyAt: 240
        )
        let hrDelta = latestHeartRate.map { $0 - baselineHeartRate }
        let deltaScore = normalizedScore(max(hrDelta ?? 0, 0), reference: heartRateDeltaReference)
        let hrSlope180s = heartRateSlope(last: 180, now: now)
        let slopeScore = normalizedScore(max(hrSlope180s ?? 0, 0), reference: heartRateSlopeReference)
        let heartRateArousal = clamp(
            ((0.65 * deltaScore) + (0.35 * slopeScore)) * calibrationProfile.hrWeightScale
                - (hrFreshnessPenalty * 0.40)
        )

        let proximityPrior = proximityPrior(now: now)
        let currentConfidence = clamp(
            0.55 * motionArousal
                + 0.20 * stillnessBreakScore
                + 0.20 * heartRateArousal
                + 0.05 * proximityPrior
        )

        var nextScoreTrace = scoreTrace
        nextScoreTrace.record(
            compositeConfidence: currentConfidence,
            motionScore: motionScore,
            stillnessBreakScore: stillnessBreakScore,
            heartRateArousal: heartRateArousal
        )
        scoreTrace = nextScoreTrace

        return SmartWakeHeuristicSnapshot(
            latestHeartRate: latestHeartRate,
            baselineHeartRate: baselineReady ? baselineHeartRate : nil,
            baselineReady: baselineReady,
            baselineSampleCount: calibrationProfile.nightsConsidered,
            currentConfidence: currentConfidence,
            motionScore: motionScore,
            stillnessBreakScore: stillnessBreakScore,
            heartRateArousal: heartRateArousal,
            motionEnergy60s: motionEnergy60s,
            motionBurst30s: motionBurst30s,
            rotationVariance60s: rotationVariance60s,
            postureShift300s: postureShift300s,
            hrDelta: hrDelta,
            hrSlope180s: hrSlope180s,
            hrFreshnessSeconds: hrFreshnessSeconds,
            motionFreshnessSeconds: motionFreshnessSeconds,
            recorderBaselineReady: recorderBaselineReady,
            sampleGaps: SmartWakeSampleGapSummary(
                longestHeartRateGapSeconds: longestHeartRateGapSeconds,
                heartRateGapEventsOver90Seconds: heartRateGapEventsOver90Seconds,
                longestMotionGapSeconds: longestMotionGapSeconds,
                motionGapEventsOver2Seconds: motionGapEventsOver2Seconds,
                recorderBackfillLagSeconds: recorderBackfillLagSeconds
            ),
            scoreTraceSummary: nextScoreTrace.summary,
            diagnosticSummary: diagnosticSummary(
                confidence: currentConfidence,
                motionScore: motionScore,
                stillnessBreakScore: stillnessBreakScore,
                heartRateArousal: heartRateArousal,
                hrFreshnessSeconds: hrFreshnessSeconds,
                motionFreshnessSeconds: motionFreshnessSeconds
            )
        )
    }

    private func updateLiveMotionBin(
        at index: Int,
        sample: SmartWakeLiveMotionSample,
        isBurst: Bool
    ) {
        liveMotionBins[index].energySum += sample.userAccelerationMagnitude
        liveMotionBins[index].sampleCount += 1
        liveMotionBins[index].burstCount += isBurst ? 1 : 0
        liveMotionBins[index].rotationSum += sample.rotationMagnitude
        liveMotionBins[index].rotationSquaredSum += sample.rotationMagnitude * sample.rotationMagnitude
        liveMotionBins[index].gravityXSum += sample.gravityX
        liveMotionBins[index].gravityYSum += sample.gravityY
        liveMotionBins[index].gravityZSum += sample.gravityZ
        liveMotionBins[index].pitchSum += sample.pitch
        liveMotionBins[index].rollSum += sample.roll
        liveMotionBins[index].yawSum += sample.yaw
    }

    private func makeLiveMotionBin(
        secondStart: Date,
        sample: SmartWakeLiveMotionSample,
        isBurst: Bool
    ) -> LiveMotionBin {
        var bin = LiveMotionBin(secondStart: secondStart)
        bin.energySum = sample.userAccelerationMagnitude
        bin.sampleCount = 1
        bin.burstCount = isBurst ? 1 : 0
        bin.rotationSum = sample.rotationMagnitude
        bin.rotationSquaredSum = sample.rotationMagnitude * sample.rotationMagnitude
        bin.gravityXSum = sample.gravityX
        bin.gravityYSum = sample.gravityY
        bin.gravityZSum = sample.gravityZ
        bin.pitchSum = sample.pitch
        bin.rollSum = sample.roll
        bin.yawSum = sample.yaw
        return bin
    }

    private func pruneState(referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-retainedWindow)
        liveMotionBins.removeAll { $0.secondStart < cutoff }
        liveMotionBinKeys = Set(liveMotionBins.map { secondKey(for: $0.secondStart) })
        recordedMotionBins.removeAll { $0.secondStart < cutoff }
        recordedMotionBinKeys = Set(recordedMotionBins.map { secondKey(for: $0.secondStart) })
        heartRateSamples.removeAll { $0.date < cutoff }
    }

    private func liveBins(inLast seconds: TimeInterval, now: Date) -> [LiveMotionBin] {
        let cutoff = now.addingTimeInterval(-seconds)
        return liveMotionBins.filter { $0.secondStart >= cutoff && $0.secondStart <= now }
    }

    private func liveBins(
        inRangeFrom recentSeconds: TimeInterval,
        to earlierSeconds: TimeInterval,
        now: Date
    ) -> [LiveMotionBin] {
        let latestCutoff = now.addingTimeInterval(-recentSeconds)
        let earliestCutoff = now.addingTimeInterval(-earlierSeconds)
        return liveMotionBins.filter {
            $0.secondStart >= earliestCutoff && $0.secondStart < latestCutoff
        }
    }

    private func recordedBins(inLast seconds: TimeInterval, now: Date) -> [SmartWakeRecordedMotionBin] {
        let cutoff = now.addingTimeInterval(-seconds)
        return recordedMotionBins.filter { $0.secondStart >= cutoff && $0.secondStart <= now }
    }

    private func weightedAverageEnergy(_ bins: [LiveMotionBin]) -> Double {
        let totalSamples = bins.reduce(0) { $0 + $1.sampleCount }
        guard totalSamples > 0 else { return 0 }
        let totalEnergy = bins.reduce(0.0) { $0 + $1.energySum }
        return totalEnergy / Double(totalSamples)
    }

    private func combinedRotationVariance(_ bins: [LiveMotionBin]) -> Double {
        let totalSamples = bins.reduce(0) { $0 + $1.sampleCount }
        guard totalSamples > 0 else { return 0 }
        let totalRotation = bins.reduce(0.0) { $0 + $1.rotationSum }
        let totalRotationSquared = bins.reduce(0.0) { $0 + $1.rotationSquaredSum }
        let mean = totalRotation / Double(totalSamples)
        let secondMoment = totalRotationSquared / Double(totalSamples)
        return max(0, secondMoment - (mean * mean))
    }

    private func postureShiftScore(
        currentBins: [LiveMotionBin],
        priorBins: [LiveMotionBin]
    ) -> Double {
        guard let currentGravity = averageGravity(currentBins),
              let priorGravity = averageGravity(priorBins),
              let currentAttitude = averageAttitude(currentBins),
              let priorAttitude = averageAttitude(priorBins) else {
            return 0
        }

        let gravityAngle = angleBetween(currentGravity, priorGravity) / .pi
        let pitchDelta = abs(currentAttitude.0 - priorAttitude.0) / .pi
        let rollDelta = abs(currentAttitude.1 - priorAttitude.1) / .pi
        let yawDelta = abs(currentAttitude.2 - priorAttitude.2) / .pi
        let attitudeDelta = clamp((pitchDelta + rollDelta + yawDelta) / 3)

        return clamp((0.7 * gravityAngle) + (0.3 * attitudeDelta))
    }

    private func averageGravity(_ bins: [LiveMotionBin]) -> (Double, Double, Double)? {
        let vectors = bins.compactMap(\.averageGravity)
        guard !vectors.isEmpty else { return nil }
        let count = Double(vectors.count)
        return (
            vectors.reduce(0) { $0 + $1.0 } / count,
            vectors.reduce(0) { $0 + $1.1 } / count,
            vectors.reduce(0) { $0 + $1.2 } / count
        )
    }

    private func averageAttitude(_ bins: [LiveMotionBin]) -> (Double, Double, Double)? {
        let values = bins.compactMap(\.averageAttitude)
        guard !values.isEmpty else { return nil }
        let count = Double(values.count)
        return (
            values.reduce(0) { $0 + $1.0 } / count,
            values.reduce(0) { $0 + $1.1 } / count,
            values.reduce(0) { $0 + $1.2 } / count
        )
    }

    private func stillnessBreakScore(
        currentEnergy90s: Double,
        recordedBaseline90m: Double?
    ) -> Double {
        guard let recordedBaseline90m, recordedBaseline90m > 0 else { return 0 }
        let ratio = currentEnergy90s / recordedBaseline90m
        let requiredRatio = calibrationProfile.stillnessMultiplier
        return clamp((ratio - 1) / max(requiredRatio - 1, 1))
    }

    private func heartRateSlope(last seconds: TimeInterval, now: Date) -> Double? {
        let samples = heartRateSamples.filter { now.timeIntervalSince($0.date) <= seconds }
        guard samples.count >= 2, let origin = samples.first?.date else { return nil }

        var totalWeight = 0.0
        var sumX = 0.0
        var sumY = 0.0
        var sumXX = 0.0
        var sumXY = 0.0

        for sample in samples {
            let minutes = sample.date.timeIntervalSince(origin) / 60.0
            let recencyWeight = 1.0 + max(0, sample.date.timeIntervalSince(now.addingTimeInterval(-seconds))) / seconds
            totalWeight += recencyWeight
            sumX += recencyWeight * minutes
            sumY += recencyWeight * sample.bpm
            sumXX += recencyWeight * minutes * minutes
            sumXY += recencyWeight * minutes * sample.bpm
        }

        let denominator = (totalWeight * sumXX) - (sumX * sumX)
        guard denominator != 0 else { return nil }
        return ((totalWeight * sumXY) - (sumX * sumY)) / denominator
    }

    private func proximityPrior(now: Date) -> Double {
        guard let wakeWindowStart, let wakeUpTime else { return 0 }
        let totalWindow = max(wakeUpTime.timeIntervalSince(wakeWindowStart), 1)
        let elapsed = now.timeIntervalSince(wakeWindowStart)
        return clamp(pow(max(0, elapsed) / totalWindow, 1.15))
    }

    private func triggerThreshold(now: Date) -> Double {
        guard let wakeWindowStart, let wakeUpTime else { return 1.0 }

        let elapsed = now.timeIntervalSince(wakeWindowStart)
        let timeUntilWake = wakeUpTime.timeIntervalSince(now)
        var threshold = 0.72 + calibrationProfile.motionTriggerThresholdOffset

        if elapsed < wakeWindowEarlyPhase {
            threshold += calibrationProfile.earlyWindowThresholdOffset
        }
        if timeUntilWake <= wakeWindowFinalPhase {
            threshold += calibrationProfile.finalWindowThresholdOffset
        }

        return clamp(threshold, lower: 0.55, upper: 0.95)
    }

    private func freshnessPenalty(
        freshnessSeconds: Double?,
        grace: Double,
        fullPenaltyAt: Double
    ) -> Double {
        guard let freshnessSeconds else { return 1.0 }
        guard freshnessSeconds > grace else { return 0 }
        return clamp((freshnessSeconds - grace) / max(fullPenaltyAt - grace, 1))
    }

    private func diagnosticSummary(
        confidence: Double,
        motionScore: Double,
        stillnessBreakScore: Double,
        heartRateArousal: Double,
        hrFreshnessSeconds: Double?,
        motionFreshnessSeconds: Double?
    ) -> String {
        let hrGap = hrFreshnessSeconds.map { String(format: "%.0fs", $0) } ?? "--"
        let motionGap = motionFreshnessSeconds.map { String(format: "%.1fs", $0) } ?? "--"
        return "Conf \(Int((confidence * 100).rounded()))% | Motion \(format(motionScore)) | Still \(format(stillnessBreakScore)) | HR \(format(heartRateArousal)) | HR gap \(hrGap) | Motion gap \(motionGap)"
    }

    private func normalizedScore(_ value: Double, reference: Double) -> Double {
        guard reference > 0 else { return 0 }
        return clamp(value / reference)
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func angleBetween(
        _ lhs: (Double, Double, Double),
        _ rhs: (Double, Double, Double)
    ) -> Double {
        let lhsMagnitude = sqrt((lhs.0 * lhs.0) + (lhs.1 * lhs.1) + (lhs.2 * lhs.2))
        let rhsMagnitude = sqrt((rhs.0 * rhs.0) + (rhs.1 * rhs.1) + (rhs.2 * rhs.2))
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        let dot = (lhs.0 * rhs.0) + (lhs.1 * rhs.1) + (lhs.2 * rhs.2)
        let cosine = max(-1.0, min(1.0, dot / (lhsMagnitude * rhsMagnitude)))
        return acos(cosine)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func secondKey(for date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    private func flooredSecond(for date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval(secondKey(for: date)))
    }

    private func clamp(
        _ value: Double,
        lower: Double = 0,
        upper: Double = 1
    ) -> Double {
        min(max(value, lower), upper)
    }
}
