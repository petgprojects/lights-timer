import Foundation

@Observable
final class WakeHeuristicEngine {
    private var heartRateSamples: [(date: Date, bpm: Double)] = []
    private var wakeWindowStart: Date?
    private var latestHRDelta: Double?
    private var latestHRScore: Double = 0
    private var latestHRVStdDev: Double?
    private var latestHRVScore: Double = 0

    private(set) var latestHeartRate: Double?
    private(set) var baselineHeartRate: Double?
    private(set) var baselineReady = false
    private(set) var baselineSampleCount = 0
    private(set) var baselineFrozenAt: Date?
    private(set) var hasTriggered = false
    private var didLogBaselineNotReadyInWakeWindow = false
    private var didLogAlreadyTriggeredRejection = false
    /// Prevents baseline freeze until the historical seed has had a chance to
    /// populate the baseline when monitoring starts inside the wake window.
    var awaitingHistoricalSeed = false
    private var awaitingSeedSince: Date?
    private let seedTimeout: TimeInterval = 30

    var logHandler: ((SmartWakeLogLevel, String) -> Void)?
    var verboseDiagnosticsProvider: (() -> Bool)?

    // Configuration
    let hrRiseThreshold: Double = 5.0
    let confidenceThreshold: Double = 0.6
    let cooldownInterval: TimeInterval = 300

    var currentConfidence: Double = 0
    var lastTriggerDate: Date?

    private let baselineLookback: TimeInterval = 7200
    private let baselineCutoffBeforeWindow: TimeInterval = 300
    private let minimumBaselineSamples = 5
    private let minimumBaselineSpan: TimeInterval = 900
    private let retainedHistoryWindow: TimeInterval = 7200

    // MARK: - Configuration

    func configure(wakeWindowStart: Date) {
        reset()
        self.wakeWindowStart = wakeWindowStart
        awaitingHistoricalSeed = true
        awaitingSeedSince = Date()
        let baselineStart = wakeWindowStart.addingTimeInterval(-baselineLookback)
        let baselineEnd = wakeWindowStart.addingTimeInterval(-baselineCutoffBeforeWindow)
        log(
            "Configured heuristic. wakeWindowStart=\(formatDate(wakeWindowStart)) baselineWindow=\(formatDate(baselineStart)) -> \(formatDate(baselineEnd))"
        )
    }

    // MARK: - Data Input

    func seedHeartRateSamples(_ samples: [(date: Date, bpm: Double)], referenceDate: Date = Date()) {
        guard !samples.isEmpty else {
            log("Historical seed contained no samples", level: .warning)
            return
        }
        let now = Date()
        let maxDate = now.addingTimeInterval(120)
        let validSamples = samples.filter { $0.date <= maxDate }
        let rejectedCount = samples.count - validSamples.count
        if rejectedCount > 0 {
            log("Rejected \(rejectedCount) historical sample(s) with future dates", level: .warning)
        }
        guard !validSamples.isEmpty else {
            log("All \(samples.count) historical sample(s) had future dates — seed discarded", level: .warning)
            return
        }
        heartRateSamples.append(contentsOf: validSamples)
        heartRateSamples.sort { $0.date < $1.date }
        latestHeartRate = heartRateSamples.last?.bpm
        if let firstSample = validSamples.first, let lastSample = validSamples.last {
            log(
                "Seeded \(validSamples.count) heart-rate sample(s) spanning \(formatDate(firstSample.date)) -> \(formatDate(lastSample.date))"
            )
        }
        awaitingHistoricalSeed = false
        awaitingSeedSince = nil
        refreshMetrics(referenceDate: referenceDate)
    }

    func addHeartRateSample(bpm: Double, date: Date = Date()) {
        let now = Date()
        guard date <= now.addingTimeInterval(120) else {
            log("Rejected heart-rate sample with future date \(formatDate(date)) (now=\(formatDate(now)))", level: .warning)
            return
        }
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
            recomputeBaseline(referenceDate: referenceDate)
        }

        updateConfidence(referenceDate: referenceDate)
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

    private func freezeBaselineIfNeeded(referenceDate _: Date) {
        let now = Date()

        if awaitingHistoricalSeed {
            if let since = awaitingSeedSince,
               now.timeIntervalSince(since) > seedTimeout {
                awaitingHistoricalSeed = false
                awaitingSeedSince = nil
                log(
                    "Seed timeout (\(Int(seedTimeout))s) — proceeding with baseline freeze",
                    level: .warning
                )
            } else {
                return
            }
        }

        guard baselineFrozenAt == nil,
              let wakeWindowStart,
              now >= wakeWindowStart else { return }

        recomputeBaseline(referenceDate: now)
        baselineFrozenAt = now
        log(
            "Baseline frozen at \(formatDate(now)). ready=\(baselineReady) baseline=\(formatBPM(baselineHeartRate)) samples=\(baselineSampleCount)"
        )
    }

