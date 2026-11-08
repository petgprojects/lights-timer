# Actual Sleep Cycle watch alarm decision and calibration

Analyzed build: Sleep Cycle 6.26.430 / 28530. Input is the decrypted, independently page-hash-verified `SCWatchExtension`, ARM64 slice. This is a behavioral reconstruction of the vendor machine code, not vendor source. The complete motion detector is documented in [MOTION.md](MOTION.md); runtime scheduling is documented in [RUNTIME.md](RUNTIME.md).

The readable implementation is [WatchAlgorithmReference.py](WatchAlgorithmReference.py). The probes and [watch-proof.json](watch-proof.json) compare the reconstruction with outputs produced by executing the original ARM64 instructions. **164 comparisons pass:** 23 parameter-table cases, 36 alarm decisions, 72 movement-filter cases, 24 historical-rate cases and 9 recursive calibration searches. These are component tests with synthetic data and Foundation/Swift runtime shims, not an overnight device validation. The scope is ordinary finite sensor/timestamp inputs; malformed floating-point inputs are not a supported interface contract.

## Entry points and exact state

| ARM64 address | Recovered responsibility |
|---|---|
| `0x100098690` | `WakeUpByMovementCountAlarmRulesWatch` initialization |
| `0x10009c2cc` | Begin tracking: assign alarm/delegate, set phase times, observe movement |
| `0x10009b4ec` | Calculate phase times from alarm time and window |
| `0x1000989f0` | Change phase; on arming, select mode and historical movement filter |
| `0x10009af74` | Movement notification dispatcher and phase transitions |
| `0x10009a704` | Apply the armed-phase movement filter and recalculate new movement |
| `0x100099334` | Decide whether to wake |
| `0x1000991e0` | Set fired flag and invoke runtime alarm delegate |
| `0x10009be18` | Stop observing, reset phase/timestamps, clear weak alarm/delegate |
| `0x10009c03c` | Choose the two rate parameters from wake-window length |
| `0x10008bbf4` | Historical movements-per-hour calculation |
| `0x10008c6e8` | Calibrated filter selection with duration/rate guards |
| `0x10008ca8c` | Recursive binary search for filter thresholds |
| `0x10008da78` | Effective session end |
| `0x10008dd68` | Session duration, clamped to zero |

Metadata names: `WakeUpByMovementCountAlarmRulesWatch`, `SleepSessionOperations`, `MovementFilterWatch`, `RulePhase`. Phase raw values are noAlarm=0, sleepy=1, armed=2, preArmed=3. The rule object contains weak alarm and delegate references, window seconds, both phase dates, sensitive mode, last qualifying movement start, a last qualifying sample timestamp used by the armed filter, fired flag, historical session operations, and filter thresholds.

Initialization sets phase=0, optional dates=nil, sensitive=false, filter=(0,0), last qualifying sample tick=-1, and fired=false. Begin tracking assigns the weak alarm/delegate, resets `lastMovementStarted=nil`, and sets phase=sleepy. It observes `MFD_MOVEMENT_OCCURRED_WATCH`.

Both `changeToPreArmedPhaseTime` and `changeToArmedPhaseTime` are set to **alarm time minus selected wake-window seconds**. The `alreadyArmed` flag is set when the supplied setup date is later than this time; it does not enter the recovered alarm decisions.

On each movement notification:

1. Ignore phase=noAlarm.
2. If sleepy and movement.date > preArmedTime, change to preArmed.
3. If still sleepy, return.
4. If preArmed and movement.date > armedTime, change to armed.
5. If still preArmed, return.
6. If armed and not fired, run the armed movement filter, then the decision function.

All date comparisons above are **strict >**. Because the two phase dates are the same, one notification can perform both transitions and then be evaluated. At the exact window-start timestamp it remains sleepy. The dispatcher is driven by movement notifications, including detector output that reports no active movement. Runtime scheduling and independent deadline backstops are handled separately.

## Historical calibration

A historical event has date, event type, and intensity. Type 1 is `movementDetected`; type 2 is `delayedMovementDetected`. The recorder pipeline emits at most one of each type per 60-second collection bin, with the last qualifying intensity of that kind, not a count of every individual raw movement. Consequently these rates are event-bin rates. See [MOTION.md](MOTION.md) for exact recorder behavior.

Let S be session start. The effective end E is:

- Explicit sessionEnd, if present.
- Otherwise the latest date among **all** session events, regardless of type.
- Otherwise S for an empty event array.

The rate calculation uses:

