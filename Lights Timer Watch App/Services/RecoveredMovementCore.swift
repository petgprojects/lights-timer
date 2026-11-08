import Foundation

// Independent implementation of the finite-input behavior documented in
// plans/sleep-cycle-watch/{MOTION,ALARM,RUNTIME}.md. There are deliberately no
// platform calls, clock reads, HR inputs, calibration profiles, or delivery
// policies here. Acquisition/ownership/checkpoint policy belongs to the adapter.

nonisolated struct RecoveredAcceleration: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    func distance(to other: Self) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        let dz = z - other.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}

nonisolated struct RecoveredMotionSample: Codable, Equatable, Sendable {
    /// Actual sensor timestamp, expressed in seconds in the adapter's epoch.
    var time: Double
    /// Raw acceleration, including gravity, for both live and recorder input.
    var acceleration: RecoveredAcceleration

    init(time: Double, acceleration: RecoveredAcceleration) {
        self.time = time
        self.acceleration = acceleration
    }
}

nonisolated struct RecoveredMovement: Codable, Equatable, Sendable {
    var time: Double
    var newMovement: Bool
    var movementInProgress: Bool
    var delayedMovement: Bool
    var intensity: Double
    var duration: Double
    /// Preserved by the armed filter; synthetic decision tests may omit it.
    var acceleration: RecoveredAcceleration?

    init(time: Double, newMovement: Bool, movementInProgress: Bool,
         delayedMovement: Bool, intensity: Double, duration: Double = 0,
         acceleration: RecoveredAcceleration? = nil) {
        self.time = time
        self.newMovement = newMovement
        self.movementInProgress = movementInProgress
        self.delayedMovement = delayedMovement
        self.intensity = intensity
        self.duration = duration
        self.acceleration = acceleration
    }
}

nonisolated struct RecoveredMovementAnalyzer: Codable, Sendable {
    /// Exact recovered getter bits: 0x3fb70a3d70a3d70b.
    static let defaultDLimit = Double(bitPattern: 0x3fb70a3d70a3d70b)
    static let blockLength = 301

    // Mutating dLimit intentionally does not recompute delayedThreshold. The
    // recovered setter only changes D; normal production uses the fixed D.
    var dLimit: Double
    var delayedThreshold: Double
    var previousAcceleration: RecoveredAcceleration?
    var anchorAcceleration: RecoveredAcceleration?
    var previousBlockMean: RecoveredAcceleration?
    var blockSamples: [RecoveredAcceleration] = []
    var counter = 0
    var lastQualifyingTime: Double?

    init(dLimit: Double = Self.defaultDLimit) {
        self.dLimit = dLimit
        delayedThreshold = exp((dLimit - 0.327) / 0.043) * (dLimit < 0.04 ? 2.1 : 1)
        blockSamples.reserveCapacity(Self.blockLength)
    }

    mutating func update(_ sample: RecoveredMotionSample) -> RecoveredMovement {
        let acceleration = sample.acceleration
        var new = false
        var active = false
        var delayed = false
        var intensity = 0.0

        if let previousAcceleration {
            let shortDelta = previousAcceleration.distance(to: acceleration)
            intensity = shortDelta
            var candidate = shortDelta
            if let anchorAcceleration {
                candidate = max(candidate, anchorAcceleration.distance(to: acceleration))
            }
            if candidate > dLimit {
                active = true
                intensity = candidate
                new = lastQualifyingTime == nil
            }
        }

        blockSamples.append(acceleration)
        if blockSamples.count == Self.blockLength {
            // Nonoverlapping blocks. Preserve sample order and divide only once
            // after summing each axis, as in the executable reference.
            var x = 0.0
            var y = 0.0
            var z = 0.0
            for value in blockSamples {
                x += value.x
                y += value.y
                z += value.z
            }
            let mean = RecoveredAcceleration(x: x / 301, y: y / 301, z: z / 301)
            if let previousBlockMean {
                let meanDelta = max(abs(mean.x - previousBlockMean.x),
                                    max(abs(mean.y - previousBlockMean.y),
                                        abs(mean.z - previousBlockMean.z)))
                if meanDelta > delayedThreshold {
                    active = true
                    delayed = true
                    new = lastQualifyingTime == nil
                    // Delayed hits overwrite a possibly larger short/anchor hit.
                    intensity = meanDelta
                }
            }
            previousBlockMean = mean
            blockSamples.removeAll(keepingCapacity: true)
        }

        if active {
            lastQualifyingTime = sample.time
        } else if let last = lastQualifyingTime, sample.time - last > 10 {
            // A gap alone does not reset the latch: this must be a quiet sample.
            lastQualifyingTime = nil
        }
        previousAcceleration = acceleration
        if counter % 100 == 0 {
            anchorAcceleration = acceleration
        }
        counter += 1

        return RecoveredMovement(time: sample.time, newMovement: new,
                                 movementInProgress: active, delayedMovement: delayed,
                                 intensity: intensity, acceleration: acceleration)
    }
}

