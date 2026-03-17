# Fix: Watch Battery Drain (~60% Overnight)

## Context

The watch app is draining roughly 60% battery overnight and does not dismiss back to the clock face. The user opened the app before bed, went to sleep, and in the morning the watch was still showing the app in the same scroll position. That is not acceptable behavior for this product because Smart Wake is supposed to monitor near wake time, not pin the app frontmost all night.

The runtime log from the night of March 15-16 proves the root causes.

**Log evidence — proactive workout keeping the app frontmost all night:**
```text
23:48:01 [SCHEDULER] Starting proactive workout session for 'Wake Up home'
23:48:02 [HEALTHKIT] Workout session started and live collection began
23:48:07 [SCHEDULER] App returned to foreground — re-evaluating proactive workout
00:10:50 [SCHEDULER] App returned to foreground — re-evaluating proactive workout
01:15:28 [SCHEDULER] App returned to foreground — re-evaluating proactive workout
02:37:30 [SCHEDULER] App returned to foreground — re-evaluating proactive workout
04:25:07 [SCHEDULER] App returned to foreground — re-evaluating proactive workout
06:01:22 [SCHEDULER] App returned to foreground — re-evaluating proactive workout
```
There were 38+ wrist-raise events between 11:48 PM and 6:01 AM. Each one woke the display and showed the full app UI because the `HKWorkoutSession` with `workout-processing` background mode makes the app frontmost. watchOS shows the app instead of the clock face. The display is the single biggest battery consumer here.

**Log evidence — background scheduling failure:**
```text
2026-03-15T13:17:11.606 [CONNECTIVITY] Received 3 smart-wake schedule snapshot(s) from phone
2026-03-15T13:17:11.634 [ERROR] [SCHEDULER] Extended runtime session invalidated with error:
    The app must be active and before applicationWillResignActive to start or schedule a WKExtendedRuntimeSession.
```
WCSession `didReceiveApplicationContext` can fire while the app is in the background. The `onSchedulesUpdated` callback triggers `schedulesDidUpdate`, which calls `scheduleAlarmSession` -> `session.start(at:)`. watchOS rejects this because the app is not active. The session is invalidated and the wake can remain silently unarmed.

**Log evidence — "too far in advance" scheduling failure (repeated 13+ times on March 13):**
```text
2026-03-13T10:53:15.249 [ERROR] Extended runtime session invalidated with error:
    An attempt was made to schedule a WKExtendedRuntimeSession too far in advance.
```
`WKExtendedRuntimeSession` alarm sessions can only be scheduled about 36 hours ahead. The current code has no guard, so repeated foreground re-evaluation attempts fail when the next wake is days away.

**Baseline bug is already fixed — commit `f0ca75f` on `main`:**
The future-dated sample poisoning and premature baseline freeze were already fixed in that commit. `seedHeartRateSamples` and `addHeartRateSample` now reject samples more than 120 seconds in the future. `freezeBaselineIfNeeded` now uses wall-clock time instead of the incoming sample timestamp. That means the 1-hour live HR monitoring lead time is now required for a healthy baseline and must not be reduced.

## Why This Change Exists

This change is not a generic cleanup. It has a very specific product goal:

1. Smart Wake must still gather one hour of live HR before the wake window so the heuristic can build a real baseline.
2. Smart Wake must still load historical overnight HealthKit data, still evaluate early triggers, still force-fire at exact wake time, and still preserve haptics, phone handoff, watch-local fallback, and HomeKit fallback scene behavior.
3. The app must stop holding the watch frontmost all night. Opening the watch app before bed must no longer start an all-night workout.
4. The watch must tell the truth about whether Smart Wake is actually armed. Silent failures are unacceptable because this is an alarm feature.

In short: keep Smart Wake behavior, remove the all-night execution model.

## Root Causes (in order of battery impact)

### 1. Proactive `HKWorkoutSession` runs all night (~90% of drain)
`SmartAlarmScheduler.evaluateProactiveWorkout()` starts an `HKWorkoutSession` whenever the app is foregrounded and a smart wake schedule exists within 12 hours. This makes the app frontmost and lights the display on every wrist raise for 8+ hours.

