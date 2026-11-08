import Foundation

@main
struct RecorderChecks {
    static func main() async throws {
        var names: [String] = []
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            names.append(name)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        func bytes(_ state: SmartWakeRecorderState) throws -> Data { try encoder.encode(state) }
        func raw(_ time: Double, _ x: Double = 0) -> RecoveredMotionSample {
            .init(time: time, acceleration: .init(x: x, y: 0, z: 1))
        }
        var state = SmartWakeRecorderState(occurrence: "schedule:20000", start: 0)
        check(state.isValid(occurrence: "schedule:20000", start: 0, end: 3600), "fresh recorder state valid")
        check(!state.accept(raw(0)), "recorder samples require begun query")
        state.beginQuery(start: 0, end: 3600)
        check(state.accept(raw(0)), "first sample accepted with exact timestamp")
        check(!state.accept(raw(0, 10)), "duplicate recorder delivery rejected")
        check(!state.accept(raw(-1, 10)), "out-of-order and pre-session sample rejected")
        check(!state.accept(raw(3601)), "sample outside current query rejected")
        check(!state.accept(raw(1, .nan)), "nonfinite XYZ rejected before detector")
        check(!state.accept(raw(.infinity)), "nonfinite sample timestamp rejected")
        check(state.cursor == 0 && state.acceptedSampleCount == 1 && state.binner.analyzer.counter == 1,
              "rejected delivery does not mutate analyzer or cursor")
        check(state.accept(raw(3600, 0.2)), "query end timestamp is inclusive")
        state.completeQuery()
        check(state.processedThrough == 3600 && state.cursor == 3600, "query cursor and actual sample cursor recorded separately")
        state.beginQuery(start: 3600, end: 7200)
        state.completeQuery()
        check(state.processedThrough == 3600 && state.cursor == 3600, "empty query does not skip unavailable history")
        check(state.queryStart == nil && state.queryEnd == nil, "completed query clears partial metadata")
        check(!state.isValid(occurrence: "different", start: 0, end: 7200), "checkpoint belongs to exact occurrence")
        check(!state.isValid(occurrence: "schedule:20000", start: 1, end: 7200), "checkpoint preserves exact armedAt")
        check(!state.isValid(occurrence: "schedule:20000", start: 0, end: 36 * 3600 + 1), "history has bounded acquisition horizon")
        var old = state
        old.version = 1
        check(!old.isValid(occurrence: "schedule:20000", start: 0, end: 7200), "older magnitude or schema state cannot enter raw detector")
        var corrupt = state
        corrupt.acceptedSampleCount += 1
        check(!corrupt.isValid(occurrence: "schedule:20000", start: 0, end: 7200), "checkpoint rejects inconsistent analyzer count")
        corrupt = state
        corrupt.events.append(.init(time: 100, kind: 9, intensity: 1))
        check(!corrupt.isValid(occurrence: "schedule:20000", start: 0, end: 7200), "checkpoint rejects unexpected historical event kinds")
        corrupt = state
        corrupt.binner.analyzer.dLimit = 0.2
        check(!corrupt.isValid(occurrence: "schedule:20000", start: 0, end: 7200), "checkpoint cannot tune fixed detector D")
        corrupt = state
        corrupt.events = Array(repeating: .init(time: 100, kind: 1, intensity: 1), count: SmartWakeRecorderState.maximumEventCount + 1)
        check(!corrupt.isValid(occurrence: "schedule:20000", start: 0, end: 7200), "checkpoint event storage is bounded")

        let samples = (0..<10000).map { index in raw(Double(index) / 50, Double((index / 271) % 3) * 0.14) }
        var uninterrupted = SmartWakeRecorderState(occurrence: "replay", start: 0)
        uninterrupted.beginQuery(start: 0, end: 200)
        for sample in samples { uninterrupted.accept(sample) }
        uninterrupted.completeQuery()
        var directBinner = RecoveredRecorderBinner()
        let events = directBinner.processQuery(start: 0, samples: samples)
        check(uninterrupted.events == events && uninterrupted.binner.analyzer.counter == samples.count,
              "streaming acquisition emits exact parity-core query output")
        for split in [1, 100, 300, 301, 601, 3001, 9999] {
            var resumed = SmartWakeRecorderState(occurrence: "replay", start: 0)
            resumed.beginQuery(start: 0, end: 200)
            for sample in samples.prefix(split) { resumed.accept(sample) }
            let persisted = try bytes(resumed)
            resumed = try decoder.decode(SmartWakeRecorderState.self, from: persisted)
            check(resumed.isValid(occurrence: "replay", start: 0, end: 200), "partial checkpoint \(split) validates")
            // Device query can redeliver its boundary sample. Do not begin a new
            // query here: cancellation/relaunch retains its original bin boundary.
            for sample in samples.suffix(from: split - 1) { resumed.accept(sample) }
            resumed.completeQuery()
            check(try bytes(resumed) == bytes(uninterrupted), "partial checkpoint \(split) resumes with identical complete state")
        }
        check(uninterrupted.binner.analyzer.blockSamples.count < 301, "raw memory stays bounded to one partial block")
        check(uninterrupted.events.count < 2 * 5, "history stores sparse minute events instead of raw night")
        var partial = SmartWakeRecorderState(occurrence: "partial", start: 0)
        partial.beginQuery(start: 0, end: 60)
        partial.accept(raw(0))
        partial.accept(raw(1, 0.2))
        partial.completeQuery()
        check(partial.events.isEmpty && partial.binner.pendingFast != nil, "completed query does not flush final partial bin")
        partial.beginQuery(start: 60, end: 180)
        partial.accept(raw(120, 0.3))
        check(partial.events.isEmpty, "query boundary equality keeps pending data")
        partial.accept(raw(120.1, 0.4))
        check(partial.events.count == 1 && partial.events[0].time == 120, "next query retains pending intensity and resets local boundary")
        let hourSamples = (0...180050).map { index in raw(Double(index) / 50, Double((index / 271) % 3) * 0.14) }
        var delivered = SmartWakeRecorderState(occurrence: "delivery", start: 0)
        for sample in hourSamples { delivered.acceptDeliveredSample(sample) }
        var logical = RecoveredRecorderBinner()
        var logicalEvents = logical.processQuery(start: 0, samples: hourSamples.filter { $0.time <= 3600 })
        logicalEvents += logical.processQuery(start: 3600, samples: hourSamples.filter { $0.time > 3600 })
        check(delivered.events == logicalEvents, "transport delivery preserves fixed logical hour event boundaries")
        check(try encoder.encode(delivered.binner) == encoder.encode(logical), "logical hour delivery retains exact analyzer and pending state")
        var lateTail = SmartWakeRecorderState(occurrence: "delivery", start: 0)
        for sample in hourSamples.prefix(179501) { lateTail.acceptDeliveredSample(sample) }
        check(lateTail.cursor == 3590 && lateTail.queryStart == 0 && lateTail.queryEnd == 3600,
              "partially delivered hour remains open until actual crossing sample")
        check(lateTail.isValid(occurrence: "delivery", start: 0, end: 3590), "checkpoint can retain future logical-hour endpoint")
        lateTail = try decoder.decode(SmartWakeRecorderState.self, from: encoder.encode(lateTail))
        for sample in hourSamples.suffix(from: 179490) { lateTail.acceptDeliveredSample(sample) }
        check(try bytes(lateTail) == bytes(delivered), "delayed recorder tail and repeated prefix produce identical state after relaunch")
        check(delivered.queryStart == 3600 && delivered.queryEnd == 7200 && delivered.cursor == 3601,
              "actual next-hour sample advances logical query without shifting timestamps")
        var invalidDelivery = SmartWakeRecorderState(occurrence: "delivery", start: 0)
        check(!invalidDelivery.acceptDeliveredSample(raw(1, .nan)) && invalidDelivery.queryStart == nil,
              "invalid delivery cannot initialize or advance logical hour")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightsTimerRecorderChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let checkpoint = folder.appendingPathComponent("checkpoint.json")
        try bytes(partial).write(to: checkpoint)
        let pipeline = SmartWakeRecorderPipeline(checkpointURL: checkpoint)
        let loaded = await pipeline.read(occurrence: "partial", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 180))
        check(try bytes(loaded.state) == bytes(partial), "new recorder actor loads occurrence-scoped partial checkpoint")
        check(loaded.status == "Recorder unavailable", "native replay explicitly reports unavailable recorder hardware")
        let nextOccurrence = await pipeline.read(occurrence: "next", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 180))
        check(nextOccurrence.state.acceptedSampleCount == 0 && nextOccurrence.state.occurrence == "next", "new occurrence cannot reuse old raw analyzer")
        var obsolete = partial
        obsolete.version = 1
        try bytes(obsolete).write(to: checkpoint)
        let oldSchemaPipeline = SmartWakeRecorderPipeline(checkpointURL: checkpoint)
        let oldSchema = await oldSchemaPipeline.read(occurrence: "partial", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 180))
        check(oldSchema.state.acceptedSampleCount == 0 && oldSchema.state.version == 2, "obsolete disk schema is replaced with fresh raw state")
        try Data(repeating: 32, count: 1_048_577).write(to: checkpoint)
        let oversizedPipeline = SmartWakeRecorderPipeline(checkpointURL: checkpoint)
        let oversized = await oversizedPipeline.read(occurrence: "partial", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 180))
        check(oversized.state.acceptedSampleCount == 0, "oversized disk checkpoint is rejected before decoding")
        let outsideBound = await pipeline.read(occurrence: "partial", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 36 * 3600 + 1))
        check(outsideBound.state.acceptedSampleCount == 0 && outsideBound.status.contains("36-hour"), "out-of-bound history request stays empty and explicit")
        let result: [String: Any] = ["status": "passed", "checks": names.count, "names": names]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
    }
}