nonisolated struct RecoveredMovementEvent: Codable, Equatable, Sendable {
    var time: Double
    /// All event types can establish effectiveEnd; only 1 and 2 count as motion.
    var kind: Int
    var intensity: Double

    init(time: Double, kind: Int, intensity: Double) {
        self.time = time
        self.kind = kind
        self.intensity = intensity
    }
}

nonisolated struct RecoveredRecorderBinner: Codable, Sendable {
    var analyzer: RecoveredMovementAnalyzer
    var pendingFast: Double?
    var pendingSlow: Double?
    var boundary: Double?

    init(analyzer: RecoveredMovementAnalyzer = .init()) {
        self.analyzer = analyzer
    }

    /// Call once per actual recorder query, not once per streamed delivery batch.
    /// Analyzer and trailing pending values survive. The boundary alone resets.
    mutating func beginQuery(start: Double) {
        boundary = start + 60
    }

    /// At most two events are returned, delayed first. There is no end/flush API:
    /// a query's trailing partial bin must remain pending into the next query.
    mutating func append(_ sample: RecoveredMotionSample) -> [RecoveredMovementEvent] {
        precondition(boundary != nil, "Begin the recorder query before appending samples")
        let movement = analyzer.update(sample)
        var result: [RecoveredMovementEvent] = []
        if let currentBoundary = boundary, movement.time > currentBoundary {
            if let pendingSlow, pendingSlow > 0 {
                result.append(.init(time: currentBoundary, kind: 2, intensity: pendingSlow))
            }
            if let pendingFast, pendingFast > 0 {
                result.append(.init(time: currentBoundary, kind: 1, intensity: pendingFast))
            }
            pendingFast = nil
            pendingSlow = nil
            // Exactly one increment per sample, including after large gaps.
            boundary = currentBoundary + 60
        }
        if movement.movementInProgress {
            if movement.delayedMovement {
                pendingSlow = movement.intensity
            } else {
                pendingFast = movement.intensity
            }
        }
        return result
    }

    mutating func processQuery(start: Double, samples: [RecoveredMotionSample]) -> [RecoveredMovementEvent] {
        beginQuery(start: start)
        var events: [RecoveredMovementEvent] = []
        for sample in samples {
            events.append(contentsOf: append(sample))
        }
        return events
    }
}

nonisolated struct RecoveredMovementFilter: Codable, Equatable, Sendable {
    var raLimit: Double
    var dLimit: Double

    init(raLimit: Double = 0, dLimit: Double = 0) {
        self.raLimit = raLimit
        self.dLimit = dLimit
    }

    static func scalar(_ value: Double) -> Self {
        Self(raLimit: min(value, 1), dLimit: value >= 1 ? value - 1 : 0)
    }
}

nonisolated struct RecoveredMovementHistory: Codable, Sendable {
    var start: Double
    var sessionEnd: Double?
    var events: [RecoveredMovementEvent]

    init(start: Double, sessionEnd: Double? = nil, events: [RecoveredMovementEvent] = []) {
        self.start = start
        self.sessionEnd = sessionEnd
        self.events = events
    }

    var effectiveEnd: Double {
        if let sessionEnd { return sessionEnd }
        guard let first = events.first else { return start }
        return events.dropFirst().reduce(first.time) { max($0, $1.time) }
    }

    var duration: Double { max(0, effectiveEnd - start) }

    mutating func append(contentsOf newEvents: [RecoveredMovementEvent]) {
        events.append(contentsOf: newEvents)
    }

    func movementsPerHour(filter: RecoveredMovementFilter = .init()) -> Double {
        let end = effectiveEnd
        let cutoff = max(start, min(start + 7200, end - 10800))
        let hours = ((end - cutoff) / 60) / 60
        var count = 0
        for event in events where event.time >= cutoff {
            if (event.kind == 1 && event.intensity >= filter.dLimit)
                || (event.kind == 2 && event.intensity >= filter.raLimit) {
                count += 1
            }
        }
        // There is deliberately no event.time <= effectiveEnd restriction.
        return hours == 0 ? 9.5 : Double(count) / hours
    }

    static func parameterPair(windowSeconds: Double) -> (regular: Double, maximum: Double) {
        let minutes = windowSeconds / 60
        if minutes <= 10 { return (8.5, 11) }
        if minutes <= 15 { return (8, 10.5) }
        if minutes <= 20 { return (7.5, 10) }
        if minutes <= 30 { return (7, 9.5) }
        if minutes <= 45 { return (6, 8.5) }
        if minutes <= 60 { return (5.5, 7) }
        if minutes <= 90 { return (5, 6.5) }
        return (7, 9.5)
    }

    func calculateFilter(target: Double) -> RecoveredMovementFilter {
        guard duration / 3600 >= 2 else { return .init() }
        guard movementsPerHour() >= target else { return .init() }
        return .scalar(searchScalar(target: target))
    }

    func searchScalar(target: Double) -> Double {
        var low = 0.0
        var high = 2.0
        for _ in 0..<41 {
            let midpoint = low + (high - low) * 0.5
            if target <= movementsPerHour(filter: .scalar(midpoint)) {
                low = midpoint
            } else {
                high = midpoint
            }
        }
        return low + (high - low) * 0.5
    }
}