    private func recomputeBaseline(referenceDate: Date) {
        guard let wakeWindowStart else {
            baselineHeartRate = nil
            baselineReady = false
            baselineSampleCount = 0
            log("Baseline check skipped because wakeWindowStart is missing", level: .warning)
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
        let span = candidates.last?.date.timeIntervalSince(candidates.first?.date ?? referenceDate) ?? 0

        guard candidates.count >= minimumBaselineSamples,
              let firstDate = candidates.first?.date,
              let lastDate = candidates.last?.date,
              lastDate.timeIntervalSince(firstDate) >= minimumBaselineSpan else {
            baselineHeartRate = nil
            baselineReady = false
            verboseLog(
                "Baseline check at \(formatDate(referenceDate)): candidates=\(candidates.count) span=\(formatDuration(span)) window=\(formatDate(baselineStart)) -> \(formatDate(baselineEnd)) result=not ready",
                level: .warning
            )
            return
        }

        baselineHeartRate = median(candidates.map(\.bpm))
        baselineReady = baselineHeartRate != nil
        verboseLog(
            "Baseline check at \(formatDate(referenceDate)): candidates=\(candidates.count) span=\(formatDuration(span)) baseline=\(formatBPM(baselineHeartRate)) BPM result=\(baselineReady ? "ready" : "not ready")"
        )
    }

    private func updateConfidence(referenceDate: Date) {
        guard baselineReady,
              let baselineHeartRate,
              let latestHeartRate else {
            latestHRDelta = nil
            latestHRScore = 0
            latestHRVStdDev = nil
            latestHRVScore = 0
            currentConfidence = 0
            verboseLog(
                "Confidence update at \(formatDate(referenceDate)): baselineReady=\(baselineReady) latest=\(formatBPM(self.latestHeartRate)) confidence=0.000",
                level: baselineReady ? .warning : .info
            )
            return
        }

        // Heart rate rise component (70% weight)
        let hrDelta = latestHeartRate - baselineHeartRate
        let hrScore = min(max(hrDelta / hrRiseThreshold, 0), 1.0) * 0.7
        latestHRDelta = hrDelta
        latestHRScore = hrScore

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
            latestHRVStdDev = stddev
        } else {
            hrvScore = 0
            latestHRVStdDev = nil
        }
        latestHRVScore = hrvScore

        currentConfidence = hrScore + hrvScore
        verboseLog(
            "Confidence update at \(formatDate(referenceDate)): latest=\(formatBPM(latestHeartRate)) baseline=\(formatBPM(baselineHeartRate)) hrDelta=\(formatBPM(hrDelta)) hrScore=\(formatScore(hrScore)) hrvStdDev=\(formatBPM(latestHRVStdDev)) hrvScore=\(formatScore(hrvScore)) confidence=\(formatScore(currentConfidence))"
        )
    }

    // MARK: - Decision

    func shouldTrigger(inWakeWindow: Bool, now: Date = Date()) -> Bool {
        if inWakeWindow {
            freezeBaselineIfNeeded(referenceDate: now)
        }

        guard inWakeWindow else {
            verboseLog(
                "Wake evaluation at \(formatDate(now)): outside wake window -> not triggering"
            )
            return false
        }

        guard !hasTriggered else {
            if !didLogAlreadyTriggeredRejection {
                didLogAlreadyTriggeredRejection = true
                log(
                    "Wake evaluation at \(formatDate(now)): already triggered at \(formatDate(lastTriggerDate)) -> not triggering",
                    level: .warning
                )
            }
            return false
        }

        guard baselineReady else {
            if !didLogBaselineNotReadyInWakeWindow {
                didLogBaselineNotReadyInWakeWindow = true
                log(
                    "Wake evaluation at \(formatDate(now)): baseline not ready (samples=\(baselineSampleCount), frozen=\(baselineFrozenAt != nil)) -> not triggering",
                    level: .warning
                )
            }
            return false
        }

        if let lastTriggerDate,
           now.timeIntervalSince(lastTriggerDate) < cooldownInterval {
            verboseLog(
                "Wake evaluation at \(formatDate(now)): cooldown active after trigger at \(formatDate(lastTriggerDate)) -> not triggering",
                level: .warning
            )
            return false
        }

        let shouldTrigger = currentConfidence >= confidenceThreshold
        let verdict = shouldTrigger ? "TRIGGER" : "WAIT"
        let message =
            "Wake evaluation at \(formatDate(now)): latest=\(formatBPM(latestHeartRate)) baseline=\(formatBPM(baselineHeartRate)) hrDelta=\(formatBPM(latestHRDelta)) hrScore=\(formatScore(latestHRScore)) hrvStdDev=\(formatBPM(latestHRVStdDev)) hrvScore=\(formatScore(latestHRVScore)) confidence=\(formatScore(currentConfidence)) threshold=\(formatScore(confidenceThreshold)) -> \(verdict)"
        if shouldTrigger {
            log(message)
        } else {
            verboseLog(message, level: .warning)
        }
        return shouldTrigger
    }

    func markTriggered(at date: Date = Date()) {
        hasTriggered = true
        lastTriggerDate = date
        log("Marked heuristic as triggered at \(formatDate(date))")
    }

    func reset() {
        heartRateSamples.removeAll()
        wakeWindowStart = nil
        latestHeartRate = nil
        baselineHeartRate = nil
        baselineReady = false
        baselineSampleCount = 0
        baselineFrozenAt = nil
        latestHRDelta = nil
        latestHRScore = 0
        latestHRVStdDev = nil
        latestHRVScore = 0
        currentConfidence = 0
        hasTriggered = false
        lastTriggerDate = nil
        didLogBaselineNotReadyInWakeWindow = false
        didLogAlreadyTriggeredRejection = false
        awaitingHistoricalSeed = false
        awaitingSeedSince = nil
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

    private func log(_ message: String, level: SmartWakeLogLevel = .info) {
        logHandler?(level, message)
    }

    private func verboseLog(_ message: String, level: SmartWakeLogLevel = .info) {
        guard verboseDiagnosticsProvider?() ?? false else { return }
        log(message, level: level)
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "--" }
        return Self.timestampFormatter.string(from: date)
    }

    private func formatBPM(_ bpm: Double?) -> String {
        guard let bpm else { return "--" }
        return String(format: "%.2f", bpm)
    }

    private func formatScore(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        String(format: "%.0fs", max(interval, 0))
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        formatter.timeZone = .current
        return formatter
    }()
}
