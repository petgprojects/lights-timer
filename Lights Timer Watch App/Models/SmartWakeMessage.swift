import Foundation

enum SmartWakeTriggerMode: String, Codable, Equatable {
    case earlyMotionTrigger
    case exactWakeFallback
}

struct SmartWakeSensorProvenance: Codable, Equatable {
    let usedLiveMotion: Bool
    let usedRecordedMotionBaseline: Bool
    let usedHeartRate: Bool
    let heartRateWasStale: Bool
    let triggerMode: SmartWakeTriggerMode

    static let exactWakeFallback = SmartWakeSensorProvenance(
        usedLiveMotion: true,
        usedRecordedMotionBaseline: true,
        usedHeartRate: false,
        heartRateWasStale: true,
        triggerMode: .exactWakeFallback
    )
}

struct SmartWakeScoreTraceSummary: Codable, Equatable {
    let peakCompositeConfidence: Double
    let peakMotionScore: Double
    let peakStillnessBreakScore: Double
    let peakHeartRateArousal: Double
    let latestCompositeConfidence: Double
    let latestMotionScore: Double
    let latestStillnessBreakScore: Double
    let latestHeartRateArousal: Double

    static let empty = SmartWakeScoreTraceSummary(
        peakCompositeConfidence: 0,
        peakMotionScore: 0,
        peakStillnessBreakScore: 0,
        peakHeartRateArousal: 0,
        latestCompositeConfidence: 0,
        latestMotionScore: 0,
        latestStillnessBreakScore: 0,
        latestHeartRateArousal: 0
    )
}

struct SmartWakeSampleGapSummary: Codable, Equatable {
    let longestHeartRateGapSeconds: Double
    let heartRateGapEventsOver90Seconds: Int
    let longestMotionGapSeconds: Double
    let motionGapEventsOver2Seconds: Int
    let recorderBackfillLagSeconds: Double?

    static let empty = SmartWakeSampleGapSummary(
        longestHeartRateGapSeconds: 0,
        heartRateGapEventsOver90Seconds: 0,
        longestMotionGapSeconds: 0,
        motionGapEventsOver2Seconds: 0,
        recorderBackfillLagSeconds: nil
    )
}

struct SmartWakeOccurrenceSummary: Codable, Equatable, Identifiable {
    let id: UUID
    let scheduleID: UUID
    let scheduleName: String
    let wakeWindowStart: Date
    let wakeUpTime: Date
    let armedAt: Date?
    let triggerDate: Date?
    let triggerConfidence: Double?
    let motionScore: Double?
    let hrFreshnessSeconds: Double?
    let motionFreshnessSeconds: Double?
    let sensorProvenance: SmartWakeSensorProvenance?
    let scoreTraceSummary: SmartWakeScoreTraceSummary
    let sampleGaps: SmartWakeSampleGapSummary
    let fallbackReason: String?
    let createdAt: Date
}

struct SmartWakeCalibrationProfile: Codable, Equatable, Sendable {
    let version: Int
    let updatedAt: Date
    let nightsConsidered: Int
    let sleepHeartRateBaselineBPM: Double
    let motionTriggerThresholdOffset: Double
    let earlyWindowThresholdOffset: Double
    let finalWindowThresholdOffset: Double
    let hrWeightScale: Double
    let stillnessMultiplier: Double
    let minimumMotionScore: Double
    let strongMotionScore: Double
    let wristTemperatureBaseline: Double?
    let respiratoryRateBaseline: Double?
    let oxygenSaturationBaseline: Double?
    let hrvBaseline: Double?

    nonisolated static let `default` = SmartWakeCalibrationProfile(
        version: 1,
        updatedAt: .distantPast,
        nightsConsidered: 0,
        sleepHeartRateBaselineBPM: 56,
        motionTriggerThresholdOffset: 0,
        earlyWindowThresholdOffset: 0.08,
        finalWindowThresholdOffset: -0.04,
        hrWeightScale: 1.0,
        stillnessMultiplier: 3.0,
        minimumMotionScore: 0.45,
        strongMotionScore: 0.78,
        wristTemperatureBaseline: nil,
        respiratoryRateBaseline: nil,
        oxygenSaturationBaseline: nil,
        hrvBaseline: nil
    )