### 2. No guards on `WKExtendedRuntimeSession.start(at:)` (~5% of drain via repeated failures and unarmed wakes)
Background WCSession delivery and too-far-in-advance scheduling both cause invalidation. The scheduler wastes work on doomed scheduling attempts and can leave the wake unarmed without telling the user.

### 3. `scheduleMonitoringStart` uses a long-delay in-process timer (structural bug)
The `monitoringTimer` bridges the gap between proactive workout start at bedtime and monitoring start one hour before the wake window. Without the proactive workout keeping the process alive, this timer is not a valid overnight execution mechanism. It must be removed.

### 4. No ambient view during active monitoring (~5% of drain)
During the roughly 90 minutes when the workout session is legitimately needed, the full `List` UI renders on wrist raise. That is unnecessary OLED cost.

### 5. Watch logging is overly expensive during active monitoring (secondary issue)
The app logs every live HR sample, logs every heuristic evaluation, and refreshes the log archive metadata on every log append. This is not the main overnight drain, but it is still wasted work during the bounded monitoring window and should be fixed in the same change.

## Solution Overview

Remove the proactive workout. Schedule the `WKExtendedRuntimeSession` to fire at `baselineStart` (`windowStart - 1 hour`). When it fires, start monitoring immediately, which starts a just-in-time workout session. That workout runs for about 90 minutes total, not 8+ hours. Add guards so the app only tries to arm a session when watchOS will actually accept it. Add an ambient view for the monitoring period. Expose explicit arming state in the UI so the user can see whether Smart Wake is truly armed.

**New lifecycle:**
```text
EVENING: User opens app -> schedules evaluated -> extended runtime session armed for baselineStart
         -> app returns to clock face after ~2 min (no workout holding it frontmost)
         -> clock face shows on every wrist raise all night

baselineStart (for example, 5:40 AM for a 7:30 wake with a 30 min window):
  -> Extended runtime session fires
  -> startMonitoringNow() -> startWorkoutSession() + HR query + historical seed + wake check timer
  -> workout-processing keeps app alive and takes over from extended runtime session
  -> App may become frontmost during monitoring only; ambient view shows on wrist raise

windowStart:
  -> Baseline freezes (should now be ready from 1 hour of live samples)
  -> Heuristic evaluates for early trigger

wakeUpTime:
  -> Force-fire if no early trigger
  -> Haptics + handoff + lights
  -> Workout ends after post-trigger cleanup
```

## Change 1: Remove proactive workout session

**Why**: The proactive workout exists only to keep the app alive from bedtime until monitoring start. That is the wrong tradeoff because it keeps the app frontmost all night. `WKExtendedRuntimeSession` gives the app scheduled background execution without pinning the app to every wrist raise. The workout session is still valid, but only once active monitoring begins.

### File: `Lights Timer Watch App/Services/SmartAlarmScheduler.swift`

**1a. Delete `proactiveWorkoutHorizon` (line 28):**
```swift
// DELETE:
private let proactiveWorkoutHorizon: TimeInterval = 43200  // 12 hours
```
**Why**: There is no longer a proactive workout to start within a horizon.

**1b. Rename `monitoringLeadTime` for clarity (line 27):**
```swift
// BEFORE:
private let monitoringLeadTime: TimeInterval = 3600

// AFTER:
private let baselineCollectionLeadTime: TimeInterval = 3600
```
**Why**: This constant defines how far before the wake window live HR collection starts so the heuristic can build a baseline. The old name is ambiguous. The value must remain `3600` seconds. Do not reduce it.

**1c. Delete `evaluateProactiveWorkout()` (lines 150-200):**
Delete the entire method.

**Why**: This is the code that starts a workout session hours before it is needed. It is the direct cause of the all-night frontmost behavior.

**1d. Remove the `evaluateProactiveWorkout(schedules)` call from `schedulesDidUpdate()` (line 145):**
```swift
// DELETE:
evaluateProactiveWorkout(schedules)
```
**Why**: It is the only internal caller of the deleted method.