nonisolated enum RecoveredAlarmPhase: Int, Codable, Sendable {
    case noAlarm = 0
    case sleepy = 1
    case armed = 2
    case preArmed = 3
}

nonisolated enum RecoveredWakeReason: String, Codable, Sendable {
    case runtimeLimit = "runtime_limit"
    case deadline = "deadline"
    case sensitiveMovement = "sensitive_movement"
    case twoQualifyingMovements = "two_qualifying_movements"
    case continuedMovement = "continued_movement"
}

nonisolated struct RecoveredAlarmRules: Codable, Sendable {
    var alarmTime: Double
    var windowSeconds: Double
    var history: RecoveredMovementHistory
    var phase: RecoveredAlarmPhase = .noAlarm
    var prearmedTime: Double?
    var armedTime: Double?
    var sensitive = false
    var filter = RecoveredMovementFilter()
    /// Decision history is separate from the analyzer and the armed filter.
    var lastMovementStarted: Double?
    var lastQualifiedTick = -1.0
    var fired = false

    init(alarmTime: Double, windowSeconds: Double, history: RecoveredMovementHistory) {
        self.alarmTime = alarmTime
        self.windowSeconds = windowSeconds
        self.history = history
        begin()
    }

    mutating func begin() {
        armedTime = alarmTime - windowSeconds
        prearmedTime = armedTime
        lastMovementStarted = nil
        phase = .sleepy
    }

    mutating func stop() {
        phase = .noAlarm
        prearmedTime = nil
        armedTime = nil
    }

    mutating func arm() {
        phase = .armed
        fired = false
        let rate = history.movementsPerHour()
        let parameters = RecoveredMovementHistory.parameterPair(windowSeconds: windowSeconds)
        sensitive = rate < parameters.regular
        filter = rate > parameters.maximum
            ? history.calculateFilter(target: parameters.maximum)
            : .init()
        lastQualifiedTick = -1
        // lastMovementStarted is reset by begin(), never by this transition.
    }

    mutating func filterMovement(_ movement: RecoveredMovement) -> RecoveredMovement {
        var result = movement
        result.duration = 0
        guard movement.movementInProgress,
              filter != RecoveredMovementFilter(raLimit: 1, dLimit: 1) else { return result }
        let threshold = movement.delayedMovement ? filter.raLimit : filter.dLimit
        guard threshold <= movement.intensity else {
            result.newMovement = false
            result.movementInProgress = false
            return result
        }
        let previous = lastQualifiedTick
        lastQualifiedTick = movement.time
        result.newMovement = movement.time - previous > 10 || previous == -1
        return result
    }

    /// Pure recovered predicate. The adapter chooses whether to supply it to
    /// receive(); policy must not silently move the user's alarm deadline.
    static func runtimeReserveReached(expirationTime: Double?, now: Double) -> Bool {
        guard let expirationTime else { return false }
        return expirationTime - now < 300
    }

    /// Called after the armed filter. It intentionally does not ignore inactive
    /// samples: deadline/expiration and delayed-history seeding still apply.
    mutating func check(_ movement: RecoveredMovement, forceRuntime: Bool = false) -> RecoveredWakeReason? {
        if forceRuntime {
            fired = true
            return .runtimeLimit
        }
        if movement.time > alarmTime {
            fired = true
            return .deadline
        }
        if sensitive {
            if movement.movementInProgress {
                fired = true
                return .sensitiveMovement
            }
            return nil
        }
        let elapsed = lastMovementStarted.map { movement.time - $0 } ?? Double.greatestFiniteMagnitude
        if movement.newMovement {
            let progress = 1 - (alarmTime - movement.time) / windowSeconds
            if progress * movement.intensity > 0.02 {
                var reason: RecoveredWakeReason?
                if elapsed < 120 {
                    fired = true
                    reason = .twoQualifyingMovements
                }
                lastMovementStarted = movement.time
                return reason
            }
            return nil
        }
        if movement.delayedMovement && movement.intensity > 0.1 && lastMovementStarted == nil {
            lastMovementStarted = movement.time
            return nil
        }
        if !movement.delayedMovement && movement.movementInProgress
            && elapsed > 10 && elapsed < Double.greatestFiniteMagnitude {
            fired = true
            return .continuedMovement
        }
        return nil
    }

    mutating func receive(_ movement: RecoveredMovement, forceRuntime: Bool = false) -> RecoveredWakeReason? {
        guard phase != .noAlarm else { return nil }
        if phase == .sleepy, let prearmedTime, movement.time > prearmedTime {
            phase = .preArmed
        }
        guard phase != .sleepy else { return nil }
        if phase == .preArmed, let armedTime, movement.time > armedTime {
            arm()
        }
        guard phase != .preArmed, !fired else { return nil }
        return check(filterMovement(movement), forceRuntime: forceRuntime)
    }
}
