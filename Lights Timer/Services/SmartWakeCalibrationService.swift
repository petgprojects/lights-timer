import Foundation
import HealthKit

@Observable
final class SmartWakeCalibrationService {
    private struct StoredOccurrenceSummary: Codable {
        let summary: SmartWakeOccurrenceSummary
        let importedAt: Date
    }

    private struct NightCalibrationContext {
        let triggerLandedInDeepSleep: Bool
        let awakeOrREMNearWake: Bool
        let sleepHeartRate: Double?
        let wristTemperature: Double?
        let respiratoryRate: Double?
        let oxygenSaturation: Double?
        let heartRateVariability: Double?
    }

    private static let authorizationPromptedKey = "smartWakeCalibrationAuthorizationPrompted"

    private let healthStore = HKHealthStore()
    private let logStore: PhoneLogStore
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let profileURL: URL
    private let summariesDirectoryURL: URL
    private let retainedSummaryCount = 30

    private(set) var calibrationProfile: SmartWakeCalibrationProfile
    private(set) var isAuthorized = false
    private(set) var statusMessage = "Calibration is using the default Smart Wake profile."
    private(set) var lastCalibrationAt: Date?

    var onProfileUpdated: ((SmartWakeCalibrationProfile) -> Void)?

    init(logStore: PhoneLogStore) {
        self.logStore = logStore

        let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let calibrationDirectoryURL = appSupportURL.appendingPathComponent(
            "SmartWakeCalibration",
            isDirectory: true
        )
        self.profileURL = calibrationDirectoryURL.appendingPathComponent("profile.json")
        self.summariesDirectoryURL = calibrationDirectoryURL.appendingPathComponent(
            "Occurrences",
            isDirectory: true
        )

        try? fileManager.createDirectory(at: calibrationDirectoryURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: summariesDirectoryURL, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: profileURL),
           let storedProfile = try? decoder.decode(SmartWakeCalibrationProfile.self, from: data) {
            calibrationProfile = storedProfile.clamped()
        } else {
            calibrationProfile = .default
        }

        // HealthKit authorizationStatus(for:) only returns meaningful values for
        // write authorization. Since calibration only needs read access, we cannot
        // determine whether the user granted or denied read permissions. Instead,
        // track whether the authorization dialog has been shown.
        isAuthorized = UserDefaults.standard.bool(forKey: Self.authorizationPromptedKey)
        if isAuthorized {
            statusMessage = "Calibration access granted. Smart Wake can tune thresholds from recent nights."
        }
        lastCalibrationAt = calibrationProfile.updatedAt == .distantPast ? nil : calibrationProfile.updatedAt
        log("Smart Wake calibration service initialized. prompted=\(isAuthorized)")
    }

    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else {
            statusMessage = "HealthKit is unavailable on this iPhone."
            log("HealthKit unavailable for Smart Wake calibration", level: .warning)
            return false
        }