**1e. Delete `monitoringTimer`, `scheduleMonitoringStart()`, and all long-delay timer cleanup:**

Delete the `monitoringTimer` property declaration:
```swift
// DELETE:
private var monitoringTimer: Timer?
```

Delete the entire `scheduleMonitoringStart()` method.

Remove `monitoringTimer?.invalidate()` and `monitoringTimer = nil` from every cleanup site that only exists to support the long-delay overnight timer.

**Why**: The long-delay timer is only valid if something else keeps the process alive all night. That “something else” is the very proactive workout we are removing. The extended runtime session will now fire at the actual monitoring start time instead.

**1f. Repurpose `onAppForeground()` so it never starts a workout:**
```swift
// BEFORE:
func onAppForeground() {
    logStore.log("SCHEDULER", "App returned to foreground — re-evaluating proactive workout")
    evaluateProactiveWorkout(sessionManager.activeSchedules)
}

// AFTER:
func onAppForeground() {
    logStore.log("SCHEDULER", "App returned to foreground — re-evaluating schedules")
    schedulesDidUpdate(sessionManager.activeSchedules)
}
```
**Why**: `LightsTimerWatchApp.swift` calls this on `scenePhase == .active`. That behavior is still useful because reopening the watch app must allow a previously unarmed wake to be armed. But it must not start a workout.

### File: `Lights Timer Watch App/Services/SmartWakeSessionController.swift`

**1g. Delete `startProactiveWorkoutSession()` (lines 527-537):**
Delete the entire method.

**Why**: It has no valid role once proactive workout start is removed.

**1h. Delete `endProactiveWorkoutSession()` (lines 539-545):**
Delete the entire method.

**Why**: Dead code after removing the proactive path.

**1i. Replace the “reuse proactive workout” branch in `startMonitoring()` with teardown-then-fresh-start:**

The current `startMonitoring()` has an `if workoutSession != nil` branch that assumes a proactive workout is already running. Replace that with:

```swift
if workoutSession != nil {
    log("SESSION", "Tearing down stale workout state before fresh monitoring start", level: .warning)
    await endWorkoutSession()
}

do {
    try await startWorkoutSession()
    isWorkoutSessionRunning = true
    startHeartRateQuery(from: Date())
    startWakeCheckTimer()
    checkForWakeTrigger()
    startHistoricalSeed(
        from: wakeUpTime.addingTimeInterval(-historicalSeedLookback),
        to: Date()
    )
    log("SESSION", "Monitoring started successfully for schedule \(schedule.id.uuidString)")
} catch {
    log(
        "SESSION",
        "Workout session failed: \(error.localizedDescription). Switching to degraded monitoring.",
        level: .warning
    )
    startDegradedMonitoring()
}
```

**Why**: With the proactive workout removed, a pre-existing workout should not exist. If it does, that state is stale and must be torn down before a fresh monitoring run starts.

## Change 2: Reschedule extended runtime session for `baselineStart` and add arming guards

**Why**: The current extended runtime session fires too late and assumes watchOS will accept any `start(at:)` call. Neither is true. The session must fire when the 1-hour live HR baseline collection needs to begin, and the scheduler must only arm it when the app is active and the wake is within the supported horizon.

### File: `Lights Timer Watch App/Services/SmartAlarmScheduler.swift`

**2a. Change `schedulesDidUpdate()` to schedule at `baselineStart`, not `wakeTime - min(window, 30)`:**

Replace the current “inside wake window” check and `desiredSessionStart` calculation with:

