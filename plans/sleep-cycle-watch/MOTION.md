# Exact watch motion and recorder pipeline

Recovered from the actual Sleep Cycle 6.26.430 (28530) `SCWatchExtension`, including its `GMFoundationWatch` implementation. The decrypted protected pages match both original pre-encryption hash tables; see [decryption-proof.json](decryption-proof.json). Addresses below are unslid ARM64 virtual addresses unless explicitly labeled ARM64_32. This describes recovered behavior; it is not a claim that the algorithm identifies clinical sleep stages.

## Input and default threshold

The live input is raw `CMAccelerometerData.acceleration` in three axes. `AccelerometerService.start(updateFrequency:)` sets both accelerometer and gyroscope update intervals to `1 / updateFrequency` (`0x100143224–0x10014332c`). The two actual start call sites at `0x1000239e0` and `0x10007a2f8` pass **40 Hz**. That is the requested rate; actual delivery can vary.

The accelerometer callback at `0x100143478` ignores a missing sample. A nonnil error logs and stops the service. Valid samples are dispatched to the main queue and processed at `0x1001437fc`. XYZ are used directly: no gravity subtraction, magnitude conversion, or low/high-pass preprocessing. Sample time is `Device.bootTime + motion.timestamp`; boot time is computed from `Date.now - ProcessInfo.systemUptime` (`0x10016f2c8–0x10016f304`). A timestamp more than five seconds from now is logged **after** the movement notification is posted; that check does not reject the sample.

Gyroscope updates have a separate notification path. The recovered detector observes accelerometer `movementUpdate`, receives an `AcceleratorMovement`, and passes its raw acceleration to the analyzer. Gyroscope values are not inputs to this analyzer or its recovered alarm motion path.

`MovementFindingDetectorWatch` registers the observer in its initializer (`0x10002920c`), creates a fresh analyzer on `start()` (`0x1000293c0`), and clears the analyzer on `stop(at:)` (`0x100029424`). Its handler (`0x100029450`) checks that the detector is active, casts the notification object to `Movement2`, calls `update`, and posts `MFD_MOVEMENT_OCCURRED_WATCH` with the resulting `DecoratedMovement`.

Despite its name, **`getCalibratedDLimit()` at `0x10002bd20` returns a constant**: Double bits `0x3fb70a3d70a3d70b`, decimal `0.09000000000000001` (the rounded product `0.05 × 1.8`). Its two logger closures (`0x100029a68`, `0x100029ba0`, via `0x10002bfa8`/`0x10002bfb8`) only format/read the values. There is no persisted-calibration lookup or threshold mutation in this getter. Both the live detector and `NightProcessor` construct their analyzers from it. The historical wake-threshold calibration is a separate downstream decision path; it does not change this initialization value in the recovered callers.

## FastMovementAnalyzer

Constructor: `0x100178368`. Update: `0x1001784c8`. Private block-average helper: `0x100178888`.

| State | Initial value | ARM64 object offset |
|---|---|---|
| Quiet period needed to rearm `newMovement` | 10 seconds | `+0x10` |
| `dLimit` | Constructor argument D, normally approximately 0.09 | `+0x18` |
| Last qualifying sample time | nil | `+0x20` |
| Previous acceleration | nil | `+0x30` |
| Saved anchor acceleration | nil | `+0x60` |
| Input counter | 0 | `+0x88` |
| X, Y, Z buffers | Three arrays of 301 Doubles | `+0x90/+0x98/+0xa0` |
| Buffer index | 0 | `+0xa8` |
| Previous block mean | nil | `+0xb0` |
| Mean-difference limit R | Formula below | `+0xd8` |

The constructor calculates:

```text
R = exp((D - 0.327) / 0.043) * (2.1 if D < 0.04 else 1)
```

At the watch's default D, R is approximately **0.0040395260551327715**. The external call is `exp`, confirmed from the import/indirect-symbol tables. R is cached at initialization. A compiler-generated setter at `0x100178c4c` can write D alone without recalculating R; the recovered live/history paths do not invoke it to apply calibration.

Finite-input pseudocode, preserving update order:

```text
update(t, acceleration a):
    new = false
    moving = false
    delayed = false
    intensity = 0

    if previousAcceleration exists:
        shortDelta = EuclideanNorm(previousAcceleration - a)
        intensity = shortDelta
        candidate = shortDelta
        if anchorAcceleration exists:
            candidate = max(candidate, EuclideanNorm(anchorAcceleration - a))
        if candidate > D:
            moving = true
            intensity = candidate
            new = (lastQualifyingTime is nil)

    X[index], Y[index], Z[index] = a.x, a.y, a.z
    index += 1
    if index >= 301:
        mean = (mean(X), mean(Y), mean(Z))
        if previousBlockMean exists:
            meanDelta = max(abs(mean.x - previousBlockMean.x),
                            abs(mean.y - previousBlockMean.y),
                            abs(mean.z - previousBlockMean.z))
            if meanDelta > R:
                moving = true
                delayed = true
                new = (lastQualifyingTime is nil)
                intensity = meanDelta
        previousBlockMean = mean
        index = 0

    if moving:
        lastQualifyingTime = t
    else if lastQualifyingTime exists and t - lastQualifyingTime > 10:
        lastQualifyingTime = nil

    previousAcceleration = a
    if counter % 100 == 0:
        anchorAcceleration = a
    counter += 1

    return DecoratedMovement(time=t, duration=0, acceleration=a,
                             newMovement=new, movementInProgress=moving,
                             delayedMovement=delayed, intensity=intensity)
```

