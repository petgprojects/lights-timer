# Motion-First Smart Wake Rebuild

## Summary
- Rebuild Smart Wake around the only runtime guarantee Apple gives us: a scheduled smart-alarm `WKExtendedRuntimeSession` with a 30-minute background window. The engine should treat motion as the primary live wake signal, heart rate as an irregular reinforcement signal, and exact wake as the hard fallback.
- Use every data source that is actually useful:
  - Live during the wake window: device motion, accelerometer history backfill, heart rate.
  - Post-hoc only for personalization: sleep stages, wrist temperature, respiratory rate, blood oxygen, HRV.
- Keep wake policy `Balanced`: avoid false-early wakes, but still fire early when the evidence is clearly good.

## Sensor Matrix
- **Live device motion**: use `CMMotionManager` during the scheduled session, with `deviceMotionUpdateInterval = 0.1` seconds (10 Hz). Use `userAcceleration`, `rotationRate`, `gravity`, and `attitude` as the primary live wake features. Source: [CMMotionManager.h](/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS26.2.sdk/System/Library/Frameworks/CoreMotion.framework/Headers/CMMotionManager.h).
- **Recorded overnight accelerometer**: start `CMSensorRecorder.recordAccelerometerForDuration(...)` when the user arms the watch before bed. This records at **50 Hz** for up to **12 hours** and remains available while the app is inactive; retrieval may lag by **up to 3 minutes**. Use this for overnight motion baseline and wake-window backfill, not for the final immediate seconds. Source: [CMSensorRecorder.h](/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS26.2.sdk/System/Library/Frameworks/CoreMotion.framework/Headers/CMSensorRecorder.h).
- **Heart rate**: keep `HKAnchoredObjectQuery` running during the session and treat samples as an irregular event stream. Without a workout, cadence is variable; Apple only guarantees that workout HR is continuous and background HR timing varies by activity. Never assume a fixed interval. Sources: [Monitor your heart rate with Apple Watch](https://support.apple.com/en-us/120277), [HKWorkoutSession.h](/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS26.2.sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKWorkoutSession.h), [HKDefines.h](/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS26.2.sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKDefines.h).
- **Not live-usable for triggering**:
  - Wrist temperature: sampled every 5 seconds during sleep, but exposed as a nightly aggregate and not on-demand.
  - Blood oxygen: on-demand or occasional background measurements; timing varies and requires stillness.
  - Respiratory rate: reviewed after sleep, not dependable as a live wake-window stream.
  - Sleep stages and HRV SDNN: useful for next-day labels/calibration, not real-time trigger input.
  Sources: [Track your nightly wrist temperature changes with Apple Watch](https://support.apple.com/en-tm/102674), [How to use the Blood Oxygen app on Apple Watch](https://support.apple.com/en-us/120358), [Track your sleep with Apple Watch](https://support.apple.com/en-lamr/guide/watch/-apd830528336/watchos), [HKTypeIdentifiers.h](/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS26.2.sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKTypeIdentifiers.h).

## Key Changes
- Rework [SmartWakeSessionController.swift](/Users/petergelgor/Documents/projects/Lights%20Timer/Lights%20Timer%20Watch%20App/Services/SmartWakeSessionController.swift):
  - When the user arms tonight’s wake, persist `armedAt`, start `CMSensorRecorder`, and keep the existing scheduled smart-alarm session.
  - When the smart-alarm session starts, start live `CMMotionManager` device-motion updates immediately and start the anchored HR query immediately.
  - Remove workout-startup as a dependency of the main algorithm. Do not attempt to start a new workout from the background smart-alarm session. Keep exact-wake force-fire and light fallback unchanged.
  - Fetch recorder history off-main-actor from `max(armedAt, wakeWindowStart - 2h)` to `now - 3m` at session start, then refresh recorder backfill every 60 seconds while the session is alive.
- Replace [WakeHeuristicEngine.swift](/Users/petergelgor/Documents/projects/Lights%20Timer/Lights%20Timer%20Watch%20App/Services/WakeHeuristicEngine.swift) with a multi-signal engine:
  - Maintain 1s bins and 5s/30s/60s/180s rolling windows for motion; maintain time-aware HR windows driven by actual sample timestamps.
  - Compute these live features:
    - `motionEnergy60s`: average magnitude of live user acceleration over 60s.
    - `motionBurst30s`: count of micro-burst events above threshold in 30s.
    - `rotationVariance60s`: variance of `rotationRate` over 60s.
    - `postureShift300s`: gravity/attitude change versus trailing 5m orientation baseline.
    - `stillnessBreakScore`: current 90s motion versus recorder-derived trailing 90m sleep-motion baseline.
    - `hrDelta`: latest BPM minus personal sleep baseline.
    - `hrSlope180s`: weighted BPM slope over the last 3 minutes.
    - `hrFreshnessPenalty`: penalty when latest HR sample is older than 90s.
    - `motionFreshnessPenalty`: penalty when live motion has gaps larger than 2s.
  - Composite confidence:
    - `0.55` motion arousal
    - `0.20` motion trend versus overnight baseline
    - `0.20` HR arousal
    - `0.05` proximity-to-wake prior
  - Trigger rules:
    - Early trigger always requires motion evidence; HR alone can never trigger.
    - First 5 minutes of the wake window use a higher threshold.
    - Final 10 minutes lower the composite threshold slightly.
    - Final 3 minutes may trigger on strong motion-only evidence if HR is stale.
    - Exact wake always force-fires.
- Extend [SmartWakeMessage.swift](/Users/petergelgor/Documents/projects/Lights%20Timer/Lights%20Timer%20Watch%20App/Models/SmartWakeMessage.swift):
  - Add `SmartWakeCalibrationProfile` to `SmartWakeSyncPayload`.
  - Extend `SmartWakeTriggerPayload` with `motionScore`, `hrFreshnessSeconds`, `motionFreshnessSeconds`, and `sensorProvenance`.
  - Add a watch-local persisted `SmartWakeOccurrenceSummary` containing trigger time, score trace summaries, sample gaps, and fallback reason.
- Add iPhone-side post-hoc calibration:
  - Introduce a new calibration service that reads `SleepAnalysis`, wrist temperature, respiratory rate, blood oxygen, and HRV the next morning.
  - Use sleep stages only as labels for adaptation:
    - raise motion threshold if recent early triggers landed in `AsleepDeep`,
    - lower threshold slightly if exact-wake fallback happened despite `Awake`/`REM` appearing shortly before wake,
    - reduce HR weight if HR gaps are consistently large for that user,
    - keep all changes bounded and apply EMA over the last 14 nights.
  - Sync the updated calibration profile back to watch on the normal schedule payload path.
- Power-mode behavior:
  - `balanced`: becomes the new motion-first production path.
  - Existing overnight-workout behavior is no longer part of the main algorithm; keep it diagnostics-gated only if you want it for experiments, not for default user behavior.

## Test Plan
- **Capability and permission cases**:
  - motion recorder available / unavailable
  - motion authorization granted / denied
  - HR permission granted / denied
  - sleep-stage and overnight-vitals permissions granted / denied on iPhone
- **Wake-window behavior**:
  - live motion only, no HR
  - sparse HR plus strong motion
  - dense HR plus weak motion
  - recorder backfill unavailable for first 3 minutes
  - exact-wake fallback
  - recovered scheduled session after process relaunch
- **Accuracy regression harness**:
  - replay saved occurrence summaries and recorded accelerometer slices through the heuristic engine deterministically
  - verify HR-only spikes never trigger
  - verify strong stillness-break + posture-shift patterns inside the window trigger early
  - verify repeated deep-sleep false positives tighten thresholds over subsequent nights
- **Performance and battery**:
  - keep recorder parsing and feature extraction off the main actor
  - verify CPU stays below the threshold that risks `exceededResourceLimits`
  - verify no frame drops or UI lockups while diagnostics are open

## Assumptions and Defaults
- Wake policy is `Balanced`.
- The main production algorithm does **not** depend on starting a workout after the scheduled alarm session begins, because HealthKit explicitly disallows starting or preparing a workout while the app is backgrounded.
- Live motion during the scheduled smart-alarm session is treated as a supported input because Apple defines smart alarms as monitoring heart rate and motion, and CoreMotion is available on watchOS; exact motion-delivery behavior still needs on-device validation.
- Wrist temperature, respiratory rate, blood oxygen, HRV, and sleep stages are intentionally excluded from live triggering and used only for next-day personalization.
- Bedtime arm reminders are outside this data-engine plan; if added later, make them a separate configurable reminder feature rather than coupling them to the heuristic work.

## Sources
- [Using extended runtime sessions](https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions)
- [Monitor your heart rate with Apple Watch](https://support.apple.com/en-us/120277)
- [Track your nightly wrist temperature changes with Apple Watch](https://support.apple.com/en-tm/102674)
- [How to use the Blood Oxygen app on Apple Watch](https://support.apple.com/en-us/120358)
- [Track your sleep with Apple Watch](https://support.apple.com/en-lamr/guide/watch/-apd830528336/watchos)
- [CMSensorRecorder.h](/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS26.2.sdk/System/Library/Frameworks/CoreMotion.framework/Headers/CMSensorRecorder.h)
- [CMMotionManager.h](/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS26.2.sdk/System/Library/Frameworks/CoreMotion.framework/Headers/CMMotionManager.h)
- [HKWorkoutSession.h](/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS26.2.sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKWorkoutSession.h)
- [HKDefines.h](/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS26.2.sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKDefines.h)
- [HKTypeIdentifiers.h](/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS26.2.sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKTypeIdentifiers.h)