```swift
let baselineStart = windowStart.addingTimeInterval(-baselineCollectionLeadTime)

if now >= baselineStart && now < wakeUpTime {
    logStore.log(
        "SCHEDULER",
        "Already inside the monitoring period for '\(nextSchedule.name)'; starting monitoring immediately"
    )
    scheduledMonitoringDate = nil
    startMonitoringNow(schedule: nextSchedule, wakeUpTime: wakeUpTime)
    return
}

let armingHorizon: TimeInterval = 35 * 3600
if baselineStart.timeIntervalSince(now) > armingHorizon {
    logStore.log(
        "SCHEDULER",
        "Wake '\(nextSchedule.name)' at \(formatTimestamp(wakeUpTime)) is beyond the 35-hour arming horizon; will re-evaluate later",
        level: .warning
    )
    // update arming state to tooEarlyToArm
    return
}

let appState = WKApplication.shared().applicationState
guard appState == .active else {
    logStore.log(
        "SCHEDULER",
        "Cannot arm extended runtime session — app is not active (state=\(appState.rawValue)). Will arm on next foreground.",
        level: .warning
    )
    // if the newly evaluated wake is materially different from the currently armed wake,
    // cancel the stale armed session before returning
    // update arming state to needsForegroundToArm
    return
}

let desiredSessionStart = max(baselineStart, now.addingTimeInterval(1))
scheduleAlarmSession(
    at: desiredSessionStart,
    schedule: nextSchedule,
    wakeUpTime: wakeUpTime,
    windowStart: windowStart
)
```

**Why**:
- `baselineStart` is the real start of live HR monitoring, so the session must fire there.
- The 35-hour guard prevents the repeated “too far in advance” invalidations already proven in the log.
- The active-state guard prevents `mustBeActiveToStartOrSchedule` failures from background WCSession delivery.

**Materially different** for the inactive-app path means the next relevant wake occurrence would behave differently if left armed as-is. Treat changes to the upcoming occurrence’s wake time, wake window / `baselineStart`, or other execution-critical parameters for that occurrence as materially different. Do **not** treat broader repeat-day edits as materially different when the already-armed upcoming occurrence is still functionally the same. Example: changing Tue/Wed/Thu 7:30 AM to weekdays 7:30 AM for the same next Tuesday wake should keep the existing armed session; changing the same upcoming wake from 7:30 AM to 9:00 AM must cancel the old armed session immediately and surface `.needsForegroundToArm`.

**2b. Update `scheduleAlarmSession()` so `scheduledMonitoringDate` is just the scheduled session date:**
```swift
// BEFORE:
let monitoringStart = windowStart.addingTimeInterval(-monitoringLeadTime)
scheduledMonitoringDate = max(monitoringStart, date)

// AFTER:
scheduledMonitoringDate = date
```
**Why**: The session now fires at `baselineStart`, which is the real monitoring start.

**2c. Make `extendedRuntimeSessionDidStart` start monitoring immediately:**
```swift
if let pending = self.pendingSchedule {
    self.startMonitoringNow(schedule: pending.schedule, wakeUpTime: pending.wakeUpTime)
}
```
**Why**: Once the session fires, the app is already inside the one-hour monitoring period. There is no more deferred timer.

**2d. Preserve equivalent pending wake state, but cancel stale armed wakes that are materially different:**

The existing invalidation path already leaves `pendingSchedule` intact. Keep that behavior. Add explicit arming-state updates and improved logs for:
- inactive app scheduling
- too-far-in-advance scheduling
- unexpected invalidation after an armed wake

On inactive schedule updates:
- if the newly evaluated next wake is functionally equivalent to what is already armed for the same upcoming occurrence, keep the existing armed session and defer reconciliation until the next foreground pass
- if it is materially different, cancel the stale armed session immediately and move to `.needsForegroundToArm`

**Why**: The re-arming path should come from `onAppForeground()` re-running `schedulesDidUpdate()`, but the user also needs to know when the currently armed wake is stale and can no longer be trusted.

## Change 3: Expose explicit scheduler arming state in the UI

**Why**: Fixing the scheduling guards is not enough. This is an alarm product. If a wake is not armed because the app is in the background or because the wake is too far away, the user must be told explicitly. Logs are not sufficient. A fresh implementation that only adds logs would still leave silent user-facing failure.

### File: `Lights Timer Watch App/Services/SmartAlarmScheduler.swift`

**3a. Add a public arming-state model:**

Add a small enum such as:
```swift
enum SmartWakeArmingState: Equatable {
    case noUpcomingWake
    case armed(Date)
    case monitoringNow
    case needsForegroundToArm(wakeUpTime: Date)
    case tooEarlyToArm(wakeUpTime: Date, earliestArmingDate: Date)
    case failed(message: String)
}
```

