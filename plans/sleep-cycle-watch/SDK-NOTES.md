# Separate phone SDK research

Historical companion investigation, November 7, 2026. These formulas describe SleepCycleSDK 1.5.2, not the watch algorithm. The actual watch is now decrypted and described in [README.md](README.md), [MOTION.md](MOTION.md), and [ALARM.md](ALARM.md). Original SDK build identity and the earlier device/simulator experiments remain in evidence.json and simulator-proof.json.

## Recovered SDK motion processing

These findings concern **SleepCycleSDK 1.5.2's motion pipeline**, not the separate watch implementation. Addresses below are unslid virtual addresses in its iOS arm64 binary.

The pipeline constructs `AccelerationFilter` at `0x8D168`. Its input routine at `0x4000` interpolates timestamped three-axis samples onto a 25 ms grid (40 Hz); nonpositive time deltas are skipped and gaps over one second enter a reset path. This is its internal processing rate, not proof of the watch's sensor request rate.

Each axis passes through two cascaded biquad sections (`0x73AC`). For each section the recurrence is:

```text
y  = b0*x + s1
s1 = b1*x - a1*y + s2
s2 = b2*x - a2*y
```

| Section | b0 | b1 | b2 | a1 | a2 |
| --- | --- | --- | --- | --- | --- |
| 1 | 0.3654502711939662 | 0.7309005423879325 | 0.3654502711939662 | 0.342548469256106 | 0.20680325470874872 |
| 2 | 1 | -2 | 1 | -1.889056624844439 | 0.8952299639500302 |

The coefficients reside at `0x160438` and `0x160460`. The second section's numerator rejects a constant component, so this is consistent with suppressing gravity/static offsets before event detection. This interpretation follows from the recovered filter, not a recovered source comment.

The sample-processing routine at `0x4A68` maintains a six-sample envelope:

```text
energy = sqrt(mean(filteredX² + filteredY² + filteredZ²))
```

Noise samples enter a 1,200-element ring at 10 Hz, covering 120 seconds. The noise estimate updates every 20 processing samples (0.5 seconds). `0x7598` sorts the available samples, takes the element at `count / 2`, then does the same with absolute deviations. For even counts this is the upper middle element, not the average of the middle pair. It stores:

```text
noiseMedian = upperMedian(noiseSamples)
noiseMAD = 1.4826 * upperMedian(abs(noiseSamples - noiseMedian))
```

After a ten-second warmup, the detector opens a movement when energy exceeds `noiseMedian + 6 * noiseMAD`; an existing movement uses `noiseMedian + 1.5 * noiseMAD`. This hysteresis lets a movement continue under a lower threshold than the one needed to start it. Constants and branches are visible in `0x4A68`; the constructor independently supplies the same multipliers.

Other constructor/event-path constants are a 0.6-second minimum event duration, a one-second permitted within-event gap, a 30-second maximum event duration, and a zero-second minimum inter-event interval. The event finalization checks are at `0x77CC`. At `0x8D318`, the instruction explicitly loads **both** vector lanes with `1.0`; the raw decompiler's rendering of this vector assignment is misleading, which is why the instruction check matters.

## Recovered SDK alarm decision

`SmartAlarmState` has sleeping, armed, and fired phases. `0xFB5B4` advances the time-dependent state and handles window-end firing; `0xFC180` records a fired event once. Movement consumption at `0xF8E54` maintains separate audio and accelerometer histories. It filters for movement events, carries each event's probability into an internal interval representation, and merges nearby events before evaluating the accumulated interval. This is event-based logic; the inspected trigger path does not consume the sleep-stage model output.

The following reconstruction comes from `0xFEA74` (calibration), `0xFCAFC` (configuration setup), and `0xFC6E8` (event decision). These larger routines were statically traced; only the small arithmetic helpers described below were independently executed in an emulator.

1. Build a historical distribution of movement scores, where score is interval duration multiplied by its probability/weight. Nearby historical intervals are merged with a two-second tolerance (`0x10F034`).
2. Compute per-source thresholds from that distribution. The normal configuration uses the 90th percentile for the upper threshold and the 50th percentile for the lower threshold. The lower-threshold formula also has a MAD multiplier; the observed normal configuration supplies zero for that multiplier.
3. Hold the upper threshold through the first 30% of the configured wake window, then interpolate toward the lower threshold over the remaining 70%.
4. Fire when the current accumulated movement score strictly exceeds that threshold, with a positive-score guard when the threshold is nonpositive.
5. An additional path fires on a qualifying large movement following a previous large movement when the gap from the previous end to the current start is strictly greater than ten seconds and strictly less than 120 seconds. Its large-movement cutoff also decreases through the window, using the 90th/70th percentile range.
6. The time path forces the window-end event if an earlier path has not fired. The public event enum also includes a `userInteraction` reason; the device-interaction classifier was not exhaustively reconstructed here.

The historical calibration routine excludes an initial portion of the session. Static tracing gives these duration-dependent offsets: no calibration interval for sessions of at most five minutes; skip the first five minutes up to two hours; above two hours and below five hours, skip `30 minutes + (duration - 2 hours)/2`; at five hours or more, skip the first two hours. These values describe the SDK routine, not the watch's overnight recorder strategy. Missing-history and zero-length-window paths have separate fallbacks; the normal-case description is not a complete replacement implementation.

The verified interpolation formula is:

```text
p = (movementStart - wakeWindowStart) / wakeWindowDuration
t = clamp((p - 0.3) / 0.7, 0, 1)
ease(t) = 2*t²                      if t < 0.5
          -1 + 4*t - 2*t²           otherwise
threshold = upper + (lower - upper) * ease(t)
```

The arithmetic helper at `0xF3CB4` implements this quadratic ease-in/ease-out interpolation, with input clamping. The percentile helper at `0xFE95C` selects sorted element `clamp(floor(q * count), 0, count - 1)`; it does not interpolate neighboring order statistics. The separate large-movement cutoff helper at `0xFE818` returns ten when its range is absent.

**Verification:** `SDKProbe.py` executes the original instructions for those three helpers using Unicorn's ARM64 emulator. It checks 103 interpolation inputs, seven large-movement progression inputs, the missing-range fallback, and five percentile inputs: 116 checks passed. Thresholds 20 and 5 in the probe are synthetic inputs, not universal Sleep Cycle thresholds. This verifies the arithmetic and selected branch behavior, not a complete SDK session, the watch algorithm, clinical accuracy, or equivalent wake quality.

To repeat with a Python environment containing `unicorn`:

```sh
python plans/sleep-cycle-watch/SDKProbe.py \
  .research-cache/sleep-cycle-sdk-1.5.2/SleepCycleSDK
```

For Lights Timer, this provides concrete reference techniques: consistently filtered axes, short-window motion energy, a rolling robust noise estimate, event hysteresis, per-night event thresholds, and a deadline-dependent threshold. Porting the phone constants directly to wrist motion would require validation. The current recorder/live baseline mismatch described below remains the first implementation issue to fix.

