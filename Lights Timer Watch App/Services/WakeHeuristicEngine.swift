import Foundation

@Observable
final class WakeHeuristicEngine {
    private var heartRateSamples: [(date: Date, bpm: Double)] = []
    private var baselineHR: Double = 0
    private(set) var hasTriggered = false

    // Configuration
    let hrRiseThreshold: Double = 5.0
    let confidenceThreshold: Double = 0.6
    let cooldownInterval: TimeInterval = 300

    var currentConfidence: Double = 0
    var lastTriggerDate: Date?

    // MARK: - Data Input

    func addHeartRateSample(bpm: Double, date: Date = Date()) {
        heartRateSamples.append((date: date, bpm: bpm))

        // Keep last 30 min of samples
        let cutoff = date.addingTimeInterval(-1800)
        heartRateSamples.removeAll { $0.date < cutoff }

        updateBaseline()
        updateConfidence(currentBPM: bpm)
    }

    // MARK: - Heuristic

    private func updateBaseline() {
        // Baseline = average of samples older than 5 minutes (deep sleep baseline)
        let fiveMinAgo = Date().addingTimeInterval(-300)
        let baselineSamples = heartRateSamples.filter { $0.date < fiveMinAgo }
        guard !baselineSamples.isEmpty else { return }
        baselineHR = baselineSamples.map(\.bpm).reduce(0, +) / Double(baselineSamples.count)
    }

    private func updateConfidence(currentBPM: Double) {
        guard baselineHR > 0 else {
            currentConfidence = 0
            return
        }

        // Heart rate rise component (70% weight)
        let hrDelta = currentBPM - baselineHR
        let hrScore = min(max(hrDelta / hrRiseThreshold, 0), 1.0) * 0.7

        // HRV / variability component (30% weight)
        // Higher short-term variability suggests lighter sleep
        let recentSamples = heartRateSamples.suffix(6)
        let hrvScore: Double
        if recentSamples.count >= 3 {
            let values = recentSamples.map(\.bpm)
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
            let stddev = variance.squareRoot()
            hrvScore = min(stddev / 5.0, 1.0) * 0.3
        } else {
            hrvScore = 0
        }

        currentConfidence = hrScore + hrvScore
    }

    // MARK: - Decision

    func shouldTrigger(inWakeWindow: Bool) -> Bool {
        guard inWakeWindow, !hasTriggered else { return false }

        if let lastTrigger = lastTriggerDate,
           Date().timeIntervalSince(lastTrigger) < cooldownInterval {
            return false
        }

        return currentConfidence >= confidenceThreshold
    }

    func markTriggered() {
        hasTriggered = true
        lastTriggerDate = Date()
    }

    func reset() {
        heartRateSamples.removeAll()
        baselineHR = 0
        currentConfidence = 0
        hasTriggered = false
        lastTriggerDate = nil
    }

    // MARK: - Diagnostics

    var diagnosticSummary: String {
        let sampleCount = heartRateSamples.count
        let baseline = String(format: "%.0f", baselineHR)
        let confidence = String(format: "%.0f%%", currentConfidence * 100)
        let latest = heartRateSamples.last.map { String(format: "%.0f", $0.bpm) } ?? "--"
        return "Samples: \(sampleCount) | Baseline: \(baseline) | Latest: \(latest) | Confidence: \(confidence)"
    }
}
