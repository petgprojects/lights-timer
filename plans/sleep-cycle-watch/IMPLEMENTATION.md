# Production integration: recovered watch movement algorithm

Implemented November 7, 2026. The production algorithm identity is
`recovered-watch-movement-v1`. This is independently written Swift from the
actual watch specification and executable Python reference. No vendor binary,
license metadata, or decompiler output is included in an app target.

## Production structure

- `Lights Timer Watch App/Services/RecoveredMovementCore.swift`: deterministic,
  nonisolated Codable/Sendable detector, historical binner/rate/calibration,
  armed filter, phase machine, deadline/expiration ordering and fired latch.
- `WakeHeuristicEngine.swift`: actor adapter. It initializes a fresh live
  analyzer for each monitoring run, supplies recorded events before the first
  live notification, and freezes calibration on entry to armed. Heart rate
  updates telemetry only. Timer callbacks do not fabricate movement events.
- `SmartWakeRecorderPipeline.swift`: separate actor for blocking recorder
  enumeration, history processing and atomic checkpoint I/O. It retains at most
  300 incomplete-block vectors, a few previous vectors, and bounded minute events.
- `SmartWakeSessionController.swift`: requests raw XYZ at 40 Hz and maps sensor
  uptime through a fixed boot-date offset. One bounded FIFO consumer preserves
  accepted sample order. Recording uses raw XYZ/startDate at delivered cadence.
  Exact-wake timer/watchdog are installed before the first suspension; initial
  recorder history completes before live notifications can arm/calibrate.
- `SmartWakeExecutionPolicy.swift`: explicit application timing/ownership policy
  and persistent occurrence-completion ledger. Scheduler, recovery, selected
  haptics, phone acknowledgement, deferred watch writes and HomeKit scenes stay
  in the existing service graph.
- Phone `SmartWakeOccurrenceArchiveService.swift` replaces HealthKit tuning with
  an archive. Removed `SmartWakeCalibrationService.swift` and
  `SmartWakeSettingsStore.swift`. Existing archived summaries remain readable.

## Algorithm behavior

The port preserves fixed D and constructor-derived R; previous/100-sample anchor
comparisons; non-overlapping 301-sample axis means; delayed intensity overwrite;
quiet-sample rearming; strict/inclusive comparison boundaries and evaluation
order. Historical minute events retain the **last** qualifying category value,
append delayed before ordinary, advance one boundary per sample, retain pending
state across logical queries, and never flush the final partial bin.

The core implements the complete window parameter table, effective end from any
session event, two-hour calibration guard, 41-step scalar search, armed-filter
regrouping, separate movement timestamps, inactive delayed-event seeding, phase
transitions, strict deadline/expiration ordering, begin/stop/reset and fired latch.

`RUNTIME.md` records a session event at `beginWakeupPhase` before processing
history. The adapter records its actual monitoring-start time as its own
**non-counting kind-0 lifecycle marker**; kind 0 is not asserted to be the vendor's
encoding. `ALARM.md` establishes that all event types can set effective end.
Thus genuinely zero-duration history has the reference 9.5/hour fallback, while
an elapsed quiet night with a lifecycle marker and no movement events has rate 0
and sensitive mode. There is no invented motion, rolling `sessionEnd = now`,
HR-based threshold, or phone HealthKit calibration.

## Explicit application policies and adaptations

| Area | Lights Timer policy |
| --- | --- |
| Runtime start | Retains `max(windowStart - 120s, wakeTime - 1500s)`, with true foreground checks and existing scheduling horizon. Windows longer than 25 minutes have bounded runtime coverage. |
| Five-minute reserve | The parity core implements strict remaining-runtime `<300s` before sample-time `>deadline`. Production does **not** pass this OS-expiration override. A shortened runtime must not move the selected alarm deadline earlier. Independent exact-wake enforcement uses wall-clock `>=wakeTime`. Expiration/invalidation still request immediate checks. |
| Runtime lost before wake | No new background runtime is fabricated; foreground rearm state and independent exact-time HomeKit scenes remain. Watch haptics cannot be guaranteed if watchOS removes execution before the deadline. |
| Haptics | Retains the user's selected Lights Timer pattern, immediate onset and existing system notification, rather than copying the vendor sequence. |
| Live delivery | Requested 40 Hz, actual sensor timestamps. FIFO holds 800 samples (20 seconds at requested cadence); overload drops new samples and subsequent sensor gaps appear in telemetry. Duplicate, nonfinite and out-of-order delivery is rejected **outside** the exact core. No resampling or gap-based detector reset. |
| Recording | Each request is capped at 12 hours. Foreground preparation renews capture if an earlier capped request does not reach the wake. Monitoring can retry preparation. |
| History retrieval | From persisted `armedAt` to `min(now - 30s, wakeTime)`, refreshed each 60s. Actual last accepted timestamp is the transport cursor. Logical contiguous hour queries are anchored at `armedAt`, preserving analyzer/pending-bin/boundary across transport retries and process restarts. This makes delayed-tail delivery equivalent to uninterrupted logical queries. Empty or partially available responses never advance past unreturned data. |
| Older hardware | Uses the documented modern-watch all-samples path. Does not implement the obsolete model-prefix <4 skip/decimation policy. |
| Relaunch | Persisted pending ownership and `armedAt` remain authoritative before connectivity hydration. History resumes; live analyzer/rules restart for a new monitoring run, as the documented runtime creates a fresh live detector. Completed occurrences do not restart. Overdue uncompleted recovered running sessions enforce exact wake immediately. |
| Acquisition limits | 36-hour history horizon, <=3600-second transport pages, <=4322 sparse history events, <=1 MiB accepted checkpoint, bounded live FIFO. No raw-night arrays or vendor CPU-sleep scheduling are retained. Recorder computation/I/O is off the main actor. |

