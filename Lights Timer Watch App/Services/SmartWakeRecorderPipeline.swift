import Foundation
#if canImport(CoreMotion)
import CoreMotion
#endif

/// Versioned acquisition state. Older magnitude-bin data is deliberately not
/// migrated into raw-XYZ detector state. Each occurrence has its own history.
nonisolated struct SmartWakeRecorderState: Codable, Sendable {
    static let schemaVersion = 2
    static let maximumHistorySeconds = 36.0 * 3600
    static let maximumEventCount = 2 * (36 * 60 + 1)
    var version = Self.schemaVersion
    var occurrence: String
    var start: Double
    var cursor: Double?
    /// Completed query cursor is separate from the actual last sample, which
    /// remains the duplicate-delivery watermark. Empty queries never advance it.
    var processedThrough: Double?
    var queryStart: Double?
    var queryEnd: Double?
    var queryAcceptedSampleCount = 0
    var binner = RecoveredRecorderBinner()
    var events: [RecoveredMovementEvent] = []
    var acceptedSampleCount = 0

    init(occurrence: String, start: Double) {
        self.occurrence = occurrence
        self.start = start
    }

    mutating func beginQuery(start: Double, end: Double? = nil) {
        queryStart = start
        queryEnd = end
        queryAcceptedSampleCount = 0
        binner.beginQuery(start: start)
    }

    /// Completion deliberately does not flush the bin. A cancelled enumeration
    /// does not call this, so its original boundary survives the next read.
    mutating func completeQuery() {
        if queryAcceptedSampleCount > 0 {
            processedThrough = queryEnd ?? cursor
        }
        queryStart = nil
        queryEnd = nil
        queryAcceptedSampleCount = 0
    }

    @discardableResult
    mutating func accept(_ sample: RecoveredMotionSample) -> Bool {
        guard sample.time.isFinite, sample.acceleration.x.isFinite,
              sample.acceleration.y.isFinite, sample.acceleration.z.isFinite,
              sample.time >= start, sample.time <= start + Self.maximumHistorySeconds,
              binner.boundary != nil,
              queryStart.map({ sample.time >= $0 }) ?? true,
              queryEnd.map({ sample.time <= $0 }) ?? true,
              cursor.map({ sample.time > $0 }) ?? true else { return false }
        events.append(contentsOf: binner.append(sample))
        cursor = sample.time
        acceptedSampleCount += 1
        queryAcceptedSampleCount += 1
        return true
    }

    /// Transport retries can deliver the tail of a logical hour later. Advance
    /// its boundary only when an actual later sample establishes the next
    /// logical query, never merely because a requested end date has passed.
    @discardableResult
    mutating func acceptDeliveredSample(_ sample: RecoveredMotionSample) -> Bool {
        guard sample.time.isFinite, sample.acceleration.x.isFinite,
              sample.acceleration.y.isFinite, sample.acceleration.z.isFinite,
              sample.time >= start, sample.time <= start + Self.maximumHistorySeconds,
              cursor.map({ sample.time > $0 }) ?? true else { return false }
        if queryStart == nil {
            let beginning = processedThrough ?? start
            beginQuery(start: beginning, end: min(beginning + 3600, start + Self.maximumHistorySeconds))
        }
        while let end = queryEnd, sample.time > end {
            completeQuery()
            beginQuery(start: end, end: min(end + 3600, start + Self.maximumHistorySeconds))
        }
        return accept(sample)
    }

    /// Reject malformed/old checkpoints rather than feeding invented state into
    /// the parity core. This also bounds decoded event storage and raw buffers.
    func isValid(occurrence expectedOccurrence: String, start expectedStart: Double, end: Double) -> Bool {
        guard version == Self.schemaVersion, occurrence == expectedOccurrence, start == expectedStart,
              start.isFinite, end.isFinite, end >= start,
              end - start <= Self.maximumHistorySeconds,
              acceptedSampleCount >= 0, acceptedSampleCount <= Int(Self.maximumHistorySeconds * 1000),
              binner.analyzer.counter == acceptedSampleCount,
              binner.analyzer.blockSamples.count == acceptedSampleCount % RecoveredMovementAnalyzer.blockLength,
              binner.analyzer.dLimit == RecoveredMovementAnalyzer.defaultDLimit,
              binner.analyzer.delayedThreshold == RecoveredMovementAnalyzer().delayedThreshold,
              events.count <= Self.maximumEventCount,
              queryAcceptedSampleCount >= 0, queryAcceptedSampleCount <= acceptedSampleCount else { return false }
        let dates = [cursor, processedThrough, queryStart, binner.analyzer.lastQualifyingTime]
        guard dates.allSatisfy({ $0.map({ $0.isFinite && $0 >= start && $0 <= end }) ?? true }),
              queryEnd.map({ $0.isFinite && $0 >= start && $0 <= start + Self.maximumHistorySeconds
                && $0 <= end + 3600 }) ?? true,
              binner.boundary.map({ $0.isFinite && $0 >= start && $0 <= end + 60 }) ?? true,
              (queryStart == nil) == (queryEnd == nil),
              queryStart.map({ $0 <= (queryEnd ?? $0) }) ?? true,
              acceptedSampleCount == 0 || (cursor != nil && binner.analyzer.previousAcceleration != nil
                && binner.analyzer.anchorAcceleration != nil),
              events.allSatisfy({ $0.time.isFinite && $0.time >= start && $0.time <= end
                && ($0.kind == 1 || $0.kind == 2) && $0.intensity.isFinite && $0.intensity > 0 }) else { return false }
        let vectors = binner.analyzer.blockSamples + [
            binner.analyzer.previousAcceleration, binner.analyzer.anchorAcceleration,
            binner.analyzer.previousBlockMean
        ].compactMap { $0 }
        return vectors.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
            && [binner.pendingFast, binner.pendingSlow].allSatisfy { $0.map({ $0.isFinite && $0 > 0 }) ?? true }
    }

    var history: RecoveredMovementHistory {
        RecoveredMovementHistory(start: start, events: events)
    }
}

