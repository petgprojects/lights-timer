import Foundation

@main
struct BaselineProbe {
    static func run(label: String, recordedMagnitude: Double) async -> Double {
        let engine = WakeHeuristicEngine()
        let windowStart = Date(timeIntervalSince1970: 1_800_000_000)
        let now = windowStart.addingTimeInterval(600)
        _ = await engine.configure(wakeWindowStart: windowStart, wakeUpTime: windowStart.addingTimeInterval(1500), calibrationProfile: .default)
        let bins = (180...3600).map { offset in
            SmartWakeRecordedMotionBin(secondStart: now.addingTimeInterval(-Double(offset)), averageAccelerationMagnitude: recordedMagnitude, sampleCount: 50)
        }
        _ = await engine.ingestRecordedMotionBins(bins, evaluatedAt: now.addingTimeInterval(-90))
        for index in 0..<900 {
            _ = await engine.ingestLiveMotionSample(SmartWakeLiveMotionSample(
                date: now.addingTimeInterval(-90 + Double(index) / 10),
                userAccelerationMagnitude: 0.02,
                rotationMagnitude: 0,
                gravityX: 0, gravityY: 0, gravityZ: 1,
                pitch: 0, roll: 0, yaw: 0
            ))
        }
        let result = await engine.evaluate(at: now)
        print("\(label): baseline=\(recordedMagnitude), liveEnergy=\(result.snapshot.motionEnergy60s), stillnessBreak=\(result.snapshot.stillnessBreakScore), motionConfidence=\(result.snapshot.motionModeConfidence)")
        return result.snapshot.stillnessBreakScore
    }
    static func main() async {
        let raw = await run(label: "Current raw-gravity baseline", recordedMagnitude: 1.0)
        let comparable = await run(label: "Illustrative comparable motion baseline", recordedMagnitude: 0.005)
        precondition(raw == 0)
        precondition(comparable > 0.9)
        print("PASS: existing engine reproduces the baseline feature mismatch. This is a synthetic diagnostic, not a validated preprocessing fix or a sleep-quality test.")
    }
}