The fixed logical-hour cursor is an intentional delivery adaptation: recorder
transport page boundaries/retries do not become new algorithm boundaries.
A sample exactly at an hour endpoint remains in that hour; the first later
sample begins the next logical query. Sparse/empty intermediate chunks preserve
pending analyzer/bin state. Records delivered out of order behind an already
accepted timestamp are rejected; physical-device checks must confirm recorder
ordering/lag rather than assume an arbitrary out-of-order backfill can be merged.

## Persistence and compatibility

- Pending wake schema is retained, including old missing-`armedAt` fallback and
  explicit `isSessionScheduled == false` foreground placeholders. Recovery
  attaches the runtime delegate synchronously before returning.
- `SmartWakeMovementHistory-v2.json` stores occurrence key, session start,
  accepted timestamp, logical query boundaries, detector state and sparse events.
  Atomic writes checkpoint the full state together, including cancellation.
  Unknown schema, mismatched occurrence/start, malformed/nonfinite data,
  impossible sizes/counters, or oversized files replay from `armedAt` instead.
  Old magnitude bins are never converted into raw acceleration.
- `smartWakeCompletedOccurrences-v1` retains at most 32 schedule/wake pairs for
  two days. Completion is written before user alert/trigger delivery, closing
  the relaunch-before-cleanup duplicate window. This does not claim atomicity
  between storage and external haptic/light effects across a process crash.
- Phone/watch duplicated message models remain identical and decode old payloads.
  Legacy power/profile fields are inert defaults, including persisted watch
  migration; the old phone `profile.json` is untouched and unread. New summaries
  add optional algorithm identity and movement phase/rate/filter/event diagnostics.
  Old archives lack these optional fields and are identified as legacy.
- Legacy `confidence` is now a rule result (0/1), not a calibrated probability;
  motion score is detector intensity. The movement trace records meaningful
  current diagnostics; old composite components are retained as zero only for
  summary-wire compatibility.
- Only an acknowledgement matching both trigger ID and schedule ID can transfer
  light ownership. A positive ack cancels the deferred fallback; a negative ack
  starts it immediately; a missing ack preserves the eight-second fallback.

## Validation

New-port evidence is in [`../../tests/SmartWakeParity/README.md`](../../tests/SmartWakeParity/README.md),
with source hashes and repeatable commands. These results are separate from the
**6,654 original-instruction research comparisons**.

- **13,870 Swift/Python comparisons across 764 deterministic cases** passed.
- **58** production policy/actor/pending-recovery/ledger assertions passed.
- **54** recorder delivery/checkpoint/restart assertions passed.
- **12** message migration assertions passed, six for each model copy.
- **19** actual phone coordinator/SwiftData handoff assertions passed with
  HomeKit, logging and WCSession transport test doubles.

Reference coverage includes threshold equality, 100/301 boundaries, delayed
intensity overwrite, quiet gaps, timestamp cadence, logical recorder chunks,
empty/sparse history, lifecycle events, two-hour guard, all window-table edges,
filtering, phases, deadline/expiration ordering and duplicate firing. Recorder
replay compares complete state after seven interrupted checkpoints and a late
50 Hz tail across an hour boundary.

Build/launch results are recorded in `tests/SmartWakeParity/build-proof.json`.
Installed toolchain: Xcode 27.0 (27A266a), Swift 6.4 compiler in Swift 5 language
mode, SDKs 27.0; deployment targets remain iOS/watchOS 26.2. Simulator builds
compile the actual apps/widgets. Release watchOS device compilation validates
production conditional paths (arm64 and arm64_32) but is not a physical installation or overnight test. All four builds passed. Fresh paired iOS/watchOS 27.0 simulators installed and launched the integration builds, reaching their HomeKit permission prompts with live processes. Those disposable simulators were then shut down and deleted; existing research simulators were preserved.

## First-night export readiness

Follow [TONIGHT-TEST.md](TONIGHT-TEST.md) for setup and morning export. Watch
phase transitions now log rate, thresholds, sensitivity and event count without
requiring Verbose Diagnostics. Verbose monitoring lines add those values at
approximately 1 Hz. Recorder refresh lines include the actual latest sample
time; `OCCURRENCE_JSON` embeds the full saved summary in ordinary shareable logs.
The internal summary no longer requires developer-container extraction. Raw XYZ
and battery measurements remain outside the export.

The readiness audit also corrected a retained 180-second recorder cutoff to the
documented 30 seconds and removed unused legacy calibration/lookback fields.
Delayed data remains protected by the actual-sample cursor and retry policy.
After this follow-up, iOS/watch simulator and Release watchOS builds passed again,
as did 58 integration, 54 recorder and 12 model-migration checks. The prior paired
simulator smoke launch predates these logging edits; no physical installation
has been performed.

## Remaining physical-device checks

1. Record several overnight runs: requested 40 Hz live cadence, actual recorder
   cadence/lag/order, authorization denial/revocation, sensor gaps, processing
   duration, and battery use. Confirm >12h initial arming renews before sleep.
2. Terminate/relaunch during sleep and monitoring: persisted ownership/`armedAt`,
   synchronous recovered-session attachment, startup at/after deadline, runtime
   expiration, foreground-only rearm, and completion deduplication.
3. Exercise selected haptics and actual lights: phone accepts/declines/is absent,
   delayed acknowledgement, eight-second watch fallback, exact-time HomeKit
   scene, one-day override, and widget status.
4. Review wake experience over multiple nights. Replay parity establishes code
   behavior; it does not establish clinical sleep-stage accuracy or battery life.