Expose it on the scheduler as `private(set) var armingState`.

Update it in all scheduler paths:
- no upcoming smart wake -> `.noUpcomingWake`
- valid session armed -> `.armed(baselineStart)`
- already inside monitoring period -> `.monitoringNow`
- inactive app guard -> `.needsForegroundToArm(wakeUpTime: wakeUpTime)`
- >35h guard -> `.tooEarlyToArm(wakeUpTime: wakeUpTime, earliestArmingDate: baselineStart - 35h)`
- unexpected invalidation -> `.failed(message: ...)`

**Why**: This makes scheduler truth explicit and testable.

### File: `Lights Timer Watch App/LightsTimerWatchApp.swift`

**3b. Make the scheduler a first-class watch service so the view can read its state directly:**

Create `SmartAlarmScheduler` during `init`, not lazily in `.task`, and inject it into the environment just like `logStore`, `sessionManager`, and `sessionController`.

Do not keep `alarmScheduler` optional. It should be created up front on watchOS and used consistently.

Keep the existing callback wiring:
- `sessionManager.onSchedulesUpdated`
- `sessionManager.onLightHandoff`
- `sessionController.onLogReadyToTransfer`

**Why**: `WatchRootView` needs direct access to the scheduler state. Mirroring arming state through another service adds ambiguity for no benefit.

### File: `Lights Timer Watch App/Views/WatchRootView.swift`

**3c. Read the scheduler from the environment and surface arming truth in the status section:**

Add:
```swift
@Environment(SmartAlarmScheduler.self) private var alarmScheduler
```

Update the idle-state subtitle so it is based on `alarmScheduler.armingState`, not just `nextScheduleDescription`.

Required user-visible messages:
- `.armed(date)` -> `Smart Wake armed for 06:10`
- `.needsForegroundToArm` -> `Open the watch app to arm Smart Wake for 07:30`
- `.tooEarlyToArm` -> `Too early to arm this wake; reopen after 8:00 PM on March 16`
- `.noUpcomingWake` -> `No upcoming smart wake`
- `.failed` -> explicit error string

**Why**: This prevents silent alarm-risk states and gives the user a correct mental model of whether Smart Wake will actually run.

## Change 4: Add Always On Display ambient view

**Why**: During the roughly 90 minutes when the workout session is valid and the app may be frontmost, the full list UI is unnecessary. A minimal ambient view lowers OLED cost while preserving the active UI when the user interacts with the watch.

### File: `Lights Timer Watch App/Views/WatchRootView.swift`

**4a. Add `isLuminanceReduced` environment value:**
```swift
@Environment(\.isLuminanceReduced) private var isLuminanceReduced
```

**4b. Replace `body` with conditional rendering:**
```swift
var body: some View {
    if isLuminanceReduced && isActiveSession {
        ambientMonitoringView
    } else {
        fullView
    }
}
```

**4c. Extract the current body into `fullView`:**
Keep the existing `NavigationStack` and `List` exactly as they are today.

**4d. Add helper properties:**
```swift
private var isActiveSession: Bool {
    sessionController.sessionState == .monitoring || sessionController.sessionState == .triggered
}

private var ambientMonitoringView: some View {
    VStack(spacing: 8) {
        Image(systemName: "moon.zzz.fill")
            .font(.title2)
            .foregroundStyle(.gray)
        Text("Smart Wake Active")
            .font(.caption)
            .foregroundStyle(.gray)
        if let desc = nextScheduleDescription {
            Text(desc)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
```

**Why**: The ambient view must be minimal, static, and honest. It should show that Smart Wake is active without redrawing the full diagnostics list.

## Change 5: Reduce watch-side logging overhead

**Why**: This is a secondary battery fix and an overall efficiency improvement. Once the overnight frontmost issue is fixed, the next avoidable cost is the amount of file I/O and string formatting done during active monitoring.

### File: `Lights Timer Watch App/Services/SmartWakeSessionController.swift`

