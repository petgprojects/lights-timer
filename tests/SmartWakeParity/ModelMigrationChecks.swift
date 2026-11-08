import Foundation

@main
struct ModelMigrationChecks {
    static func main() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let summary = SmartWakeOccurrenceSummary(
            id: UUID(), scheduleID: UUID(), scheduleName: "Migration", wakeWindowStart: Date(timeIntervalSince1970: 1_000),
            wakeUpTime: Date(timeIntervalSince1970: 2_800), armedAt: nil, triggerDate: nil,
            triggerConfidence: nil, motionScore: nil, hrFreshnessSeconds: nil, motionFreshnessSeconds: nil,
            sensorProvenance: nil, scoreTraceSummary: .empty, sampleGaps: .empty, fallbackReason: nil,
            createdAt: Date(timeIntervalSince1970: 2_801)
        )
        precondition(summary.algorithmIdentifier == "recovered-watch-movement-v1")
        let decoded = try decoder.decode(SmartWakeOccurrenceSummary.self, from: encoder.encode(summary))
        precondition(decoded == summary)
        var json = try JSONSerialization.jsonObject(with: encoder.encode(summary)) as! [String: Any]
        json.removeValue(forKey: "algorithmIdentifier")
        json.removeValue(forKey: "movementTraceSummary")
        let oldSummary = try decoder.decode(SmartWakeOccurrenceSummary.self, from: JSONSerialization.data(withJSONObject: json))
        precondition(oldSummary.algorithmIdentifier == nil)
        precondition(oldSummary.movementTraceSummary == nil)
        let oldPayload = try decoder.decode(SmartWakeSyncPayload.self, from: Data("{\"schedules\":[]}".utf8))
        precondition(oldPayload.powerMode == .balanced && oldPayload.calibrationProfile == .default)
        var detailed = summary
        detailed.movementTraceSummary = SmartWakeMovementTraceSummary(phaseDescription: "Armed", historicalEventRate: 9.5, dLimit: 0, raLimit: 0.3, verySensitive: false, historicalEventCount: 54)
        let decodedDetail = try decoder.decode(SmartWakeOccurrenceSummary.self, from: encoder.encode(detailed))
        precondition(decodedDetail == detailed)
        print("6 model migration checks passed")
    }
}
