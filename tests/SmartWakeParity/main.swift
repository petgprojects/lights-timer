// Compiled alongside the production core by run.py; never part of an app target.
import Foundation

typealias Object = [String: Any]
let null = NSNull()
func number(_ o: Object, _ key: String, _ fallback: Double = 0) -> Double { (o[key] as? NSNumber)?.doubleValue ?? fallback }
func flag(_ o: Object, _ key: String, _ fallback: Bool = false) -> Bool { o[key] as? Bool ?? fallback }
func optionalNumber(_ o: Object, _ key: String) -> Double? { (o[key] as? NSNumber)?.doubleValue }
func optional(_ value: Any?) -> Any { value ?? null }
func vector(_ a: RecoveredAcceleration?) -> Any { a.map { [$0.x, $0.y, $0.z] } as Any? ?? null }
func sample(_ values: [Double]) -> RecoveredMotionSample {
    .init(time: values[0], acceleration: .init(x: values[1], y: values[2], z: values[3]))
}
func motion(_ o: Object) -> RecoveredMovement {
    .init(time: number(o, "time", 1000), newMovement: flag(o, "new"), movementInProgress: flag(o, "active"),
          delayedMovement: flag(o, "delayed"), intensity: number(o, "intensity"), duration: number(o, "duration"))
}
func movementJSON(_ m: RecoveredMovement) -> Object {
    ["time": m.time, "new": m.newMovement, "active": m.movementInProgress, "delayed": m.delayedMovement,
     "intensity": m.intensity, "duration": m.duration, "acceleration": vector(m.acceleration)]
}
func analyzerJSON(_ a: RecoveredMovementAnalyzer) -> Object {
    ["limit": a.dLimit, "threshold": a.delayedThreshold, "previous": vector(a.previousAcceleration),
     "anchor": vector(a.anchorAcceleration), "mean": vector(a.previousBlockMean), "counter": a.counter,
     "buffer": a.blockSamples.map { [$0.x, $0.y, $0.z] }, "last": optional(a.lastQualifyingTime)]
}
func history(_ o: Object) -> RecoveredMovementHistory {
    let events = (o["events"] as? [[Double]] ?? []).map { RecoveredMovementEvent(time: $0[0], kind: Int($0[1]), intensity: $0[2]) }
    return .init(start: number(o, "start"), sessionEnd: optionalNumber(o, "end"), events: events)
}
func filter(_ o: Object) -> RecoveredMovementFilter { .init(raLimit: number(o, "slow"), dLimit: number(o, "fast")) }
func filterJSON(_ f: RecoveredMovementFilter) -> Object { ["fast": f.dLimit, "slow": f.raLimit] }
func alarmJSON(_ a: RecoveredAlarmRules) -> Object {
    ["phase": a.phase.rawValue, "sensitive": a.sensitive, "filter": filterJSON(a.filter),
     "last": optional(a.lastMovementStarted), "lastTick": a.lastQualifiedTick, "fired": a.fired]
}
func makeAlarm(_ o: Object) -> RecoveredAlarmRules {
    var a = RecoveredAlarmRules(alarmTime: number(o, "deadline", 1300), windowSeconds: number(o, "window", 600), history: history(o))
    if let p = o["phase"] as? Int { a.phase = RecoveredAlarmPhase(rawValue: p)! }
    if o["sensitive"] != nil { a.sensitive = flag(o, "sensitive") }
    if o["fired"] != nil { a.fired = flag(o, "fired") }
    if o["fast"] != nil || o["slow"] != nil { a.filter = filter(o) }
    if o["last"] != nil { a.lastMovementStarted = optionalNumber(o, "last") }
    if o["lastTick"] != nil { a.lastQualifiedTick = number(o, "lastTick") }
    return a
}
func evaluate(_ o: Object) throws -> Any {
    switch o["kind"] as! String {
    case "detector":
        var a = RecoveredMovementAnalyzer(dLimit: number(o, "limit", 0.09000000000000001))
        let mutations = o["limitChanges"] as? [String: Double] ?? [:]
        let snapshots = Set(o["roundTrips"] as? [Int] ?? [])
        var result: [Object] = []
        for (index, values) in (o["samples"] as! [[Double]]).enumerated() {
            if let d = mutations[String(index)] { a.dLimit = d }
            if snapshots.contains(index) { a = try JSONDecoder().decode(RecoveredMovementAnalyzer.self, from: JSONEncoder().encode(a)) }
            let m = a.update(sample(values))
            result.append(["movement": movementJSON(m), "state": analyzerJSON(a)])
        }
        return result
    case "binner":
        var b = RecoveredRecorderBinner()
        var result: [Object] = []
        for query in o["queries"] as! [Object] {
            if flag(query, "roundTrip") { b = try JSONDecoder().decode(RecoveredRecorderBinner.self, from: JSONEncoder().encode(b)) }
            let samples = (query["samples"] as! [[Double]]).map(sample)
            let events = b.processQuery(start: number(query, "start"), samples: samples)
            result.append(["events": events.map { ["time": $0.time, "kind": $0.kind, "intensity": $0.intensity] },
                           "analyzer": analyzerJSON(b.analyzer), "fast": optional(b.pendingFast), "slow": optional(b.pendingSlow)])
        }
        return result
    case "history":
        let h = history(o), target = number(o, "target", 9.5)
        return ["end": h.effectiveEnd, "rate": h.movementsPerHour(filter: filter(o)),
                "filter": filterJSON(h.calculateFilter(target: target)), "scalar": h.searchScalar(target: target)]
    case "parameters":
        let pair = RecoveredMovementHistory.parameterPair(windowSeconds: number(o, "window"))
        return [pair.regular, pair.maximum]
    case "filter":
        var a = makeAlarm(o)
        let m = a.filterMovement(motion(o))
        return ["movement": movementJSON(m), "state": alarmJSON(a)]
    case "decision":
        var a = makeAlarm(o)
        let reason = a.check(motion(o), forceRuntime: flag(o, "forceRuntime"))
        return ["reason": optional(reason?.rawValue), "state": alarmJSON(a)]
    case "alarm":
        var a = makeAlarm(o)
        var result: [Object] = []
        for step in o["steps"] as! [Object] {
            if flag(step, "roundTrip") { a = try JSONDecoder().decode(RecoveredAlarmRules.self, from: JSONEncoder().encode(a)) }
            var reason: RecoveredWakeReason?
            switch step["operation"] as? String ?? "receive" {
            case "begin": a.begin()
            case "stop": a.stop()
            case "arm": a.arm()
            default: reason = a.receive(motion(step), forceRuntime: flag(step, "forceRuntime"))
            }
            result.append(["reason": optional(reason?.rawValue), "state": alarmJSON(a)])
        }
        return result
    case "runtime":
        return RecoveredAlarmRules.runtimeReserveReached(expirationTime: optionalNumber(o, "expiration"), now: number(o, "now"))
    default: fatalError("Unknown request")
    }
}

do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let requests = try JSONSerialization.jsonObject(with: input) as! [Object]
    let outputs = try requests.map(evaluate)
    let data = try JSONSerialization.data(withJSONObject: outputs, options: [.sortedKeys, .fragmentsAllowed])
    FileHandle.standardOutput.write(data)
} catch {
    FileHandle.standardError.write(Data("Parity driver failed: \(error)\n".utf8))
    exit(1)
}