    nonisolated func clamped() -> SmartWakeCalibrationProfile {
        SmartWakeCalibrationProfile(
            version: version,
            updatedAt: updatedAt,
            nightsConsidered: max(0, nightsConsidered),
            sleepHeartRateBaselineBPM: min(max(sleepHeartRateBaselineBPM, 38), 95),
            motionTriggerThresholdOffset: min(max(motionTriggerThresholdOffset, -0.12), 0.18),
            earlyWindowThresholdOffset: min(max(earlyWindowThresholdOffset, 0.02), 0.18),
            finalWindowThresholdOffset: min(max(finalWindowThresholdOffset, -0.12), 0),
            hrWeightScale: min(max(hrWeightScale, 0.2), 1.0),
            stillnessMultiplier: min(max(stillnessMultiplier, 1.5), 6.0),
            minimumMotionScore: min(max(minimumMotionScore, 0.25), 0.75),
            strongMotionScore: min(max(strongMotionScore, 0.55), 0.95),
            wristTemperatureBaseline: wristTemperatureBaseline,
            respiratoryRateBaseline: respiratoryRateBaseline,
            oxygenSaturationBaseline: oxygenSaturationBaseline,
            hrvBaseline: hrvBaseline
        )
    }
}

struct SmartWakeTriggerPayload: Codable, Equatable {
    let triggerID: UUID
    let scheduleID: UUID
    let triggerDate: Date
    let confidence: Double
    let heartRateAtTrigger: Double?
    let motionLevel: Double?
    let motionScore: Double?
    let hrFreshnessSeconds: Double?
    let motionFreshnessSeconds: Double?
    let sensorProvenance: SmartWakeSensorProvenance?
    let lightsHandledOnWatch: Bool?

    init(
        triggerID: UUID = UUID(),
        scheduleID: UUID,
        triggerDate: Date,
        confidence: Double,
        heartRateAtTrigger: Double?,
        motionLevel: Double?,
        motionScore: Double? = nil,
        hrFreshnessSeconds: Double? = nil,
        motionFreshnessSeconds: Double? = nil,
        sensorProvenance: SmartWakeSensorProvenance? = nil,
        lightsHandledOnWatch: Bool? = nil
    ) {
        self.triggerID = triggerID
        self.scheduleID = scheduleID
        self.triggerDate = triggerDate
        self.confidence = confidence
        self.heartRateAtTrigger = heartRateAtTrigger
        self.motionLevel = motionLevel
        self.motionScore = motionScore
        self.hrFreshnessSeconds = hrFreshnessSeconds
        self.motionFreshnessSeconds = motionFreshnessSeconds
        self.sensorProvenance = sensorProvenance
        self.lightsHandledOnWatch = lightsHandledOnWatch
    }

    private enum CodingKeys: String, CodingKey {
        case triggerID
        case scheduleID
        case triggerDate
        case confidence
        case heartRateAtTrigger
        case motionLevel
        case motionScore
        case hrFreshnessSeconds
        case motionFreshnessSeconds
        case sensorProvenance
        case lightsHandledOnWatch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        triggerID = try container.decode(UUID.self, forKey: .triggerID)
        scheduleID = try container.decode(UUID.self, forKey: .scheduleID)
        triggerDate = try container.decode(Date.self, forKey: .triggerDate)
        confidence = try container.decode(Double.self, forKey: .confidence)
        heartRateAtTrigger = try container.decodeIfPresent(Double.self, forKey: .heartRateAtTrigger)
        motionLevel = try container.decodeIfPresent(Double.self, forKey: .motionLevel)
        motionScore = try container.decodeIfPresent(Double.self, forKey: .motionScore)
        hrFreshnessSeconds = try container.decodeIfPresent(Double.self, forKey: .hrFreshnessSeconds)
        motionFreshnessSeconds = try container.decodeIfPresent(Double.self, forKey: .motionFreshnessSeconds)
        sensorProvenance = try container.decodeIfPresent(
            SmartWakeSensorProvenance.self,
            forKey: .sensorProvenance
        )
        lightsHandledOnWatch = try container.decodeIfPresent(Bool.self, forKey: .lightsHandledOnWatch)
    }
}

struct SmartWakeLightHandoffPayload: Codable, Equatable {
    let triggerID: UUID
    let scheduleID: UUID
    let phoneWillHandleLights: Bool
    let reason: String?
}

struct SmartWakeSessionState: Codable {
    enum State: String, Codable {
        case idle
        case monitoring
        case triggered
        case failed
    }

    let state: State
    let scheduleID: UUID?
    let message: String?
}

struct SmartWakePermissionStatus: Codable {
    let heartRateDataActive: Bool
    let watchConnected: Bool
    let motionAvailable: Bool
    let motionAuthorized: Bool
    let recorderAvailable: Bool
    let recorderAuthorized: Bool

    init(
        heartRateDataActive: Bool,
        watchConnected: Bool,
        motionAvailable: Bool = false,
        motionAuthorized: Bool = false,
        recorderAvailable: Bool = false,
        recorderAuthorized: Bool = false
    ) {
        self.heartRateDataActive = heartRateDataActive
        self.watchConnected = watchConnected
        self.motionAvailable = motionAvailable
        self.motionAuthorized = motionAuthorized
        self.recorderAvailable = recorderAvailable
        self.recorderAuthorized = recorderAuthorized
    }