        let readTypes: Set<HKObjectType> = [
            HKCategoryType(.sleepAnalysis),
            HKQuantityType(.heartRate),
            HKQuantityType(.appleSleepingWristTemperature),
            HKQuantityType(.respiratoryRate),
            HKQuantityType(.oxygenSaturation),
            HKQuantityType(.heartRateVariabilitySDNN)
        ]

        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            // HealthKit does not expose read authorization status for privacy.
            // After the dialog completes without error, mark as prompted so
            // calibration can attempt to fetch data. If the user denied access,
            // HealthKit returns empty results and calibration gracefully no-ops.
            isAuthorized = true
            UserDefaults.standard.set(true, forKey: Self.authorizationPromptedKey)
            statusMessage = "Calibration access granted. Smart Wake can tune thresholds from recent nights."
            log("Smart Wake calibration authorization dialog completed. Marked as prompted.")
            await refreshCalibrationIfNeeded(force: true)
            return true
        } catch {
            statusMessage = "Calibration authorization failed: \(error.localizedDescription)"
            log(
                "Smart Wake calibration authorization failed: \(error.localizedDescription)",
                level: .error
            )
            return false
        }
    }

    func importOccurrenceSummary(_ summary: SmartWakeOccurrenceSummary) {
        let wrapped = StoredOccurrenceSummary(summary: summary, importedAt: Date())
        let fileURL = summariesDirectoryURL.appendingPathComponent(
            "occurrence-\(summary.id.uuidString).json"
        )

        do {
            let data = try encoder.encode(wrapped)
            try data.write(to: fileURL, options: .atomic)
            pruneStoredSummaries()
            statusMessage = "Imported Smart Wake occurrence \(summary.id.uuidString.prefix(8))."
            log(
                "Imported Smart Wake occurrence summary \(summary.id.uuidString) for schedule \(summary.scheduleID.uuidString)"
            )

            Task { [weak self] in
                await self?.refreshCalibrationIfNeeded(force: true)
            }
        } catch {
            statusMessage = "Failed to import Smart Wake occurrence summary."
            log(
                "Failed to persist Smart Wake occurrence summary \(summary.id.uuidString): \(error.localizedDescription)",
                level: .error
            )
        }
    }

    func refreshCalibrationIfNeeded(force: Bool = false) async {
        guard HKHealthStore.isHealthDataAvailable() else {
            statusMessage = "HealthKit is unavailable on this iPhone."
            return
        }

        // Gate on whether the user has been prompted, not on authorizationStatus
        // (which is unreliable for read-only HealthKit types). If the user denied
        // access, HealthKit returns empty results and calibration gracefully no-ops.
        guard isAuthorized else {
            if force {
                statusMessage = "Calibration still needs Health access. Using the default Smart Wake profile."
            }
            return
        }

        let summaries = loadStoredSummaries()
            .map(\.summary)
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(14)
        guard !summaries.isEmpty else {
            if force {
                statusMessage = "Calibration is waiting for watch occurrence summaries."
            }
            return
        }

        var motionOffsetTarget = 0.0
        var hrWeightTarget = calibrationProfile.hrWeightScale
        var sleepHeartRateWeightedSum = 0.0
        var sleepHeartRateWeight = 0.0
        var wristTemperatureWeightedSum = 0.0
        var wristTemperatureWeight = 0.0
        var respiratoryWeightedSum = 0.0
        var respiratoryWeight = 0.0
        var oxygenWeightedSum = 0.0
        var oxygenWeight = 0.0
        var hrvWeightedSum = 0.0
        var hrvWeight = 0.0
        var evaluatedNights = 0

        for summary in summaries {
            let context = await loadNightCalibrationContext(for: summary)
            evaluatedNights += 1
            let adjustmentWeight = calibrationAdjustmentWeight(for: context)

            let triggeredEarly = summary.triggerDate.map { $0 < summary.wakeUpTime } ?? false
            let exactWakeFallback = (summary.fallbackReason ?? "").localizedCaseInsensitiveContains("exact wake")
                || (summary.triggerDate.map { $0 >= summary.wakeUpTime } ?? false)

            if triggeredEarly && context.triggerLandedInDeepSleep {
                motionOffsetTarget += 0.05 * adjustmentWeight
            }

            if exactWakeFallback && context.awakeOrREMNearWake {
                motionOffsetTarget -= 0.03 * adjustmentWeight
            }

            if summary.sampleGaps.heartRateGapEventsOver90Seconds > 1
                || summary.sampleGaps.longestHeartRateGapSeconds > 180 {
                hrWeightTarget -= 0.08 * adjustmentWeight
            }

            if let sleepHeartRate = context.sleepHeartRate {
                sleepHeartRateWeightedSum += sleepHeartRate * adjustmentWeight
                sleepHeartRateWeight += adjustmentWeight
            }
            if let wristTemperature = context.wristTemperature {
                wristTemperatureWeightedSum += wristTemperature * adjustmentWeight
                wristTemperatureWeight += adjustmentWeight
            }
            if let respiratoryRate = context.respiratoryRate {
                respiratoryWeightedSum += respiratoryRate * adjustmentWeight
                respiratoryWeight += adjustmentWeight
            }
            if let oxygen = context.oxygenSaturation {
                oxygenWeightedSum += oxygen * adjustmentWeight
                oxygenWeight += adjustmentWeight
            }
            if let hrv = context.heartRateVariability {
                hrvWeightedSum += hrv * adjustmentWeight
                hrvWeight += adjustmentWeight
            }
        }

        let cappedMotionOffset = min(max(motionOffsetTarget, -0.12), 0.18)
        let cappedHRWeight = min(max(hrWeightTarget, 0.2), 1.0)
        let alpha = 2.0 / Double(min(max(evaluatedNights, 1), 14) + 1)
        let nextProfile = SmartWakeCalibrationProfile(
            version: 1,
            updatedAt: Date(),
            nightsConsidered: evaluatedNights,
            sleepHeartRateBaselineBPM: ema(
                current: calibrationProfile.sleepHeartRateBaselineBPM,
                target: weightedAverage(
                    weightedSum: sleepHeartRateWeightedSum,
                    totalWeight: sleepHeartRateWeight
                ) ?? calibrationProfile.sleepHeartRateBaselineBPM,
                alpha: alpha
            ),
            motionTriggerThresholdOffset: ema(
                current: calibrationProfile.motionTriggerThresholdOffset,
                target: cappedMotionOffset,
                alpha: alpha
            ),
            earlyWindowThresholdOffset: calibrationProfile.earlyWindowThresholdOffset,
            finalWindowThresholdOffset: calibrationProfile.finalWindowThresholdOffset,
            hrWeightScale: ema(
                current: calibrationProfile.hrWeightScale,
                target: cappedHRWeight,
                alpha: alpha
            ),
            stillnessMultiplier: ema(
                current: calibrationProfile.stillnessMultiplier,
                target: cappedMotionOffset > 0 ? 3.4 : 2.8,
                alpha: alpha
            ),
            minimumMotionScore: ema(
                current: calibrationProfile.minimumMotionScore,
                target: min(max(0.45 + (cappedMotionOffset * 0.35), 0.3), 0.7),
                alpha: alpha
            ),
            strongMotionScore: ema(
                current: calibrationProfile.strongMotionScore,
                target: min(max(0.78 + (cappedMotionOffset * 0.25), 0.62), 0.9),
                alpha: alpha
            ),
            wristTemperatureBaseline: weightedAverage(
                weightedSum: wristTemperatureWeightedSum,
                totalWeight: wristTemperatureWeight
            ) ?? calibrationProfile.wristTemperatureBaseline,
            respiratoryRateBaseline: weightedAverage(
                weightedSum: respiratoryWeightedSum,
                totalWeight: respiratoryWeight
            ) ?? calibrationProfile.respiratoryRateBaseline,
            oxygenSaturationBaseline: weightedAverage(
                weightedSum: oxygenWeightedSum,
                totalWeight: oxygenWeight
            ) ?? calibrationProfile.oxygenSaturationBaseline,
            hrvBaseline: weightedAverage(
                weightedSum: hrvWeightedSum,
                totalWeight: hrvWeight
            ) ?? calibrationProfile.hrvBaseline
        ).clamped()

        guard force || nextProfile != calibrationProfile else { return }

        calibrationProfile = nextProfile
        lastCalibrationAt = nextProfile.updatedAt
        statusMessage = "Calibration updated from \(evaluatedNights) recent night(s)."
        persistCalibrationProfile(nextProfile)
        onProfileUpdated?(nextProfile)
        log(
            "Updated Smart Wake calibration profile. nights=\(evaluatedNights) motionOffset=\(String(format: "%.3f", nextProfile.motionTriggerThresholdOffset)) hrWeight=\(String(format: "%.3f", nextProfile.hrWeightScale))"
        )
    }

    private func loadNightCalibrationContext(
        for summary: SmartWakeOccurrenceSummary
    ) async -> NightCalibrationContext {
        let triggerReferenceDate = summary.triggerDate ?? summary.wakeUpTime
        let stageWindowStart = triggerReferenceDate.addingTimeInterval(-10 * 60)
        let wakeLabelWindowStart = summary.wakeUpTime.addingTimeInterval(-20 * 60)
        let nightRangeStart = summary.wakeUpTime.addingTimeInterval(-12 * 60 * 60)
        let nightRangeEnd = summary.wakeUpTime.addingTimeInterval(90 * 60)

        let sleepSamples = (try? await fetchSleepSamples(from: nightRangeStart, to: nightRangeEnd)) ?? []
        let triggerLandedInDeepSleep = sleepSamples.contains { sample in
            sample.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                && sample.endDate > stageWindowStart
                && sample.startDate <= triggerReferenceDate
        }
        let awakeOrREMNearWake = sleepSamples.contains { sample in
            (sample.value == HKCategoryValueSleepAnalysis.awake.rawValue
                || sample.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue)
                && sample.endDate > wakeLabelWindowStart
                && sample.startDate <= summary.wakeUpTime
        }

        return NightCalibrationContext(
            triggerLandedInDeepSleep: triggerLandedInDeepSleep,
            awakeOrREMNearWake: awakeOrREMNearWake,
            sleepHeartRate: try? await fetchAverageQuantity(
                .heartRate,
                unit: HKUnit.count().unitDivided(by: .minute()),
                from: nightRangeStart,
                to: summary.wakeUpTime
            ),
            wristTemperature: try? await fetchAverageQuantity(
                .appleSleepingWristTemperature,
                unit: HKUnit.degreeCelsius(),
                from: nightRangeStart,
                to: nightRangeEnd
            ),
            respiratoryRate: try? await fetchAverageQuantity(
                .respiratoryRate,
                unit: HKUnit.count().unitDivided(by: .minute()),
                from: nightRangeStart,
                to: nightRangeEnd
            ),
            oxygenSaturation: try? await fetchAverageQuantity(
                .oxygenSaturation,
                unit: HKUnit.percent(),
                from: nightRangeStart,
                to: nightRangeEnd
            ),
            heartRateVariability: try? await fetchAverageQuantity(
                .heartRateVariabilitySDNN,
                unit: HKUnit.secondUnit(with: .milli),
                from: nightRangeStart,
                to: nightRangeEnd
            )
        )
    }

    private func fetchSleepSamples(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [HKCategorySample] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKCategoryType(.sleepAnalysis),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
                }
            }
            healthStore.execute(query)
        }
    }

    private func fetchAverageQuantity(
        _ type: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from startDate: Date,
        to endDate: Date
    ) async throws -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(type),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
                }
            }
            healthStore.execute(query)
        }

        guard !samples.isEmpty else { return nil }
        let values = samples.map { $0.quantity.doubleValue(for: unit) }
        return average(values)
    }

    private func loadStoredSummaries() -> [StoredOccurrenceSummary] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: summariesDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(StoredOccurrenceSummary.self, from: data)
        }
    }

    private func pruneStoredSummaries() {
        let urls = (try? fileManager.contentsOfDirectory(
            at: summariesDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let sortedURLs = urls.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }

        for url in sortedURLs.dropFirst(retainedSummaryCount) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func persistCalibrationProfile(_ profile: SmartWakeCalibrationProfile) {
        guard let data = try? encoder.encode(profile) else { return }
        try? data.write(to: profileURL, options: .atomic)
    }

    private func calibrationAdjustmentWeight(for context: NightCalibrationContext) -> Double {
        let deviations = [
            normalizedAbsoluteDeviation(
                context.wristTemperature,
                baseline: calibrationProfile.wristTemperatureBaseline,
                scale: 0.35
            ),
            normalizedAbsoluteDeviation(
                context.respiratoryRate,
                baseline: calibrationProfile.respiratoryRateBaseline,
                scale: 2.5
            ),
            normalizedAbsoluteDeviation(
                context.oxygenSaturation,
                baseline: calibrationProfile.oxygenSaturationBaseline,
                scale: 0.02
            ),
            normalizedAbsoluteDeviation(
                context.heartRateVariability,
                baseline: calibrationProfile.hrvBaseline,
                scale: 15
            )
        ].compactMap { $0 }

        guard let averageDeviation = average(deviations) else { return 1.0 }
        return max(0.65, 1.0 - (averageDeviation * 0.35))
    }

    private func normalizedAbsoluteDeviation(
        _ value: Double?,
        baseline: Double?,
        scale: Double
    ) -> Double? {
        guard let value, let baseline, scale > 0 else { return nil }
        return min(abs(value - baseline) / scale, 1.0)
    }

    private func ema(current: Double, target: Double, alpha: Double) -> Double {
        current + ((target - current) * alpha)
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func weightedAverage(weightedSum: Double, totalWeight: Double) -> Double? {
        guard totalWeight > 0 else { return nil }
        return weightedSum / totalWeight
    }

    private func log(_ message: String, level: PhoneLogLevel = .info) {
        logStore.log("SmartWakeCalibration", message, level: level)
    }
}