```
C = max(S, min(S + 7200, E - 10800))
hours = ((E - C) / 60) / 60
count = number of events whose date >= C and either:
    type == 1 and intensity >= filter.dLimit
    type == 2 and intensity >= filter.raLimit
rate = 9.5 if hours == 0 else count / hours
```

The count has no explicit `event.date <= E` check. All rate/count cutoffs are inclusive. This excludes the first two hours on sessions lasting at least five hours; on shorter sessions it retains at least the final three hours where available. E is event-derived, not wall-clock now, while a session is in progress. Empty/zero-duration history falls back to **9.5**, not zero.

When entering armed phase, the rule resets fired=false, calculates rate with filter=(0,0), and chooses these parameters:

| Window minutes, inclusive upper bound | Sensitive-mode boundary | Filter target maximum |
|---|---:|---:|
| <=10 | 8.5 | 11.0 |
| <=15 | 8.0 | 10.5 |
| <=20 | 7.5 | 10.0 |
| <=30 | 7.0 | 9.5 |
| <=45 | 6.0 | 8.5 |
| <=60 | 5.5 | 7.0 |
| <=90 | 5.0 | 6.5 |
| >90 | 7.0 | 9.5 |

This binary exposes all these branches even though the app's selected window enum currently maps to 0/10/15/20/30 minutes. The 25-minute case uses the <=30 row.

`verySensitiveWakeUpMode = historicalRate < sensitiveBoundary` (strict). If historicalRate > maximum target (strict), calculate the calibrated filter; otherwise use filter=(0,0). Always reset armed-filter lastTick=-1. The `lastMovementStarted` decision history is initialized at begin tracking, not reset in this phase-change function.

Filter calculation independently requires full session duration >= 2 hours and unfiltered rate >= target. If either fails, return (0,0). Otherwise search a scalar x in [0,2] with:

```
raLimit = min(x, 1)
dLimit = max(x - 1, 0)
low=0; high=2
repeat 41 times:
    x = low + (high-low)*0.5
    if target <= historicalRate(filter(x)): low=x
    else: high=x
return filter(low + (high-low)*0.5)
```

The original function is recursive with depth 0..40 evaluating rate, depth 41 returning its midpoint. It first increases the delayed-motion threshold while leaving the instantaneous threshold zero, then raises the instantaneous threshold once the scalar passes 1. It does not use the iPhone SDK's threshold calibration formula.

## Armed-phase filter

The input is a `DecoratedMovement`: date, original accelerometer movement, duration, newMovement, movementInProgress, delayedMovement, and intensity. The output preserves date, raw movement, delayed flag and intensity; its duration is explicitly zero.

- If input is inactive, preserve its flags and do not update lastTick.
- If both filter thresholds are exactly 1, bypass filtering, preserve flags and do not update lastTick. This explicit special case was verified; the binary search normally approaches 2 without returning exactly 2.
- Otherwise, choose threshold=raLimit for delayed movements and dLimit for instantaneous movements.
- If intensity < threshold, clear newMovement and movementInProgress. Do not update lastTick.
- If intensity >= threshold, retain movementInProgress, replace newMovement with `(date - previousLastTick > 10) || previousLastTick == -1`, and set lastTick=date.

Thus the live armed filter recomputes movement episode starts after the historical thresholds are applied. Equality at 10 seconds does not start a new movement; equality at an intensity threshold passes.

## Exact wake decision

The decision first requires a current alarm with a valid alarm time. It then evaluates in this order:

1. If the runtime delegate's `0x100036e74` predicate is true, fire. The runtime tracing identifies this predicate as extended-runtime expirationDate.timeIntervalSinceNow < 300 seconds.
2. Else if movement.date > alarmTime, fire (strict >, not >=).
3. Else if sensitive mode: fire whenever filtered movementInProgress is true. Otherwise return.
4. Else apply the normal-mode branches below.

Let elapsed = movement.date - lastMovementStarted, or `Double.greatestFiniteMagnitude` if the latter is nil.

**New movement:**

```
progress = 1 - (alarmTime - movement.date) / wakeUpWindowSeconds
if progress * intensity > 0.02:
    if elapsed < 120: fire
    lastMovementStarted = movement.date
return
```

Both comparisons are strict. Progress is not explicitly clamped. A qualifying first new movement records a start; another qualifying new movement within 120 seconds fires. Exactly 120 seconds does not fire, but updates the start. There is no nonnegative elapsed check. A new movement whose scaled intensity is <=0.02 neither fires nor updates lastMovementStarted.