The Euclidean comparisons are at `0x100178564–0x100178624`. The three mean calls are `vDSP_meanvD` at `0x100178a0c`, `0x100178a40`, and `0x100178a74`; the axis-difference test is at `0x100178a84–0x100178ae8`. The timeout comparison is at `0x100178744–0x10017875c`, and the anchor refresh is at `0x100178760–0x1001787c0`.

Important consequences of those instructions:

- The 301-sample means use **non-overlapping blocks**, despite the stored name `previousRollingAverage`. The first block only establishes a mean; the first possible mean-difference hit is sample 602.
- At requested live 40 Hz, completed block means occur every 7.525 seconds and the anchor updates every 2.5 seconds. The timestamps of 301 evenly spaced samples span 300 intervals, or 7.5 seconds. Both rules count samples; neither uses a timer.
- The anchor changes after detection on zero-based input counts 0, 100, 200, and so on.
- A delayed hit overwrites intensity with `meanDelta`, even if the instantaneous path already produced a larger value.
- If the instantaneous candidate does not exceed D, intensity remains `shortDelta`, even when the anchor delta was larger.
- The field named `lastTickWhenMovementStarted` is updated on **every qualifying sample**, not only movement onset.
- `movementInProgress` reports the current sample's threshold hit. It is false on quiet samples while the ten-second latch is still armed.
- Rearming requires a **nonqualifying** sample more than ten seconds after the last hit. A qualifying sample after a large timestamp gap can still have `newMovement=false` if no quiet sample cleared the latch first.
- No explicit monotonic-time check, gap reset, stale-input rejection, resampling, or finite-value sanitizer exists here. Movement-intensity and quiet-gap comparisons are strict `>`; the special low-D branch is strict `< 0.04`.
- Output duration is explicitly zero (`0x100178838–0x10017883c`). Consumers must supply any event duration themselves.

## Recorded overnight history

`NightProcessor.init(collectionInterval:)` is at `0x100029718`. All 15 recovered direct initializer call sites pass **60.0 seconds**. It constructs the same analyzer with the constant D above and initializes empty aggregation state.

The source function names survive in diagnostic strings:

- `retrieveEvents(from:to:inBackgroundTask:exitWhenCpuExhausted:handler:)`: outer worker at `0x100029c68`.
- `process(from:to:poorHardware:)`: per-query processor at `0x10002afe4`.

The inner processor calls `CMSensorRecorder.accelerometerData(from:to:)` at `0x10002b1d4`, enumerates the returned records, and directly reads each accepted `CMRecordedAccelerometerData.acceleration` (`0x10002b530–0x10002b548`) plus **`record.startDate`** (`0x10002b560`). These form an `AcceleratorMovement` passed to the same persistent analyzer (`0x10002b5f4`). The recorded path does not use the live boot-time conversion.

