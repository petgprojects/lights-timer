# Watch acquisition, scheduling, and alert execution

Reconstructed from the actual Sleep Cycle 6.26.430 / 28530 watch executable. Addresses are unslid ARM64 virtual addresses. [MOTION.md](MOTION.md) describes sensor processing and recorder aggregation; [ALARM.md](ALARM.md) describes the decision state machine.

## Scheduling

`SetAlarmCoordinator.continueStart(skipAnimationDelay:)`, `0x100048c18`, requires motion authorization status 3, obtains the selected alarm date, and maps the window enum to `[0, 600, 900, 1200, 1800]` seconds. The selected window is passed to the alarm-rule constructor. The scheduled runtime date is computed separately:

```python
lead = 1800 if window_enum == 4 else 1500
runtime_date = alarm_date - lead
if runtime_date.timeIntervalSinceNow < 5:
    runtime_date = Date.now + 5
if alarm_date - runtime_date < 0:
    runtime_date = alarm_date
```

The two reads of current time are separate in the binary. This is approximately `min(alarmDate, max(alarmDate-lead, now+5))`, with the precise evaluation order above. The lead selection is at `0x100049104..0x100049148`; the two clamps are at `0x10004914c..0x1000491d0`.

`RuntimeSessionManager.scheduleBackgroundSession(date:)`, `0x1000348f0`, requires no existing owned runtime, the application state to be active, and a requested date at least `now-60 seconds`. It creates a `WKExtendedRuntimeSession`, assigns its delegate, calls `start(at:)`, and persists `ExtendedRuntimeSessionScheduledDate`. Successful scheduling proceeds into `beginSleepTracking(alarmDate:)`, `0x100034e48`.

The constructor sites at `0x1000399c0` and `0x10007c82c` create `WakeUpByMovementCountAlarmRulesWatch` (`0x100098690`) using the selected window. They start live movement monitoring through `0x10007a1ec`, which requests **40 Hz** and starts a fresh movement detector.

Apple documents a 30-minute smart-alarm runtime, scheduling while active, and relaunch through the extension delegate. Those are platform rules; the dates and guards above come from Sleep Cycle's instructions. [Apple extended runtime sessions](https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions)

## Overnight recording and history processing

`beginSleepTracking` creates the alarm and sleep-session state and calls `recordMotion(forDuration:)`, `0x10003ed24`, with the time remaining until the alarm. That function checks recording availability and authorization, caps the duration at **43,200 seconds**, and dispatches the recording request to a utility queue. The closure `0x10003f294` calls `CMSensorRecorder.recordAccelerometer(forDuration:)`. A separate `0x10003f188` path requests 0.1 seconds; it is not the overnight recording duration.

Apple specifies 50 Hz for the recorder and permits recording while the application is suspended or terminated. Sleep Cycle feeds returned raw samples into its analyzer at their delivered cadence; it does not resample modern-watch recorder data to the live 40 Hz rate. [Apple recorder documentation](https://developer.apple.com/documentation/coremotion/cmsensorrecorder/recordaccelerometer%28forduration%3A%29)

On runtime start, the normal path calls `beginWakeupPhase`, `0x100037d5c`. It marks the wake phase, records a session event, processes pending overnight history, and then starts live monitoring and the alarm rules. History processing runs asynchronously on a utility queue. In `0x100038c0c`, its input starts at the persisted processed-through date, falling back to session start, and ends at `Date.now - 30 seconds`. A `NightProcessor` is created with a **60-second collection interval**. Requests are queued if processing is already active. Motion authorization failure follows an empty-result completion path instead of producing invented sensor history.

`SleepSessionCoordinator.scheduleNextBackgroundRefresh`, `0x10007b630`, proposes a background refresh at `now + 7200 seconds` for a hardware-model numeric prefix above 3, or `now + 3600 seconds` for older hardware. It requests that refresh only when the proposed date is before `alarmDate - 1800 seconds`. This is an OS request, not a promise that the application runs at that interval. [MOTION.md](MOTION.md) specifies the separate per-query chunking and event-bin rules.

## Deadline and runtime-expiration paths

The alarm decision is invoked on movement notifications, including samples with `movementInProgress=false`. After the phase has entered armed, it checks runtime expiration before the movement timestamp deadline:

```python
if runtime.expirationDate is not None:
    if runtime.expirationDate.timeIntervalSinceNow < 300:
        fire()
        return
if movement.date > alarmDate:
    fire()
    return
# Otherwise evaluate the movement rules.
```

`RuntimeSessionManager`'s expiration predicate is `0x100036e74..0x100037038`; it returns false for a missing session or expiration date. The deadline comparison is strict `>`, and the expiration comparison is strict `<`. Their order is verified in `0x100099334`. The notification phase gate still applies: the predicate is not an independent timer that executes while the app is suspended.

**Consequence derived from these formulas:** if the OS grants a full 30-minute session, a runtime scheduled 25 minutes before the alarm reaches its five-minute reserve at the alarm time. A runtime scheduled 30 minutes before the alarm reaches that reserve five minutes earlier. Actual behavior follows the OS-provided expiration date and event delivery, so this consequence is not a measured overnight timing result.

There is also an independent `extendedRuntimeSessionWillExpire` callback at `0x10003a024`: if the runtime is running and the current alarm has `isFired == false` and `isPlaying == false`, it invokes `soundAlarm` directly. Thus missing live movement callbacks still have an expiration callback path. The normal start callback at `0x10003742c` also handles a snoozing or absent-alarm-time state separately from the ordinary history-processing path. The invalidation callback clears the runtime reference and persists/stops session state; it cannot create runtime after the OS has invalidated it.

## Firing and repeating haptics

The rule's `fireAlarm` (`0x1000991e0`) sets its fired latch and calls the runtime delegate (`0x100038654`). That delegate requires a running runtime (state 2), records sleep event type 5, stops movement monitoring through `0x100074998`, and calls `soundAlarm`, `0x100037fb8`.

`soundAlarm` persists current alarm state and calls `notifyUserWithHaptic:repeatHandler:` with initial haptic type 0 (`notification`). The repeat callback `0x100038878` obtains its next pair from `0x100008c50`, with the following 14-entry constant sequence at `0x10023d3f0`:

| Haptic type | Delay returned, seconds | Repetitions in sequence |
| --- | ---: | ---: |
| directionUp (1) | 1.5 | 3 |
| start (6), success (3), start, success, start, success, start | 1.0 each | 7 entries |
| notification (0) | 2.0 | 3 |
| notification (0) | 1.5 | 1 |

The sequence wraps. The callback adds each selected delay to a cumulative counter before returning. When that accumulated value becomes **strictly greater than 60 seconds**, it substitutes `retry` (5) and a **0.5-second** delay. Thus it escalates after roughly a minute; it does not simply stop after one minute. Raw type names were cross-checked against the installed WatchKit header. Actual vibration timing remains managed by WatchKit.

## Evidence scope

The scheduling, record duration, history cursor, and alert sequence above were read directly from disassembled/decompiled instructions and constant tables. Original-instruction probes separately validate the mathematical movement/alarm/calibration components, as detailed in [PROBES.md](PROBES.md). This document does not claim a completed overnight run of Sleep Cycle, a simulated sensor environment, or identical battery behavior in Lights Timer.