**Non-new delayed movement:** if intensity >0.1 and lastMovementStarted is nil, set lastMovementStarted=movement.date and return without firing. If lastMovementStarted already exists, do not replace it. This branch does not explicitly require the filtered active flag. This matters when a high calibrated delayed threshold suppresses active while the raw retained intensity is still above0.1.

**Non-new instantaneous movement:** fire if movementInProgress is true, delayedMovement is false, elapsed >10 seconds, and elapsed < Double.greatestFiniteMagnitude. The elapsed test is time since the saved decision start, not a new sample counter; there is no upper time bound. The armed filter's episode recomputation controls whether the sample reaches the new/non-new branch.

There is no HR, HRV, temperature, sleep-stage label, or trained model evaluation in these alarm rules. Inputs are historical movement-event counts, current decorated accelerometer movement, time within the wake window, and runtime expiration.

## Fire and cleanup

`fireAlarm` sets fired=true before obtaining the current alarm. With an alarm and live delegate it calls RuntimeSessionManager's `0x100038654`. The notification dispatcher subsequently skips all checks while fired=true. The runtime tracing establishes that the delegate initiates sound/haptics only if its runtime session is in running state, records event type5, then stops monitoring; scheduling, runtime availability, snoozing and backup expiration callbacks are outside this document's component scope.

Stopping removes the notification observer, changes phase to noAlarm, clears the two optional phase dates, and clears the weak alarm/delegate references. The next begin-tracking call resets decision history.

## Evidence and reproducibility

[PROBES.md](PROBES.md) documents execution and coverage. The public research scripts accept a separately supplied binary; they contain no vendor executable bytes. [decryption-proof.json](decryption-proof.json) verifies plaintext provenance against the original IPA. Raw disassembly, Ghidra output, Swift metadata, and individual instruction-test logs remain locally ignored in `.research-cache/sleep-cycle-deep/watch-alarm/` and `crossmatch/`.

Instruction execution tests use the ARM64 slice with platform services shimmed. ARM64_32 parity is separately audited; neither is an overnight hardware or clinical accuracy trial.

## ARM64_32 cross-check and runtime callback fields

The decrypted ARM64_32 slice has matching constants, decision branches and state changes in **16 reviewed functions**. Method correspondence is anchored in Swift nominal descriptors and the same vtable indexes, then checked against actual disassembly. Pointer widths, object layouts and native array counters differ; no algorithm difference was found for ordinary supported data. This is a static parity audit, not an ARM64_32 runtime execution test or whole-app equivalence claim. The explicit coverage and SHA256 are in [watch-arm64_32-parity.json](watch-arm64_32-parity.json); annotated instructions are in `alarm-arm64_32.asm`, `parameter-arm64_32.asm`, and `extras-arm64_32.asm`.

| Responsibility | ARM64_32 address |
|---|---|
| initialization | `0x99bdc` |
| begin tracking | `0x9d5f4` |
| change phase/calibrate | `0x99f3c` |
| fire delegate | `0x9a6a0` |
| wake decision and guards | `0x9a7ec` |
| armed filter | `0x9baec` |
| movement notification phases | `0x9c37c` |
| phase timestamps | `0x9c880` |
| stop tracking | `0x9d038` |
| window parameter table | `0x9d2a8` |
| historical rate | `0x8cf58` |
| calibration guards/filter | `0x8da94` |
| binary search | `0x8de60` |
| effective end | `0x8ed14` |
| clamped duration | `0x8f004` |
| runtime expiration predicate | `0x39bcc` |

The checks include all seven window boundaries and the >90-minute fallback; 7200/10800-second history selection; the 9.5 empty-duration fallback; >=2-hour calibration eligibility; 41 binary-search evaluations; threshold equality handling; -1/10-second armed-filter episode handling; strict 0.02, 0.1, 10-second and 120-second wake branches; nil decision-history seeding; runtime predicate before deadline before sensitivity; both phase timestamps; fired suppression; and the <300-second runtime predicate. Effective end still uses explicit end, latest event, or session start.

The `RuntimeSessionManager.willExpire` callback's two Published Boolean keypaths resolve to **Alarm.isFired** and **Alarm.isPlaying**. Its guards require both false (plus the runtime running-state guard documented in RUNTIME.md). They are not an `isStopped` or snoozing check. The storage keypaths `0x1001cc768` and `0x1001cc7b0` resolve through indirect references to field-offset globals `0x10023b120` and `0x10023b128`. Those are identical to the private Alarm property accessors at `0x100004400` and `0x100004414`, vtable indexes13/19, whose positions correspond to `_isFired`/`_isPlaying` in the Swift field metadata. Full address evidence: `expiration-guard-keypaths.json`.
