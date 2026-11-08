# Production Smart Wake validation

These checks compile the application's actual Swift sources. They are separate
from the **6,654 original-instruction comparisons** used to establish the
recovered reference. No vendor code, decrypted binary, license data, network
access, Python package installation, or physical device is required.

Run from the repository root with the installed Xcode toolchain:

```sh
python3 tests/SmartWakeParity/run.py
python3 tests/SmartWakeParity/run_integration.py
python3 tests/SmartWakeParity/run_phone_handoff.py
```

The Swift drivers use Swift 5 language mode with default MainActor isolation,
matching the application's concurrency settings. They run as native macOS
processes. Watch/iPhone/widget builds and watchOS Simulator launch are separate
validation steps; see the production integration report.

## Results

| Suite | Passing checks | Evidence |
| --- | ---: | --- |
| Production Swift versus independent Python reference | 13,870 in 764 input cases | `port-proof.json` |
| Application execution policy, actor, completion ledger, pending occurrence recovery | 58 | `integration-proof.json` |
| Recorder acquisition, delayed delivery, checkpoints and restart | 54 | `integration-proof.json` |
| Phone/watch message schema compatibility | 12 (6 per model copy) | `integration-proof.json` |
| Production phone coordinator and SwiftData light-handoff behavior | 19 | `phone-handoff-proof.json` |

Reports record source hashes so later edits can be distinguished from the tested
revision. `run.py` regenerates its report after compiling the core; replay
differences cause a nonzero exit. Integration assertions fail the process rather
than writing a passing report.

## Reference replay coverage

`run.py` imports `plans/sleep-cycle-watch/WatchAlgorithmReference.py` and passes
identical deterministic timestamped input to it and
`Lights Timer Watch App/Services/RecoveredMovementCore.swift`.

- **13,061 detector samples:** fixed default D, constructor threshold calculation
  around D=0.04, strict instantaneous and delayed threshold equality, previous
  sample and 100-sample anchor updates, 301/602/903 block boundaries, delayed
  intensity overwrite, quiet-sample rearming versus active samples after a gap,
  timestamp preservation, sample-count behavior at 40/50 Hz, deterministic random
  XYZ, and constructor-derived R surviving a later D change. Every sample compares
  movement flags/intensity/raw XYZ and the entire retained buffer, counter,
  previous vector, anchor, block mean and last-qualifying timestamp.
- **11 recorder-query states:** boundary equality, last intensity rather than
  maximum, delayed-before-ordinary event ordering, one boundary advance per
  sample after a large gap, cross-query analyzer/pending-state persistence, empty
  history and no trailing partial flush.
- **26 window-table cases:** all seven inclusive upper bounds and both sides,
  zero, the 25-minute application default and the over-90-minute fallback.
- **35 historical-rate/filter cases:** empty/sparse history, effective end from
  all event kinds, explicit-end behavior, inclusive cutoff/intensity comparisons,
  the exact two-hour eligibility boundary, and the 41-step binary search.
- **152 armed-filter cases, 486 decision cases, 94 lifecycle states:** inclusive
  intensity thresholds, strict 10-second regrouping, `(1,1)` bypass, strict 0.02,
  0.1, 10-second and 120-second decisions, distinct filter/decision timestamps,
  inactive delayed-event seeding, runtime-before-deadline ordering, exact window
  boundary, mode selection, stop/begin/arm reset behavior and fired suppression.
- **5 runtime-predicate cases:** missing expiration and strict remaining-time
  `<300` comparison, including equality. This helper remains distinct from
  Lights Timer's application execution policy.

State is also encoded/decoded mid-stream to exercise restoration. Integer,
Boolean, phase, reason and timestamp comparisons are exact. Other floating-point
outputs allow absolute `1e-10` / relative `1e-12` error for arithmetic/library
rounding. Branch decisions still compare exactly. Stop behavior and the runtime
reserve predicate are compared to their documented semantics in `ALARM.md` and
`RUNTIME.md`; other expectations call the Python reference directly.

## Application and acquisition coverage

`IntegrationChecks.swift` executes the actual actor and pure execution policy.
It verifies that HR only updates telemetry, duplicate/out-of-order/nonfinite live
samples cannot mutate the detector, timer ticks cannot synthesize motion,
calibration occurs before arming and remains frozen afterward, inactive samples
still reach deadline checks, and both firing latches suppress duplicates.
It distinguishes genuinely zero-duration history (fallback rate 9.5) from a quiet
overnight session. The non-motion wake-phase lifecycle event establishes that
session's effective end without counting as movement, yielding a zero event rate
and sensitive mode when no movement events were recovered.

The application deadline remains `now >= selectedWakeTime`, including late startup.
Scheduling retains `max(windowStart - 120 seconds, wakeTime - 1500 seconds)`.
Tests check seven window sizes and show that a nominal 30-minute runtime's
five-minute reserve cannot advance the selected deadline under that scheduling
formula. The production actor intentionally does not pass an OS expiration
reserve as an early-wake override; the recovered core still implements it for
parity. Real runtime duration remains controlled by watchOS.

Persistence checks use isolated temporary UserDefaults suites. They reconstruct
completion and pending-wake stores, verify full occurrence/`armedAt`/one-day
override recovery without connectivity hydration, preserve a false
`isSessionScheduled` placeholder, cover legacy missing fields, and check bounded
completion retention plus malformed storage. These exercise storage and policy;
they do not simulate WatchKit's recovered-session callback.

`RecorderChecks.swift` executes the production acquisition state and disk loader.
It verifies bounded raw buffers, schema/occurrence validation, duplicate delivery,
finite XYZ, actual timestamps, empty reads, partial-bin preservation, fixed
logical hour boundaries and delayed tail delivery. Seven interrupt points
(1/100/300/301/601/3001/9999 samples) produce exactly the same complete state after
JSON restoration and duplicate boundary delivery as uninterrupted processing.
A 50 Hz hour replay checkpoints at 3590 seconds, then delivers the late tail and
next hour; its complete state matches uninterrupted delivery and the parity-tested
core binner. Unsupported checkpoint schemas and oversized files are discarded.

`PhoneHandoffChecks.swift` uses the production coordinator and in-memory SwiftData.
Only HomeKit effects, connectivity transport and logging are test doubles. It
checks accepted, rejected and duplicate handoffs, fallback decisions, trigger
freshness and matching one-day occurrences. This proves ownership decisions,
not physical accessory writes or WCSession delivery.

## Physical-device validation still required

- Overnight requested 40 Hz raw accelerometer delivery and actual recorder
  cadence/lag, authorization changes, and interrupted sensor callbacks.
- Process termination/relaunch and synchronous recovered runtime attachment on
  watchOS, including late launch and runtime-expiration behavior.
- Exact-time/user-selected haptics, phone positive/negative/missing acknowledgement,
  deferred watch HomeKit fallback, and independent HomeKit fallback scenes.
- Overnight battery use, recorder processing cost and wake experience across
  several nights. Replay parity is not a clinical sleep-stage or accuracy claim.
