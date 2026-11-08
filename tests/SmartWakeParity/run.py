#!/usr/bin/env python3
"""Compile the production Swift core and compare deterministic inputs with the research model.

No vendor binary, App Store installation, emulator, network, or device is used.
Counts below are NEW Swift-port comparisons, not the 6,654 reconstruction probes.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import importlib.util
import itertools
import json
import math
from pathlib import Path
import random
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "Lights Timer Watch App/Services/RecoveredMovementCore.swift"
REFERENCE = ROOT / "plans/sleep-cycle-watch/WatchAlgorithmReference.py"
DRIVER = Path(__file__).with_name("main.swift")
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("watch_reference", REFERENCE)
ref = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = ref
spec.loader.exec_module(ref)


def movement(o):
    return ref.Movement(o.get("time", 1000), o.get("new", False), o.get("active", False),
                        o.get("delayed", False), o.get("intensity", 0), o.get("duration", 0))


def movement_json(m):
    return dict(time=m.date, new=m.new, active=m.active, delayed=m.delayed,
                intensity=m.intensity, duration=m.duration, acceleration=None)


def analyzer_json(a):
    return dict(limit=a.limit, threshold=a.threshold, previous=a.prev, anchor=a.long,
                mean=a.avg, counter=a.counter, buffer=list(a.buf), last=a.last)


def filter_json(f):
    return dict(fast=f.d, slow=f.ra)


def alarm_json(a):
    return dict(phase=a.phase, sensitive=a.sensitive, filter=filter_json(a.filt),
                last=a.last_start, lastTick=a.last_qualified_tick, fired=a.fired)


def make_alarm(o):
    a = ref.AlarmRules(o.get("deadline", 1300), o.get("window", 600), o.get("start", 0),
                       [ref.Event(*e) for e in o.get("events", [])], o.get("end"))
    for key, attr in (("phase", "phase"), ("sensitive", "sensitive"), ("fired", "fired"),
                      ("last", "last_start"), ("lastTick", "last_qualified_tick")):
        if key in o:
            setattr(a, attr, o[key])
    if "slow" in o or "fast" in o:
        a.filt = ref.Filter(o.get("slow", 0), o.get("fast", 0))
    return a


def expected(o):
    kind = o["kind"]
    if kind == "detector":
        a = ref.FastMovementAnalyzer(o.get("limit", ref.detector_d_limit()))
        outputs = []
        for i, (t, *v) in enumerate(o["samples"]):
            a.limit = o.get("limitChanges", {}).get(str(i), a.limit)
            m = a.update(t, tuple(v))
            outputs.append(dict(movement=dict(time=t, new=m["new"], active=m["inProgress"],
                                              delayed=m["delayed"], intensity=m["intensity"], duration=0, acceleration=v),
                                state=analyzer_json(a)))
        return outputs
    if kind == "binner":
        b = ref.RecorderEventBinner()
        outputs = []
        for q in o["queries"]:
            events = b.process_query(q["start"], [(r[0], tuple(r[1:])) for r in q["samples"]])
            outputs.append(dict(events=[dict(time=e.date, kind=e.kind, intensity=e.intensity) for e in events],
                                analyzer=analyzer_json(b.analyzer), fast=b.pending_fast, slow=b.pending_slow))
        return outputs
    if kind == "parameters":
        return ref.parameter_pair(o["window"])
    if kind == "history":
        s, e, events = o.get("start", 0), o.get("end"), [ref.Event(*v) for v in o.get("events", [])]
        f = ref.Filter(o.get("slow", 0), o.get("fast", 0))
        target = o.get("target", 9.5)
        return dict(end=ref.effective_end(s, e, events), rate=ref.movements_per_hour(s, e, events, f),
                    filter=filter_json(ref.calculate_filter(target, s, e, events)),
                    scalar=ref.search_scalar(target, s, e, events))
    if kind in ("filter", "decision"):
        a = make_alarm(o)
        if kind == "filter":
            return dict(movement=movement_json(a.filter_movement(movement(o))), state=alarm_json(a))
        return dict(reason=a.check(movement(o), o.get("forceRuntime", False)), state=alarm_json(a))
    if kind == "alarm":
        a, outputs = make_alarm(o), []
        for step in o["steps"]:
            operation, reason = step.get("operation", "receive"), None
            if operation == "begin":
                a.begin()
            elif operation == "arm":
                a.arm()
            elif operation == "stop":
                # Static stop semantics in ALARM.md; reference exposes begin/arm only.
                a.phase, a.armed_time, a.prearmed_time = 0, None, None
            else:
                reason = a.receive(movement(step), step.get("forceRuntime", False))
            outputs.append(dict(reason=reason, state=alarm_json(a)))
        return outputs
    if kind == "runtime":
        # Runtime predicate is in RUNTIME.md and original instruction probes.
        return o.get("expiration") is not None and o["expiration"] - o.get("now", 0) < 300
    raise AssertionError(kind)


def cases():
    result = []

    def add(name, kind, **kwargs):
        result.append(dict(name=name, kind=kind, **kwargs))

    d = ref.detector_d_limit()
    for limit in (0, 0.039999999999, 0.04, 0.040000000001, d, 0.327, 0.5):
        samples = [[i / 40, 0 if i < 301 else 0.05, 0, 1] for i in range(904)]
        add(f"constructor_{limit}_blocks_301_602_903", "detector", limit=limit, samples=samples,
            roundTrips=[100, 300, 301, 601, 602])
    for delta in (math.nextafter(d, -math.inf), d, math.nextafter(d, math.inf)):
        add(f"strict_instantaneous_threshold_{delta!r}", "detector", samples=[[0, 0, 0, 1], [0.025, delta, 0, 1]])
    add("anchor_refresh_after_detection_100", "detector",
        samples=[[i / 40, i * 0.001, 0, 1] for i in range(405)])
    overwrite = [[i / 40, 0 if i < 301 else (0.5 if i == 601 else 0.01), 0, 1] for i in range(603)]
    add("delayed_intensity_overwrites_larger_instantaneous_hit", "detector", samples=overwrite)
    r = ref.FastMovementAnalyzer().threshold
    for target in (math.nextafter(r, -math.inf), r, math.nextafter(r, math.inf)):
        add(f"strict_delayed_threshold_{target!r}", "detector", samples=[
            [i / 40, target * 301 if i == 601 else 0, 0, 1] for i in range(602)])
    quiet = [[i / 40, 0 if i == 0 else 0.2, 0, 1] for i in range(102)]
    quiet += [[12.5, 0.2, 0, 1], [12.500001, 0.2, 0, 1], [12.6, 0.4, 0, 1], [100, 0.6, 0, 1]]
    add("quiet_10_second_rearm_and_active_gap_no_reset", "detector", samples=quiet)
    add("constructor_delayed_threshold_does_not_follow_limit_setter", "detector",
        samples=overwrite, limitChanges={"301": 0.8}, roundTrips=[301])
    rng = random.Random(20261107)
    for cadence in (40, 50):
        t, samples = 1000000000.0, []
        for i in range(1600):
            t += 1 / cadence if i % 423 else 25.0
            samples.append([t, rng.uniform(-0.25, 0.25), rng.uniform(-0.04, 0.04), 1 + rng.uniform(-0.1, 0.1)])
        add(f"seeded_raw_xyz_{cadence}hz_actual_timestamps", "detector", samples=samples,
            roundTrips=[99, 100, 300, 601, 1600])
    add("nonmonotonic_finite_timestamps_are_core_inputs", "detector",
        samples=[[0, 0, 0, 1], [1, 0.2, 0, 1], [-5, 0.5, 0, 1], [300, 0.5, 0, 1]])

    # Per-query boundary resets, retained analyzer/pending events, no partial flush.
    add("recorder_empty_queries_and_partial_bin", "binner", queries=[
        dict(start=0, samples=[]), dict(start=0, samples=[[0, 0, 0, 1], [1, 0.3, 0, 1]]),
        dict(start=30, samples=[], roundTrip=True), dict(start=60, samples=[[120, 0.5, 0, 1], [120.001, 0.6, 0, 1]])])
    add("recorder_last_not_max_and_strict_boundary", "binner", queries=[
        dict(start=0, samples=[[0, 0, 0, 1], [1, 0.8, 0, 1], [59, 0.2, 0, 1], [60, 0.3, 0, 1], [60.001, 0.4, 0, 1]])])
    add("recorder_gap_advances_one_boundary_per_sample", "binner", queries=[
        dict(start=0, samples=[[0, 0, 0, 1], [1, 0.3, 0, 1], [300, 0.8, 0, 1], [301, 0.2, 0, 1], [302, 0.6, 0, 1]])])
    samples = [[i / 5, 0 if i < 301 else (0.5 if i == 601 else 0.01), 0, 1] for i in range(1000)]
    add("recorder_delayed_first_and_live_state_survives_chunks", "binner", queries=[
        dict(start=0, samples=samples[:300]), dict(start=60, samples=samples[300:602], roundTrip=True),
        dict(start=120.4, samples=samples[602:], roundTrip=True)])
    add("recorder_hour_chunks_at_delivered_50hz", "binner", queries=[
        dict(start=0, samples=[[3598 + i / 50, 0.2 * (i % 2), 0, 1] for i in range(100)]),
        dict(start=3600, samples=[[3600 + i / 50, 0.01 * (i // 301), 0, 1] for i in range(3100)], roundTrip=True)])

    for upper in (0, 600, 900, 1200, 1800, 2700, 3600, 5400):
        for delta in (-0.000001, 0, 0.000001):
            add(f"window_{upper}_{delta}", "parameters", window=upper + delta)
    add("window_25_minutes", "parameters", window=1500)
    add("window_over_90_fallback", "parameters", window=7200)

    history_events = [[i * 300, 1 + i % 2, (i % 7 + 1) * 0.07] for i in range(100)]
    for end in (None, 0, 7199.999999, 7200, 7200.000001, 10800, 17999.999999, 18000, 28800):
        for ev in ([], history_events):
            add(f"history_duration_{end}_{bool(ev)}", "history", end=end, events=ev)
    for target in (0, 7, 9.5, 10, 100):
        add(f"history_search_target_{target}", "history", end=7200, events=history_events, target=target)
    for offset in (-0.000001, 0, 0.000001):
        add(f"history_cutoff_inclusive_{offset}", "history", end=28800,
            events=[[7200 + offset, 1, 0.1], [7200 + offset, 2, 0.2]], fast=0.1, slow=0.2)
    for intensity in (0.199999999, 0.2, 0.200000001):
        add(f"history_intensity_inclusive_{intensity}", "history", end=7200,
            events=[[100, 1, intensity], [200, 2, intensity]], fast=0.2, slow=0.2)
    add("history_effective_end_all_event_kinds", "history", start=10, events=[[20, 1, 0.2], [7200, 7, 0]])
    add("history_explicit_end_has_no_event_upper_bound", "history", end=7200, events=[[8000, 1, 1], [9000, 2, 1]])
    add("history_pre_session_end_negative_rate", "history", start=100, end=50, events=[[100, 1, 0.2]])
    for end in (7199.999999, 7200, 7200.000001):
        add(f"calibration_two_hour_guard_{end}", "history", end=end,
            events=[[100 + i * 100, 1 + i % 2, 0.4] for i in range(40)])

    for active, new, delayed in itertools.product((False, True), repeat=3):
        for intensity in (0.099999999, 0.1, 0.100000001, 0.199999999, 0.2, 0.200000001):
            for last_tick in (-1, 990, 989.999999):
                add(f"filter_{active}_{new}_{delayed}_{intensity}_{last_tick}", "filter",
                    active=active, new=new, delayed=delayed, intensity=intensity, fast=0.1, slow=0.2,
                    lastTick=last_tick, duration=99, phase=2)
    for active, new, delayed in itertools.product((False, True), repeat=3):
        add(f"filter_exact_1_1_bypass_{active}_{new}_{delayed}", "filter", active=active, new=new,
            delayed=delayed, intensity=0.05, fast=1, slow=1, lastTick=123, duration=7, phase=2)

    for sensitive, new, active, delayed in itertools.product((False, True), repeat=4):
        for intensity in (0, 0.04, 0.040000001, 0.1, 0.100000001):
            for last in (None, 990, 989.999999, 880, 880.000001, 1001):
                add(f"decision_{sensitive}_{new}_{active}_{delayed}_{intensity}_{last}", "decision",
                    sensitive=sensitive, new=new, active=active, delayed=delayed, intensity=intensity, last=last, phase=2)
    for timestamp in (1299.999999, 1300, 1300.000001):
        for runtime in (False, True):
            add(f"deadline_order_{timestamp}_{runtime}", "decision", time=timestamp, forceRuntime=runtime,
                sensitive=True, active=False, phase=2)

    for phase, fired in itertools.product(range(4), (False, True)):
        for timestamp in (699.999999, 700, 700.000001):
            add(f"phase_{phase}_{fired}_{timestamp}", "alarm", phase=phase, fired=fired,
                steps=[dict(time=timestamp), dict(time=1300.000001, roundTrip=True), dict(time=1301)])
    add("filtered_inactive_delayed_seeds_decision_history", "alarm", phase=2, slow=0.5,
        steps=[dict(time=1000, delayed=True, active=True, new=True, intensity=0.2),
               dict(time=1009, active=True, intensity=0.1), dict(time=1011, active=True, intensity=0.1), dict(time=1012)])
    add("sensitive_fire_then_duplicate_suppression", "alarm", phase=2, sensitive=True,
        steps=[dict(time=1000, active=True, intensity=0.2), dict(time=1001, active=True, intensity=0.3, roundTrip=True), dict(time=1400)])
    add("stop_begin_arm_reset_semantics", "alarm", phase=2, fired=True, last=400, lastTick=500, fast=0.2, slow=0.3,
        steps=[dict(operation="stop"), dict(time=1400), dict(operation="begin", roundTrip=True),
               dict(time=700), dict(time=700.01), dict(time=1300.01)])
    for rate in (6.999999, 7, 7.000001, 9.499999, 9.5, 9.500001):
        add(f"arming_mode_rate_{rate}", "alarm", window=1800, deadline=2000,
            start=0, end=3600 / rate, events=[[10, 1, 0.5]], steps=[dict(time=201)])
    add("empty_history_ordinary_mode", "alarm", window=1800, deadline=2000, steps=[dict(time=201)])
    add("sparse_history_sensitive_mode", "alarm", window=1800, deadline=2000, end=28800,
        events=[[8000, 1, 0.1]], steps=[dict(time=201), dict(time=202, active=True, intensity=0.2)])
    for remaining in (None, -1, 299.999999, 300, 300.000001):
        add(f"runtime_reserve_strict_{remaining}", "runtime", now=1000,
            expiration=None if remaining is None else 1000 + remaining)
    return result


def mismatches(actual, wanted, path=""):
    if isinstance(wanted, dict):
        if not isinstance(actual, dict) or actual.keys() != wanted.keys():
            return [(path, actual, wanted)]
        return [v for k in wanted for v in mismatches(actual[k], wanted[k], f"{path}.{k}")]
    if isinstance(wanted, (list, tuple)):
        if not isinstance(actual, list) or len(actual) != len(wanted):
            return [(path + ".length", len(actual) if isinstance(actual, list) else actual, len(wanted))]
        return [v for i, (a, e) in enumerate(zip(actual, wanted)) for v in mismatches(a, e, f"{path}[{i}]")]
    if isinstance(wanted, bool) or wanted is None or isinstance(wanted, str):
        return [] if actual == wanted and (not isinstance(wanted, bool) or isinstance(actual, bool)) else [(path, actual, wanted)]
    if isinstance(wanted, int):
        return [] if actual == wanted else [(path, actual, wanted)]
    if path.endswith((".time", ".last", ".lastTick", ".limit", ".end")):
        return [] if actual == wanted else [(path, actual, wanted)]
    # Branches and timestamps above are exact; tolerate cross-language libm/norm roundoff.
    return [] if isinstance(actual, (int, float)) and math.isclose(actual, wanted, rel_tol=1e-12, abs_tol=1e-10) else [(path, actual, wanted)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).with_name("port-proof.json"))
    args = parser.parse_args()
    vectors = cases()
    counts, failures = Counter(), []
    with tempfile.TemporaryDirectory(prefix="lights-smartwake-parity-") as folder:
        binary = Path(folder) / "parity"
        compile_args = ["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor", str(CORE), str(DRIVER), "-o", str(binary)]
        subprocess.run(compile_args, check=True)
        # Batches limit the replay driver's resident memory, including per-sample retained state.
        for begin in range(0, len(vectors), 20):
            batch = vectors[begin:begin + 20]
            proc = subprocess.run([str(binary)], input=json.dumps(batch), text=True, capture_output=True, check=True)
            actuals = json.loads(proc.stdout)
            for case, actual in zip(batch, actuals):
                want = expected(case)
                count = len(want) if case["kind"] in ("detector", "binner", "alarm") else 1
                counts[case["kind"]] += count
                differences = mismatches(actual, want)
                if differences:
                    failures.append(dict(name=case["name"], differences=differences[:20]))
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in (CORE, REFERENCE, DRIVER, Path(__file__))}
    report = dict(status="passed" if not failures else "failed", port_comparisons=sum(counts.values()),
                  vector_cases=len(vectors), comparisons_by_kind=dict(counts), failures=failures,
                  floating_point_tolerance=dict(relative=1e-12, absolute=1e-10),
                  integer_boolean_phase_reason_comparisons="exact",
                  source_sha256=hashes, swift_version=subprocess.check_output(["xcrun", "swiftc", "--version"], text=True).strip(),
                  compile_flags=["-swift-version", "5", "-default-isolation", "MainActor"],
                  scope="Native macOS replay of actual production Swift core against independent Python reference. Full retained detector state compared on every sample. Codable restoration included. No vendor binary or device used.",
                  original_instruction_reconstruction_checks=6654,
                  original_instruction_checks_are_not_included_in_port_count=True,
                  reference_extensions=["Stop lifecycle semantics and runtime <300-second predicate are specified in ALARM.md/RUNTIME.md; other expected outputs call WatchAlgorithmReference.py directly."],
                  excluded=["watchOS recovery callbacks", "physical sensor cadence and delivery", "overnight accuracy and battery", "haptics", "HomeKit", "WCSession delivery"])
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: report[k] for k in ("status", "port_comparisons", "vector_cases", "comparisons_by_kind")}, indent=2))
    if failures:
        print(json.dumps(failures[:3], indent=2))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