nonisolated struct SmartWakeRecorderResult: Sendable {
    let state: SmartWakeRecorderState
    let status: String
}

/// Owns blocking recorder enumeration and disk checkpoints off the main actor.
/// Only 301 raw vectors and sparse minute events are retained, never a night of
/// raw samples. Empty queries don't commit a cursor across unavailable data.
actor SmartWakeRecorderPipeline {
    private var state: SmartWakeRecorderState?
    private let checkpointURL: URL

    init(checkpointURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.checkpointURL = checkpointURL ?? support.appendingPathComponent("SmartWakeMovementHistory-v2.json")
    }

    func read(occurrence: String, from start: Date, to end: Date) -> SmartWakeRecorderResult {
        let startTime = start.timeIntervalSince1970
        let endTime = end.timeIntervalSince1970
        guard startTime.isFinite, endTime.isFinite, endTime >= startTime,
              endTime - startTime <= SmartWakeRecorderState.maximumHistorySeconds else {
            let empty = SmartWakeRecorderState(occurrence: occurrence, start: startTime)
            return SmartWakeRecorderResult(state: empty, status: "Recorder history outside the 36-hour acquisition bound")
        }
        if state.map({ !$0.isValid(occurrence: occurrence, start: startTime, end: endTime) }) ?? true {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: checkpointURL.path),
               let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 1_048_576,
               let data = try? Data(contentsOf: checkpointURL),
               let saved = try? JSONDecoder().decode(SmartWakeRecorderState.self, from: data),
               saved.isValid(occurrence: occurrence, start: startTime, end: endTime) {
                state = saved
            } else {
                state = SmartWakeRecorderState(occurrence: occurrence, start: startTime)
            }
        }
        var current = state!
        #if canImport(CoreMotion) && (os(watchOS) || os(iOS))
        guard CMSensorRecorder.isAccelerometerRecordingAvailable(),
              CMSensorRecorder.authorizationStatus() == .authorized else {
            return SmartWakeRecorderResult(state: current, status: "Recorder unavailable or unauthorized")
        }
        let recorder = CMSensorRecorder()
        // The actual sample watermark, not a requested range endpoint, is the
        // authoritative transport cursor. Logical chunk boundaries persist in
        // state across these transport pages and across delayed recorder reads.
        var queryStart = current.cursor ?? startTime
        let before = current.acceptedSampleCount
        while queryStart < endTime && !Task.isCancelled {
            let queryEnd = min(queryStart + 3600, endTime)
            if let records = recorder.accelerometerData(
                from: Date(timeIntervalSince1970: queryStart), to: Date(timeIntervalSince1970: queryEnd)
            ) {
                var iterator = NSFastEnumerationIterator(records)
                while let value = iterator.next() {
                    if Task.isCancelled { break }
                    guard let record = value as? CMRecordedAccelerometerData else { continue }
                    let time = record.startDate.timeIntervalSince1970
                    guard time >= queryStart, time <= queryEnd else { continue }
                    current.acceptDeliveredSample(RecoveredMotionSample(time: time, acceleration: .init(
                        x: record.acceleration.x, y: record.acceleration.y, z: record.acceleration.z
                    )))
                }
            }
            if Task.isCancelled { break }
            queryStart = queryEnd
        }
        // This actor method never suspends, so an older request cannot overwrite
        // a newer occurrence. Cancellation checkpoints the partial query as well
        // as analyzer/bin state, allowing exact resume after process termination.
        state = current
        var status = "\(current.acceptedSampleCount - before) raw samples; \(current.events.count) movement events"
        do {
            try FileManager.default.createDirectory(at: checkpointURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(current).write(to: checkpointURL, options: .atomic)
        } catch { status += "; checkpoint failed: \(error.localizedDescription)" }
        return SmartWakeRecorderResult(state: current, status: status)
        #else
        return SmartWakeRecorderResult(state: current, status: "Recorder unavailable")
        #endif
    }
}
