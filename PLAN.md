# Fix: Smart Wake Extended Runtime Session Expires Before Wake Window

## Problem Summary

The `WKExtendedRuntimeSession` (smart alarm type) provides **~30 minutes of background runtime** ([Apple docs](https://developer.apple.com/documentation/watchkit/wkextendedruntimesession)). The current code starts the session **1 hour before the wake window** (`baselineCollectionLeadTime = 3600s`), so the entire 30-minute budget is consumed during baseline collection, and the session dies 30 minutes before the wake window even opens.

**User's case**: wake at 07:30, 30-min window (07:00–07:30). Session started at 06:00, expired at 06:30. Wake window and force-fire at 07:30 were never reachable.

**Secondary issues compounding the failure**:
- Workout session fails immediately ("cannot start in background") → degraded mode with very sparse HR samples (~1 every 5 min)
- All future-dated HR samples rejected (watchOS/HealthKit bug delivering samples with June 2026 dates)
- Historical seed returned 8 samples from 05:30–05:57, but the baseline window is 06:00–06:55, so none qualified
- Baseline never became ready → no early trigger possible → force-fire at wake time was the only path, but the session died 30 min before that

## Root Cause

In `SmartAlarmScheduler.swift:63`:
```swift
private let baselineCollectionLeadTime: TimeInterval = 3600 // 1 hour
```

This is used at line 349:
```swift
let baselineStart = windowStart.addingTimeInterval(-baselineCollectionLeadTime)
```

And `baselineStart` is used as the session's scheduled start time (line 355, 473). The session starts 1 hour before the wake window, burning its entire 30-minute budget before the window opens.

## Fix Strategy

Shift the extended runtime session start time so the ~30-minute budget covers the actual wake window (where triggering and force-fire happen). Build the heuristic baseline entirely from **historical HealthKit data** (passive overnight HR samples already stored on the watch) instead of live monitoring during a pre-window session.

This works because:
1. Apple Watch records heart rate every few minutes during sleep — this data is already in HealthKit
2. The app already has a `startHistoricalSeed()` method that queries HealthKit for past samples
3. The heuristic engine's `seedHeartRateSamples()` already processes historical data correctly
4. The historical seed query range (`wakeUpTime - 2h` to `now`) already covers the baseline window

## Changes

### 1. `SmartAlarmScheduler.swift` — Fix session start timing

**What changes**: Replace the fixed 1-hour `baselineCollectionLeadTime` with a dynamic session start calculation that respects the ~30-minute budget.

**Specific edits**:

a) Replace constant at line 63:
```swift
// REMOVE:
private let baselineCollectionLeadTime: TimeInterval = 3600

// ADD:
/// Conservative budget for the extended runtime session. Apple grants ~30 min
/// for smart-alarm sessions; we use 27 min to leave margin for setup/teardown.
private let safeSessionBudget: TimeInterval = 27 * 60

/// Small buffer before the effective monitoring start for workout/query setup.
private let sessionSetupBuffer: TimeInterval = 120  // 2 minutes
```

b) In `schedulesDidUpdate(_:)`, replace the baseline/session start calculation (around lines 346–356):
```swift
// CURRENT:
let baselineStart = windowStart.addingTimeInterval(-baselineCollectionLeadTime)
let nextWake = PendingWake(
    schedule: nextSchedule,
    wakeUpTime: wakeUpTime,
    windowStart: windowStart,
    baselineStart: baselineStart,
    scheduledSessionStart: baselineStart
)

// REPLACEMENT:
let sessionStart = computeSessionStart(windowStart: windowStart, wakeUpTime: wakeUpTime)
let nextWake = PendingWake(
    schedule: nextSchedule,
    wakeUpTime: wakeUpTime,
    windowStart: windowStart,
    baselineStart: sessionStart,
    scheduledSessionStart: sessionStart
)
```

c) Add the computation method:
```swift
/// Compute the session start time to maximize wake-window coverage
/// within the ~30-minute extended runtime session budget.
///
/// For short wake windows (≤25 min): session starts `sessionSetupBuffer`
/// before the window, so the full window plus setup fits in the budget.
///
/// For longer wake windows (>25 min): session starts so that wake time
/// falls safely within the budget. The tail end of the window (closest to
/// wake time) is prioritized — early-trigger opportunities at the window
/// start are sacrificed if the window exceeds the budget.
private func computeSessionStart(windowStart: Date, wakeUpTime: Date) -> Date {
    let idealStart = windowStart.addingTimeInterval(-sessionSetupBuffer)
    let latestViableStart = wakeUpTime.addingTimeInterval(-safeSessionBudget)
    // Use whichever is later — ensures wake time is always reachable
    return max(idealStart, latestViableStart)
}
```