**5a. Stop unconditional per-sample HR logging in production by adding a runtime diagnostics flag:**

The current code logs every live HR sample in `processHeartRateSamples()`. Replace the current always-on behavior with a dedicated runtime diagnostics flag that defaults to off and can be enabled in non-debug builds.

**Why**: Per-sample logging is useful for debugging but not necessary for normal overnight operation.

### File: `Lights Timer Watch App/Services/WakeHeuristicEngine.swift`

**5b. Gate verbose baseline and confidence logs behind the same runtime diagnostics flag:**

The detailed logs in:
- `configure`
- baseline recompute failures/successes
- confidence updates
- wake evaluation verdicts

should only be emitted when the runtime diagnostics flag is enabled.

Always keep:
- configuration start
- historical seed success/failure
- trigger decision that actually fired
- trigger rejection for important lifecycle errors

**Why**: The heuristic does not need to write a line for every state recalculation in production.

### File: `Lights Timer Watch App/Services/SmartWakeLogStore.swift`

**5c. Remove per-append archive rescans from `log(...)`:**

Today `log(...)` writes one line, mirrors it to console, and immediately rescans the log directory by calling `refreshAvailableLogs(...)`.

Replace this with:
- a `logsDirty` boolean set on every append
- metadata refresh only when:
  - a session log is prepared
  - the watch logs UI opens
  - a share/export/transfer action needs fresh metadata

**Why**: Directory rescans on every append are wasted I/O during active monitoring.

## Change 6: Update the architecture docs in the same change

**Why**: This repo explicitly requires architecture docs to be updated when workflows change. Leaving the docs stale will cause the next agent to reintroduce the old design by mistake.

### Files:
- `CLAUDE.md`
- `AGENTS.md`

### Required doc updates

**6a. Replace the old three-tier Smart Wake model with the new bounded model:**
- no proactive workout at bedtime
- one-hour live HR baseline collection begins at `baselineStart`
- extended runtime session arms only when app is active and wake is within the supported horizon
- extended runtime session only bootstraps the just-in-time workout
- workout lifetime is limited to the one-hour baseline period, wake window, and post-trigger cleanup

**6b. Document the arming guards and user-visible states:**
- watch app must be active to arm
- wakes beyond the arming horizon are intentionally deferred
- watch UI exposes `armed`, `needs foreground`, and `too early` states explicitly

**6c. Document the ambient monitoring UI and logging changes:**
- ambient view during monitoring/triggered state in luminance-reduced mode
- verbose monitoring logs are behind a runtime diagnostics flag that is available in non-debug builds

## What Is NOT Changing

These parts of the product must remain functionally identical:
- `startWorkoutSession()` stays the same
- `startHeartRateQuery()` stays the same open-ended anchored query
- `startWakeCheckTimer()` stays at the same 10-second cadence
- `checkForWakeTrigger()` keeps the same early-trigger and exact-wake force-fire logic
- `WakeHeuristicEngine` baseline windows, thresholds, freeze behavior, and future-date filtering do not change
- `startHistoricalSeed()` still uses the same historical lookback
- `fireTrigger()` still handles haptics, phone handoff, and deferred light fallback
- `finishMonitoringAfterTrigger()` still keeps the workout alive through post-trigger work, then tears it down
- `waitForPostTriggerWork()`, `stopMonitoring()`, `failMonitoring()`, and `startDegradedMonitoring()` stay behaviorally the same
- HomeKit fallback scene behavior stays the same
- WCSession trigger, handoff, and state messaging stay the same
- Test mode stays the same
- All iPhone-side logic stays the same unless a doc reference must be updated
- `baselineCollectionLeadTime` must remain 3600 seconds

## Files To Modify

