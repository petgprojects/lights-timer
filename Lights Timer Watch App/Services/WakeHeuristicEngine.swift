import Foundation

@Observable
final class WakeHeuristicEngine {
    private var heartRateSamples: [(date: Date, bpm: Double)] = []
    private var wakeWindowStart: Date?

    private(set) var latestHeartRate: Double?
    private(set) var baselineHeartRate: Double?
    private(set) var baselineReady = false
    private(set) var baselineSampleCount = 0
    private(set) var baselineFrozenAt: Date?
    private(set) var hasTriggered = false

    // Configuration
    let hrRiseThreshold: Double = 5.0
    let confidenceThreshold: Double = 0.6
    let cooldownInterval: TimeInterval = 300

    var currentConfidence: Double = 0
    var lastTriggerDate: Date?

    private let baselineLookback: TimeInterval = 3600
    private let baselineCutoffBeforeWindow: TimeInterval = 300
    private let minimumBaselineSamples = 8
    private let minimumBaselineSpan: TimeInterval = 900
    private let retainedHistoryWindow: TimeInterval = 7200

    // MARK: - Configuration

    func configure(wakeWindowStart: Date) {
        reset()
        self.wakeWindowStart = wakeWindowStart
    }

    // MARK: - Data Input

    func seedHeartRateSamples(_ samples: [(date: Date, bpm: Double)], referenceDate: Date = Date()) {
        guard !samples.isEmpty else { return }
        heartRateSamples.append(contentsOf: samples)
        heartRateSamples.sort { $0.date < $1.date }
        latestHeartRate = heartRateSamples.last?.bpm
        refreshMetrics(referenceDate: referenceDate)
    }

    func addHeartRateSample(bpm: Double, date: Date = Date()) {
        heartRateSamples.append((date: date, bpm: bpm))
        heartRateSamples.sort { $0.date < $1.date }
        latestHeartRate = heartRateSamples.last?.bpm
        refreshMetrics(referenceDate: date)
    }

    // MARK: - Heuristic

    private func refreshMetrics(referenceDate: Date) {
        pruneSamples(referenceDate: referenceDate)
        freezeBaselineIfNeeded(referenceDate: referenceDate)

        if baselineFrozenAt == nil {
            recomputeBaseline()
        }

        updateConfidence()
    }

    private func pruneSamples(referenceDate: Date) {
        let cutoff: Date
        if let wakeWindowStart {
            cutoff = wakeWindowStart.addingTimeInterval(-retainedHistoryWindow)
        } else {
            cutoff = referenceDate.addingTimeInterval(-retainedHistoryWindow)
        }
        heartRateSamples.removeAll { $0.date < cutoff }
    }

    private func freezeBaselineIfNeeded(referenceDate: Date) {
        guard baselineFrozenAt == nil,
              let wakeWindowStart,
              referenceDate >= wakeWindowStart else { return }

        recomputeBaseline()
        baselineFrozenAt = referenceDate
    }

    private func recomputeBaseline() {
        guard let wakeWindowStart else {
            baselineHeartRate = nil
            baselineReady = false
            baselineSampleCount = 0
            return
        }

        let baselineStart = wakeWindowStart.addingTimeInterval(-baselineLookback)
        let baselineEnd = wakeWindowStart.addingTimeInterval(-baselineCutoffBeforeWindow)
        let candidates = heartRateSamples
            .filter { sample in
                sample.date >= baselineStart && sample.date <= baselineEnd
            }
            .sorted { $0.date < $1.date }

        baselineSampleCount = candidates.count

        guard candidates.count >= minimumBaselineSamples,
              let firstDate = candidates.first?.date,
              let lastDate = candidates.last?.date,
              lastDate.timeIntervalSince(firstDate) >= minimumBaselineSpan else {
            baselineHeartRate = nil
            baselineReady = false
            return
        }

        baselineHeartRate = median(candidates.map(\.bpm))
        baselineReady = baselineHeartRate != nil
    }

    private func updateConfidence() {
        guard baselineReady,
              let baselineHeartRate,
              let latestHeartRate else {
            currentConfidence = 0
            return
        }

        // Heart rate rise component (70% weight)
        let hrDelta = latestHeartRate - baselineHeartRate
        let hrScore = min(max(hrDelta / hrRiseThreshold, 0), 1.0) * 0.7

        // HRV / variability component (30% weight)
        let recentSamples = heartRateSamples.suffix(6)
        let hrvScore: Double
        if recentSamples.count >= 3 {
            let values = recentSamples.map(\.bpm)
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.map { value in
                let delta = value - mean
                return delta * delta
            }.reduce(0, +) / Double(values.count)
            let stddev = variance.squareRoot()
            hrvScore = min(stddev / 5.0, 1.0) * 0.3
        } else {
            hrvScore = 0
        }

        currentConfidence = hrScore + hrvScore
    }

    // MARK: - Decision

    func shouldTrigger(inWakeWindow: Bool, now: Date = Date()) -> Bool {
        if inWakeWindow {
            freezeBaselineIfNeeded(referenceDate: now)
        }

        guard inWakeWindow, !hasTriggered, baselineReady else { return false }

        if let lastTriggerDate,
           now.timeIntervalSince(lastTriggerDate) < cooldownInterval {
            return false
        }

        return currentConfidence >= confidenceThreshold
    }

    func markTriggered(at date: Date = Date()) {
        hasTriggered = true
        lastTriggerDate = date
    }

    func reset() {
        heartRateSamples.removeAll()
        wakeWindowStart = nil
        latestHeartRate = nil
        baselineHeartRate = nil
        baselineReady = false
        baselineSampleCount = 0
        baselineFrozenAt = nil
        currentConfidence = 0
        hasTriggered = false
        lastTriggerDate = nil
    }

    // MARK: - Diagnostics

    var diagnosticSummary: String {
        let sampleCount = heartRateSamples.count
        let baseline = baselineHeartRate.map { String(format: "%.0f", $0) } ?? "--"
        let latest = latestHeartRate.map { String(format: "%.0f", $0) } ?? "--"
        let confidence = String(format: "%.0f%%", currentConfidence * 100)
        let ready = baselineReady ? "ready" : "waiting"
        return "Samples: \(sampleCount) | Baseline: \(baseline) (\(ready), \(baselineSampleCount)) | Latest: \(latest) | Confidence: \(confidence)"
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sortedValues = values.sorted()
        let middle = sortedValues.count / 2

        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[middle - 1] + sortedValues[middle]) / 2
        }

        return sortedValues[middle]
    }
}