d) Update `desiredSessionStart` calculation (line 473) — no change needed structurally since it already does `max(baselineStart, now + 1)`, and `baselineStart` is now `sessionStart`.

e) Update `armingState` displays: everywhere `monitoringStart: baselineStart` is used in armed state, it now reflects the session start time (which is what we want to show the user).

### 2. `SmartAlarmScheduler.swift` — Add force-fire safety net in `willExpire`

**What changes**: When the session is about to expire during active monitoring in/near the wake window, force an immediate wake check so the watch can fire before the session dies.

**Specific edits** in `extendedRuntimeSessionWillExpire` (around line 1019):

```swift
// CURRENT (after the willExpire log):
if !self.sessionController.isMonitoringActive,
   self.sessionController.sessionState != .triggered,
   let pending = self.pendingSchedule {
    self.startMonitoringNow(schedule: pending.schedule, wakeUpTime: pending.wakeUpTime)
}

// REPLACEMENT:
if !self.sessionController.isMonitoringActive,
   self.sessionController.sessionState != .triggered,
   let pending = self.pendingSchedule {
    self.startMonitoringNow(schedule: pending.schedule, wakeUpTime: pending.wakeUpTime)
} else if self.sessionController.isMonitoringActive,
          self.sessionController.sessionState != .triggered {
    self.logStore.log(
        "SCHEDULER",
        "Session expiring while monitoring is active — forcing immediate wake check",
        level: .warning
    )
    self.sessionController.forceImmediateWakeCheck()
}
```

### 3. `SmartWakeSessionController.swift` — Expose `forceImmediateWakeCheck`

**What changes**: Add a public method that the scheduler can call when the session is about to expire.

```swift
/// Called by the scheduler when the extended runtime session is about to expire.
/// Runs an immediate wake check so the watch can force-fire before losing background execution.
func forceImmediateWakeCheck() {
    checkForWakeTrigger()
}
```

### 4. `SmartAlarmScheduler.swift` — Add force-fire on unexpected session invalidation

**What changes**: In `extendedRuntimeSession(didInvalidateWith:)`, if monitoring is active in/past the wake window and no trigger has fired, force-fire immediately before background execution ends.

In the `didInvalidateWith` delegate (around line 1084):

```swift
// ADD before the existing `else if sessionController.isMonitoringActive` check:
} else if self.sessionController.isMonitoringActive,
          self.sessionController.sessionState != .triggered {
    // Session died while monitoring — force one last wake check.
    // If we're at/past wake time, this will fire. If not, the fallback
    // scene at wake time is the safety net.
    self.logStore.log(
        "SCHEDULER",
        "Extended runtime session invalidated during active monitoring — forcing final wake check",
        level: .warning
    )
    self.sessionController.forceImmediateWakeCheck()
    self.armingState = .failed(message: "Session expired during monitoring")
```

### 5. Update `CLAUDE.md` — Document the session budget constraint

Update the Smart Wake section to document:
- The extended runtime session budget is ~30 minutes (Apple platform constraint)
- The session is scheduled to maximize wake-window coverage, not baseline collection
- Baseline is built entirely from historical HealthKit data via `startHistoricalSeed`
- For wake windows longer than ~25 minutes, the session covers the end of the window (near wake time) and early-trigger opportunities at the window start may be limited

## What This Does NOT Fix (Known Limitations)

1. **Workout session fails in background**: `HKWorkoutSession.startActivity` fails with "cannot start a workout session while in the background" when called from an extended runtime session callback. This is a watchOS platform limitation — you cannot start a new workout session from the background, even within an active extended runtime session. The app correctly falls back to degraded mode. This limitation is already handled by the existing degraded-monitoring path.

2. **Future-dated HR samples**: Some HealthKit samples arrive with dates months in the future (a watchOS/HealthKit bug). The existing filter correctly rejects these. No code change needed.

3. **Degraded-mode HR sample rate**: In degraded mode (no workout session), passive HR queries deliver samples infrequently (~every 5 minutes). This limits early-trigger sensitivity, but force-fire at wake time remains guaranteed. With the session now covering the wake window, even sparse samples during the window can contribute to trigger decisions.

## Verification

1. Build watch target: `xcodebuild -target 'Lights Timer Watch App' -sdk watchsimulator26.2 build CODE_SIGNING_ALLOWED=NO`
2. For the user's scenario (wake 07:30, 30-min window):
   - Session should now start at ~07:00 - 2min = 06:58 (not 06:00)
   - Session budget covers 06:58–07:28+, with wake time (07:30) within reach
   - Historical seed (queried at 06:58) will fetch samples from 05:30–06:58, covering the baseline window (06:00–06:55)
   - Force-fire at 07:30 is reachable within the session budget
3. Real-device test required for actual HealthKit data and HomeKit control