    private enum CodingKeys: String, CodingKey {
        case heartRateDataActive = "healthKitAuthorized"
        case watchConnected
        case motionAvailable
        case motionAuthorized
        case recorderAvailable
        case recorderAuthorized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        heartRateDataActive = try container.decode(Bool.self, forKey: .heartRateDataActive)
        watchConnected = try container.decode(Bool.self, forKey: .watchConnected)
        motionAvailable = try container.decodeIfPresent(Bool.self, forKey: .motionAvailable) ?? false
        motionAuthorized = try container.decodeIfPresent(Bool.self, forKey: .motionAuthorized) ?? false
        recorderAvailable = try container.decodeIfPresent(Bool.self, forKey: .recorderAvailable) ?? false
        recorderAuthorized = try container.decodeIfPresent(Bool.self, forKey: .recorderAuthorized) ?? false
    }
}

struct HapticPatternChangePayload: Codable {
    let scheduleID: UUID
    let hapticPatternRaw: String
}

enum SmartWakePowerMode: String, Codable, CaseIterable, Identifiable {
    case balanced
    case highReliability

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .balanced:
            "Balanced"
        case .highReliability:
            "High Reliability"
        }
    }

    var summary: String {
        switch self {
        case .balanced:
            "Motion-first Smart Wake using live motion, recorder backfill, irregular heart-rate reinforcement, and exact-wake fallback."
        case .highReliability:
            "Reserved for diagnostics and future experiments. Production Smart Wake uses the same motion-first path."
        }
    }

    var detail: String {
        switch self {
        case .balanced:
            "Recommended. Uses the scheduled smart-alarm session, live device motion at 10 Hz, recorder backfill, and exact-wake fallback without relying on background workout startup."
        case .highReliability:
            "Experimental. The legacy overnight-workout path is no longer part of default Smart Wake behavior."
        }
    }

    var isBatteryHeavy: Bool {
        false
    }
}

struct SmartWakeSyncPayload: Codable, Equatable {
    let schedules: [WatchScheduleSnapshot]
    let powerMode: SmartWakePowerMode
    let calibrationProfile: SmartWakeCalibrationProfile

    init(
        schedules: [WatchScheduleSnapshot],
        powerMode: SmartWakePowerMode,
        calibrationProfile: SmartWakeCalibrationProfile = .default
    ) {
        self.schedules = schedules
        self.powerMode = powerMode
        self.calibrationProfile = calibrationProfile
    }

    private enum CodingKeys: String, CodingKey {
        case schedules
        case powerMode
        case calibrationProfile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schedules = try container.decode([WatchScheduleSnapshot].self, forKey: .schedules)
        powerMode = try container.decodeIfPresent(SmartWakePowerMode.self, forKey: .powerMode) ?? .balanced
        calibrationProfile = try container.decodeIfPresent(
            SmartWakeCalibrationProfile.self,
            forKey: .calibrationProfile
        ) ?? .default
    }
}

enum WCMessageKey {
    static let type = "type"
    static let payload = "payload"

    static let smartWakeTriggered = "smartWakeTriggered"
    static let sessionStateChanged = "sessionStateChanged"
    static let permissionStatus = "permissionStatus"
    static let schedulesUpdated = "schedulesUpdated"
    static let hapticPatternChanged = "hapticPatternChanged"
    static let testTrigger = "testTrigger"
    static let smartWakeLightHandoff = "smartWakeLightHandoff"
    static let smartWakeOccurrenceSummary = "smartWakeOccurrenceSummary"
}

enum HapticPattern: String, Codable, CaseIterable, Identifiable {
    case gentle
    case pulse
    case heartbeat
    case alarm
    case critical

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gentle: "Gentle"
        case .pulse: "Pulse"
        case .heartbeat: "Heartbeat"
        case .alarm: "Alarm"
        case .critical: "Critical"
        }
    }

    var patternDescription: String {
        switch self {
        case .gentle: "Soft taps that gradually increase"
        case .pulse: "Rhythmic pulses that build"
        case .heartbeat: "Heartbeat-like double taps"
        case .alarm: "Aggressive alarm bursts with rapid follow-up taps"
        case .critical: "Maximum-strength triple bursts using the strongest watch haptics available to the app"
        }
    }

    var systemImage: String {
        switch self {
        case .gentle: "hand.tap"
        case .pulse: "waveform.path"
        case .heartbeat: "heart.fill"
        case .alarm: "alarm.fill"
        case .critical: "exclamationmark.triangle.fill"
        }
    }
}