| File | What changes |
|------|-------------|
| `Lights Timer Watch App/Services/SmartAlarmScheduler.swift` | Delete proactive workout, delete `monitoringTimer`/`scheduleMonitoringStart`, rename lead-time constant, schedule at `baselineStart`, add arming guards, add explicit arming state, update extended runtime delegate handling |
| `Lights Timer Watch App/Services/SmartWakeSessionController.swift` | Delete proactive workout methods, replace proactive-workout reuse branch with teardown-then-fresh-start, gate per-sample logging behind a runtime diagnostics flag |
| `Lights Timer Watch App/LightsTimerWatchApp.swift` | Create and inject `SmartAlarmScheduler` as a first-class environment service on watchOS |
| `Lights Timer Watch App/Views/WatchRootView.swift` | Read scheduler from environment, show explicit arming-state messaging, add `isLuminanceReduced`, extract `fullView`, add ambient monitoring view |
| `Lights Timer Watch App/Services/SmartWakeLogStore.swift` | Remove per-append log directory refreshes and replace with lazy metadata refresh |
| `Lights Timer Watch App/Services/WakeHeuristicEngine.swift` | Gate verbose heuristic logging behind the same runtime diagnostics flag |
| `CLAUDE.md` | Update three-tier -> bounded two-phase model, add scheduling guards, add arming-state docs, add ambient-view/logging docs |
| `AGENTS.md` | Update authoritative architecture map to match the new Smart Wake execution model |

## Verification

1. **Build**: `xcodebuild -target 'Lights Timer Watch App' -sdk watchsimulator26.2 build CODE_SIGNING_ALLOWED=NO`
2. **App dismissal**: Open the watch app before bed and let it idle. Verify the clock face returns after the normal watchOS timeout. There must be no green workout indicator overnight before `baselineStart`. The runtime log must not contain bedtime proactive-workout start lines after this change.
3. **Arming while active**: With the watch app open and the next wake within 35 hours, verify the scheduler arms for `baselineStart`, `scheduledMonitoringDate == baselineStart`, and the UI says Smart Wake is armed.
4. **Arming guard — background**: Push schedules from the phone while the watch app is not active. Verify the scheduler logs that it cannot arm because the app is inactive and does not emit `mustBeActiveToStartOrSchedule`. If the newly evaluated next wake is materially different from what is armed, verify the stale armed session is cancelled and the UI tells the user to reopen the watch app to arm Smart Wake. If the newly evaluated next wake is functionally equivalent for the same upcoming occurrence, verify the existing armed session is preserved until the next foreground re-evaluation.
5. **Arming guard — too far**: Create or keep a wake more than 35 hours away. Verify the scheduler does not call `start(at:)`, does not emit `too far in advance`, and the UI shows the `too early to arm` state.
6. **Monitoring start**: At `baselineStart`, verify the extended runtime session fires and immediately starts monitoring: workout session, HR query, wake-check timer, and historical seed.
7. **Baseline**: After one hour of live monitoring, verify baseline is ready at wake-window start. This is the first end-to-end validation after `f0ca75f`.
8. **Trigger path**: Verify either early trigger or exact-wake force-fire. Confirm haptics, phone handoff, watch-local fallback, and post-trigger cleanup still work.
9. **Failure path**: Force workout startup failure or unexpected workout termination during monitoring. Verify degraded mode still preserves the wake-time trigger path.
10. **AOD**: During monitoring, lower the wrist and verify the ambient “Smart Wake Active” view appears. Raise the wrist and verify the full UI returns.
11. **Arming-state UI**: Verify the watch status subtitle is truthful in all cases: armed, unarmed because inactive, unarmed because too early, no wake, and failure.
12. **Logging**: In a release-style run with diagnostics disabled, verify per-sample HR spam is gone and log metadata is not rescanned on every append. Then enable the runtime diagnostics flag in a non-debug build and verify detailed monitoring logs become available again.
13. **Battery**: Overnight battery drain should drop substantially versus the current all-night proactive-workout behavior.

## Guardrails

- Do not reduce the one-hour live HR pre-window collection period.
- Do not change `WakeHeuristicEngine` baseline math or thresholds in this fix.
- Do not add overnight periodic wakes or “sample every 15 minutes” logic.
- Do not depend on multiple future `WKExtendedRuntimeSession.start(at:)` alarms in one wake flow.
- Do not hide arming failures in logs only. The user-facing watch UI must show the true arming state.
- Do not skip updating `AGENTS.md` and `CLAUDE.md` in the same change.
