# Fix: Smart Wake Extended Runtime Session Expires Before Wake Window

## Problem Summary

The `WKExtendedRuntimeSession` (smart alarm type) provides **~30 minutes of background runtime** ([Apple docs](https://developer.apple.com/documentation/watchkit/wkextendedruntimesession)). The current code starts the session **1 hour before the wake window** (`baselineCollectionLeadTime = 3600s`), so the entire 30-minute budget is consumed during baseline collection, and the session dies before the wake window opens.

**User's case**: wake at 07:30, 30-min window (07:00–07:30). Session started at 06:00, expired at 06:30. Wake window and force-fire at 07:30 were never reachable.

**Secondary issues compounding the failure**:
- Workout session fails immediately ("cannot start in background") → degraded mode with very sparse HR samples (~1 every 5 min)
- Future-dated HR samples rejected (watchOS/HealthKit bug delivering samples with June 2026 dates)
- Historical seed returned 8 samples from 05:30–05:57, but the baseline window was 06:00–06:55, so none qualified
- Baseline never became ready → no early trigger possible → force-fire at wake time was the only path, but the session died 30 min before that

## Root Cause

In `SmartAlarmScheduler.swift:63`:
```swift
private let baselineCollectionLeadTime: TimeInterval = 3600 // 1 hour
```

This is used at line 349 to compute `baselineStart`:
```swift
let baselineStart = windowStart.addingTimeInterval(-baselineCollectionLeadTime)
```

And `baselineStart` is used as the session's scheduled start time (lines 355, 473). The session starts 1 hour before the wake window, burning its entire ~30-minute budget before the window opens.

## Fix Strategy

**Shift the extended runtime session start time** so the ~30-minute budget covers the actual wake window (where triggering and force-fire happen). **Build the heuristic baseline entirely from historical HealthKit data** (passive overnight HR samples already stored on the watch) instead of live monitoring during a pre-window session. **Relax baseline requirements** so passive overnight data reliably qualifies.

This works because:
1. Apple Watch records heart rate every few minutes during sleep — this data is already in HealthKit
2. The app already has a `startHistoricalSeed()` method that queries HealthKit for past samples (`SmartWakeSessionController.swift:267-270` queries `wakeUpTime - 2h` to `now`)
3. The heuristic engine's `seedHeartRateSamples()` already processes historical data correctly
4. With the session starting close to the wake window, the historical seed query will cover the full baseline period

### Timing math for the user's scenario (wake 07:30, 30-min window)

```
windowStart         = 07:00
idealStart          = windowStart - 2min  = 06:58
latestViableStart   = wakeUpTime - 25min  = 07:05
sessionStart        = max(06:58, 07:05)   = 07:05  ← the later of the two

Session runs:     07:05 → ~07:35 (30-min budget)
Wake window:      07:00 → 07:30
Force-fire at:    07:30
Margin:           ~5 min between force-fire and session death

Historical seed:  queries 05:30 → 07:05 (wakeUpTime - 2h to now)
Baseline window:  05:00 → 06:55 (windowStart - 2h to windowStart - 5min)
                  ↑ widened from 1h to 2h to capture more passive overnight samples
```

The first 5 minutes of the wake window (07:00–07:05) are missed, but early triggers near the very start of the window are the least likely scenario — HR changes indicating wakefulness happen closer to natural wake time.

### Timing math for short windows (wake 07:30, 10-min window)

```
windowStart         = 07:20
idealStart          = windowStart - 2min  = 07:18
latestViableStart   = wakeUpTime - 25min  = 07:05
sessionStart        = max(07:18, 07:05)   = 07:18

Session runs:     07:18 → ~07:48
Wake window:      07:20 → 07:30  ← entirely within session budget
Margin:           ~18 min
```

### Timing math for long windows (wake 07:30, 60-min window)

```
windowStart         = 06:30
idealStart          = windowStart - 2min  = 06:28
latestViableStart   = wakeUpTime - 25min  = 07:05
sessionStart        = max(06:28, 07:05)   = 07:05

Session runs:     07:05 → ~07:35
Wake window:      06:30 → 07:30
Coverage:         last 25 of 60 min covered (tail end near wake time)
Margin:           ~5 min
```

---

## Changes

### Change 1: `SmartAlarmScheduler.swift` — Fix session start timing

**Why**: The session must start close enough to wake time that the ~30-minute budget covers the wake window and force-fire.

**Step 1a** — Replace constant at line 63:

```swift
// REMOVE this line:
private let baselineCollectionLeadTime: TimeInterval = 3600

// ADD these two lines in its place:
/// Conservative budget for the extended runtime session. Apple grants ~30 min
/// for smart-alarm sessions; we use 25 min to leave a ~5-minute safety margin
/// for force-fire at wake time.
private let safeSessionBudget: TimeInterval = 25 * 60

/// Small buffer before the wake window start for workout/query setup.
private let sessionSetupBuffer: TimeInterval = 120
```

**Step 1b** — In `schedulesDidUpdate(_:)`, replace lines 349–356. Find:

```swift
        let baselineStart = windowStart.addingTimeInterval(-baselineCollectionLeadTime)
        let nextWake = PendingWake(
            schedule: nextSchedule,
            wakeUpTime: wakeUpTime,
            windowStart: windowStart,
            baselineStart: baselineStart,
            scheduledSessionStart: baselineStart
        )
```

Replace with:

```swift
        let sessionStart = computeSessionStart(windowStart: windowStart, wakeUpTime: wakeUpTime)
        let nextWake = PendingWake(
            schedule: nextSchedule,
            wakeUpTime: wakeUpTime,
            windowStart: windowStart,
            baselineStart: sessionStart,
            scheduledSessionStart: sessionStart
        )
```

Note: The `PendingWake.baselineStart` field is reused to hold the session start time. The field name is a misnomer after this change — it no longer represents when baseline collection starts (the baseline is now built from historical HealthKit data). However, renaming it would cascade through `PendingWake`, `SmartWakePendingWakeRecord`, persistence, recovery, and display code — too much churn for this fix. A follow-up rename is fine.

**Step 1c** — Add the computation method. Place it in the `// MARK: - Schedule Helpers` section (after line 736, before `findNextRelevantOccurrence`):

```swift
    /// Compute the session start time to maximize wake-window coverage
    /// within the ~30-minute extended runtime session budget.
    ///
    /// - Short wake windows (≤ safeSessionBudget - setupBuffer): session starts
    ///   `sessionSetupBuffer` before the window, covering the full window.
    /// - Long wake windows: session starts `safeSessionBudget` before wake time,
    ///   prioritizing the tail of the window (closest to wake time).
    private func computeSessionStart(windowStart: Date, wakeUpTime: Date) -> Date {
        let idealStart = windowStart.addingTimeInterval(-sessionSetupBuffer)
        let latestViableStart = wakeUpTime.addingTimeInterval(-safeSessionBudget)
        return max(idealStart, latestViableStart)
    }
```

**Step 1d** — Fix `matchesOccurrence` in the `PendingWake` struct (lines 30–35). Find:

```swift
    func matchesOccurrence(_ other: PendingWake) -> Bool {
        schedule.id == other.schedule.id
            && wakeUpTime == other.wakeUpTime
            && windowStart == other.windowStart
            && baselineStart == other.baselineStart
    }
```

Replace with:

```swift
    func matchesOccurrence(_ other: PendingWake) -> Bool {
        schedule.id == other.schedule.id
            && wakeUpTime == other.wakeUpTime
            && windowStart == other.windowStart
    }
```

**Why**: `baselineStart` is now a derived value (computed from `windowStart` and `wakeUpTime`). Two wakes for the same schedule/occurrence should always match regardless of session timing. Without this change, a persisted wake record saved with the old 1-hour lead time would fail to match a freshly computed wake with the new timing, causing unnecessary session cancellation and re-arming.

**Step 1e** — No changes needed to:
- Line 473 (`desiredSessionStart = max(baselineStart, now.addingTimeInterval(1))`) — still correct; `baselineStart` is now `sessionStart`, and the `max` with `now + 1` handles the "already past session start" case.
- `armingState = .armed(wakeUpTime:, monitoringStart: baselineStart)` references (lines 399, 448, 604) — these now show the session start time, which is what the user should see (when monitoring will begin, not when a hypothetical baseline window starts).
- `scheduleAlarmSession(at:schedule:wakeUpTime:windowStart:baselineStart:)` — the `baselineStart` parameter now receives `sessionStart`, which flows through to `PendingWake` and persistence correctly.

### Change 2: `SmartAlarmScheduler.swift` — Force-fire safety net in `willExpire`

**Why**: If the session is about to expire while monitoring is active but no trigger has fired, we need to run one final wake check. If we're at/past wake time, this fires the trigger before the session dies. If we're before wake time, it's a no-op and the HomeKit fallback scene at wake time is the safety net.

In `extendedRuntimeSessionWillExpire` (lines 1019–1024), find:

```swift
            // Only force-start monitoring if nothing has triggered yet
            if !self.sessionController.isMonitoringActive,
               self.sessionController.sessionState != .triggered,
               let pending = self.pendingSchedule {
                self.startMonitoringNow(schedule: pending.schedule, wakeUpTime: pending.wakeUpTime)
            }
```

Replace with:

```swift
            if !self.sessionController.isMonitoringActive,
               self.sessionController.sessionState != .triggered,
               let pending = self.pendingSchedule {
                // Session expiring before monitoring started — last chance to start it
                self.startMonitoringNow(schedule: pending.schedule, wakeUpTime: pending.wakeUpTime)
            } else if self.sessionController.isMonitoringActive,
                      self.sessionController.sessionState != .triggered {
                // Session expiring during monitoring — force one last wake check
                // so we can fire before losing background execution
                self.logStore.log(
                    "SCHEDULER",
                    "Session expiring while monitoring is active — forcing immediate wake check",
                    level: .warning
                )
                self.sessionController.forceImmediateWakeCheck()
            }
```

### Change 3: `SmartWakeSessionController.swift` — Expose `forceImmediateWakeCheck`

**Why**: The scheduler needs to trigger a wake check from `willExpire` and `didInvalidate` callbacks. `checkForWakeTrigger()` is currently private.

Add this method in the `// MARK: - Wake Check` section (after `startWakeCheckTimer`, before `checkForWakeTrigger`), around line 673:

```swift
    /// Called by the scheduler when the extended runtime session is about to expire
    /// or has been invalidated. Runs an immediate wake check so the watch can
    /// force-fire before losing background execution.
    func forceImmediateWakeCheck() {
        checkForWakeTrigger()
    }
```

### Change 4: `SmartAlarmScheduler.swift` — Force-fire on unexpected session invalidation

**Why**: If the session dies unexpectedly during active monitoring (e.g., budget exhausted, system pressure), we should attempt one last wake check before the app loses background execution entirely.

In `extendedRuntimeSession(didInvalidateWith:)` (lines 1084–1091), find:

```swift
            } else if self.sessionController.isMonitoringActive
                || self.sessionController.sessionState == .triggered {
                self.armingState = .monitoringNow
```

Replace with:

```swift
            } else if self.sessionController.isMonitoringActive,
                      self.sessionController.sessionState != .triggered {
                self.logStore.log(
                    "SCHEDULER",
                    "Extended runtime session invalidated during active monitoring — forcing final wake check",
                    level: .warning
                )
                self.sessionController.forceImmediateWakeCheck()
                self.armingState = .failed(message: "Session expired during monitoring")
            } else if self.sessionController.sessionState == .triggered {
                self.armingState = .monitoringNow
```

Note: The original code had a single `else if` that covered both `isMonitoringActive` and `.triggered` with `||`. We split it into two branches: one for active-monitoring-not-yet-triggered (force-fire + mark failed), and one for already-triggered (keep `.monitoringNow` as before, since post-trigger work is in progress and the trigger already fired).

### Change 5: `WakeHeuristicEngine.swift` — Relax baseline requirements for historical data

**Why**: The baseline is now built entirely from historical HealthKit data (passive overnight samples). Apple Watch records HR every ~5–10 minutes during sleep. The old requirements (8 samples within a 1-hour window) were designed for live monitoring with a workout session delivering frequent samples. With passive data only, these thresholds are too strict and the baseline may never become ready.

In `WakeHeuristicEngine.swift`, find (lines 32–35):

```swift
    private let baselineLookback: TimeInterval = 3600
    private let baselineCutoffBeforeWindow: TimeInterval = 300
    private let minimumBaselineSamples = 8
    private let minimumBaselineSpan: TimeInterval = 900
```

Replace with:

```swift
    private let baselineLookback: TimeInterval = 7200          // 2 hours
    private let baselineCutoffBeforeWindow: TimeInterval = 300 // 5 minutes before wake window
    private let minimumBaselineSamples = 5                     // Reduced from 8 for passive data
    private let minimumBaselineSpan: TimeInterval = 900        // 15 minutes (unchanged)
```

**What each value does**:
- `baselineLookback = 7200`: The baseline window is now `windowStart - 2h` to `windowStart - 5min`. For a 07:00 window start, this means 05:00–06:55 instead of 06:00–06:55. Doubles the time span where passive HR samples can qualify.
- `minimumBaselineSamples = 5`: At ~5–10 min passive sample rate, a 2-hour window yields ~12–24 samples. Requiring only 5 means the baseline becomes ready even if sampling is sparse or some samples were filtered out (e.g., future-dated ones).
- `minimumBaselineSpan = 900`: Kept at 15 minutes. With passive sampling every 5–10 min, 5 samples naturally span 20–50 minutes. This guard prevents the edge case where all samples cluster in a brief burst, which would make the median unrepresentative of resting HR.

### Change 6: Update `CLAUDE.md` — Document the session budget constraint

In the Smart Wake section (step 3, "Bounded watch execution model"), update to reflect:

- The extended runtime session budget is ~30 minutes (Apple platform constraint for smart-alarm type sessions)
- The session is now scheduled to maximize wake-window coverage: `sessionStart = max(windowStart - 2min, wakeUpTime - 25min)`
- Baseline is built entirely from historical HealthKit data via `startHistoricalSeed`, not live pre-window monitoring
- The heuristic baseline window is 2 hours before the wake window (widened from 1 hour) with relaxed sample requirements (5 samples spanning 15 minutes)
- For wake windows longer than ~23 minutes, the session covers the tail end of the window; early-trigger opportunities at the window start may be limited
- `willExpire` and `didInvalidate` both force an immediate wake check as a safety net

---

## What This Does NOT Fix (Known Limitations)

1. **Workout session fails in background**: `HKWorkoutSession.startActivity` fails with "cannot start a workout session while in the background" when called from within an extended runtime session callback. This is a watchOS platform limitation. The app correctly falls back to degraded mode with passive HR queries. No code change needed — the existing degraded-monitoring path handles this.

2. **Future-dated HR samples**: Some HealthKit samples arrive with dates months in the future (likely a watchOS/HealthKit bug). The existing filter in `WakeHeuristicEngine.addHeartRateSample` correctly rejects these. No code change needed.

3. **Degraded-mode HR sample rate**: In degraded mode (no workout session), passive HR queries deliver samples infrequently (~every 5 minutes). This limits early-trigger sensitivity compared to a workout session (~every few seconds). However, with the session now covering the wake window, even sparse samples during the window can contribute to trigger decisions. Force-fire at wake time remains guaranteed regardless.

---

## Verification

1. Build watch target:
   ```bash
   xcodebuild -target 'Lights Timer Watch App' -sdk watchsimulator26.2 build CODE_SIGNING_ALLOWED=NO
   ```
2. Build iOS target (embeds watch app):
   ```bash
   xcodebuild -target 'Lights Timer' -sdk iphonesimulator26.2 build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO
   ```
3. For the user's scenario (wake 07:30, 30-min window):
   - Session should start at **07:05** (not 06:00)
   - Session budget covers 07:05–~07:35, with force-fire at 07:30 safely inside (~5 min margin)
   - Historical seed (queried at ~07:05) fetches samples from 05:30–07:05, covering the widened baseline window (05:00–06:55)
   - Baseline should become ready from passive overnight HR samples
   - If session expires unexpectedly, `willExpire`/`didInvalidate` force one last wake check
4. Real-device test required for actual HealthKit data and HomeKit light control