Apple documents sensor-recorder capture at **50 Hz**. The recovered modern-watch path does not resample that stream to the requested live 40 Hz. Consequently, at nominal recorder cadence completed 301-sample block means occur every **6.02 seconds** and the same 100-sample anchor interval spans **2 seconds**. The first-to-last timestamps within one block span 6 seconds. Actual missing/delayed records still affect those durations. [Apple: recordAccelerometer(forDuration:)](https://developer.apple.com/documentation/coremotion/cmsensorrecorder/recordaccelerometer(forduration:))

The older-hardware branch uses the integer before the comma in the device identifier after removing `Watch` (`0x1000a3c84`). This is a hardware-model prefix, not a marketing Series number. For a value below 4, the worker queries 600-second chunks, skips the following 600 seconds, and passes `poorHardware=true`. That flag processes only returned indices 0, 100, 200, and so on. For values at least 4, including `Watch6,14`, it processes **every record in contiguous 3,600-second query chunks**. Chunk-size selection is at `0x100029f64–0x100029f74`, query dispatch at `0x10002a0b8–0x10002a0e0`, and cursor advancement at `0x10002a11c–0x10002a170`. The analyzer is retained across chunks.

The outer worker's execution budget is 3.5 seconds when `inBackgroundTask=true`, otherwise 8 seconds. After a query, it compares elapsed time with budget minus that query's execution time. If `exitWhenCpuExhausted=true`, it stops and returns the last queried end date. Otherwise it sleeps `max(30, 60 - elapsed)` seconds and restarts the budget clock. That affects how much history is processed in one invocation, not the arithmetic of individual movements.

## Sixty-second event aggregation

Recorder analysis produces sparse `SleepEventWatch` values for calibration and later processing. The event type raw values are `unknown=0`, `movementDetected=1`, and `delayedMovementDetected=2`.

At entry to each query, the local boundary is `queryStart + collectionInterval`. The analyzer and aggregation fields remain on the `NightProcessor` instance:

| State | ARM64 offset |
|---|---|
| `collectionInterval` | `+0x18` |
| `movementDetected` | `+0x20` |
| `strongestDelayedMovement` | `+0x28` |
| `strongestMovement` | `+0x30` |
| `totalRecords` | `+0x38` |
| Analyzer | `+0x40` |

Despite the `strongest*` names, these values store the **last** qualifying intensity in each category, not the maximum. The assignment instructions at `0x10002b928` and `0x10002b940` are unconditional Double stores without a maximum comparison.

```text
process(queryStart, queryEnd, poorHardware):
    boundary = queryStart + 60
    output = []

    for (zeroBasedIndex, record) in recorderData(queryStart, queryEnd):
        if poorHardware and zeroBasedIndex % 100 != 0:
            continue
        if record is not CMRecordedAccelerometerData:
            continue

        m = analyzer.update(record.startDate, record.rawXYZ)

        if m.time > boundary:
            if movementDetected:
                if strongestDelayedMovement > 0:
                    append Event(time=boundary, type=2,
                                 intensity=strongestDelayedMovement)
                if strongestMovement > 0:
                    append Event(time=boundary, type=1,
                                 intensity=strongestMovement)
            movementDetected = false
            strongestDelayedMovement = 0
            strongestMovement = 0
            boundary += 60

        if m.movementInProgress:
            movementDetected = true
            if m.delayedMovement:
                strongestDelayedMovement = m.intensity
            else:
                strongestMovement = m.intensity

    return output
```

This pseudocode omits diagnostic counters and optional raw-dump I/O. It preserves the relevant ordering:

- The boundary test is strict `sampleTime > boundary` (`0x10002b610–0x10002b614`). A sample exactly on the boundary belongs to the bin being accumulated.
- A crossing sample first emits the previous aggregation state, then contributes its own hit to the new state.
- The boundary advances by 60 **once per accepted sample**, not in a loop (`0x10002b8dc`). Large time gaps can cause subsequent samples to advance several old boundaries gradually.
- Delayed events are appended before ordinary events when both exist at one boundary.
- A sample whose delayed flag is true contributes only to the delayed category, even if it also crossed D.
- There is **no final partial-bin flush** when enumeration ends. The return path at `0x10002bab0` only performs cleanup and optional dump flushing.
- The analyzer and pending bin values survive into the next query, while the boundary is initialized afresh from that query's start. Consequently, a chunk's trailing pending bin can be combined with early data from the next chunk before a subsequent emission. A reconstruction that flushes every query or resets the analyzer would change the observed algorithm.

## ARM64_32 confirmation

The user's Series 8 uses the ARM64_32 architecture. Its decrypted initializer is at `0x179634`, update at `0x179760`, and 301-sample helper at `0x179ae4`; its virtual-address base is `0x4000`.

Static instruction comparison confirms the same 301-element Double arrays; `0.04`, `2.1`, `-0.327`, and `0.043` constants (`0x1de638–0x1de650`); exponential threshold; short/anchor Euclidean comparisons; maximum absolute axis difference; delayed/intensity overwrite; strict ten-second rearm; and refresh after each 100 inputs. Pointers and Swift Int are 32-bit, while motion arithmetic and array elements remain Double. No mathematical difference was found for ordinary finite inputs within signed-Int range. Original-instruction execution and independent reference comparisons are recorded separately by the validation investigation.

The ARM64_32 history constructor at `0x2c8b0` likewise creates the same analyzer from its constant getter at `0x2ee48`. Its outer worker is `0x2ce0c`, and its per-query processor is `0x2e1e4`. The recorder path also matches: 600/3,600-second chunk selection (`0x2d070–0x2d084`), old-device skip (`0x2d244–0x2d298`), 1-in-100 decimation (`0x2e458–0x2e47c`), raw XYZ and record time (`0x2e6a4–0x2e710`), strict boundary test (`0x2e77c–0x2e780`), one boundary increment (`0x2ea20`), last-value assignments (`0x2ea68`, `0x2ea80`), and no end flush (`0x2ebb0` cleanup path). Both architectures materialize the exact same default-D bits.

## Evidence boundaries

This file specifies the live and recorded acceleration inputs, motion feature detector, and recorded event aggregation. The alarm-window rule, historical threshold calibration, scheduling, and wake execution are separate downstream paths. None of the motion facts above require assuming that the phone SDK is identical to the watch: they were read from the actual decrypted watch executable. Disassembly and decompiler working files remain in the ignored `.research-cache/sleep-cycle-deep/watch-motion/` directory.
