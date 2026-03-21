# Plan: Fix Smart Wake Overnight Session Issues

## Context

The Smart Wake feature failed during an overnight session on 2026-03-19. Three issues were identified from the runtime log:

1. **HKWorkoutSession died immediately** — "Client application cannot start a workout session while in the background" when the extended runtime session fired at 7:05am
2. **Future-dated HR samples** — 15 samples with dates in June-July 2026 arrived in the initial anchored query callback, creating log noise (correctly rejected by the heuristic engine)
3. **Infrequent HR sampling** — Without an active workout session, passive HR monitoring only delivered samples every ~5 minutes. The wake-check timer ran every 10 seconds against the same stale data, and the heuristic never reached the 0.6 confidence threshold, forcing a fallback fire at exactly 7:30am

These issues are interconnected: Issue 1 directly causes Issue 3. The fix for Issue 1 is the primary change.

Two additional residual issues were identified in the runtime log and are addressed in Issue 4.

---

## Prerequisite: Validate No-Builder Workout Session (HARD GATE)

**Implementation of Issue 1 MUST NOT proceed until this spike passes or fails. The entire proactive-session design depends on the outcome.**

The core of this plan assumes `HKWorkoutSession` without `HKLiveWorkoutBuilder` provides both overnight background execution (via `workout-processing` mode) and workout-frequency HR sampling. The current codebase only exercises the builder-backed path (`SmartWakeSessionController.swift` line 485). This assumption is unproven.

**Validation spike** (physical watch required):
1. Create an `HKWorkoutSession` with `.other` activity type, set its delegate, call `startActivity(with: Date())`. Do NOT create a builder or call `beginCollection()`.
2. Start an `HKAnchoredObjectQuery` for heart rate.
3. Send the app to background. Observe:
   - **Pass criterion A**: App stays alive in background (workout-processing mode engaged)
   - **Pass criterion B**: HR samples arrive via the anchored query at noticeably higher frequency than passive (~5min) — expect every few seconds
   - **Pass criterion C**: After calling `session.end()`, no workout entry appears in the Health app and no Activity Rings credit is added

**If the spike passes**: Proceed with Issue 1 as designed (no-builder proactive session).

**If the spike fails** (no frequent HR without a builder, OR Activity Rings pollution without a builder): Two options, requiring a product decision before proceeding:

**Option A — discardWorkout() path (preferred if rings pollution is unacceptable):**
Use the builder but call `builder.discardWorkout()` instead of `builder.finishWorkout()` for proactive sessions. This substitution must be made in **every** workout teardown path that can run while a proactive-origin session is active:
- `stopProactiveWorkout()` (new method, pre-monitoring teardown) — must call `builder.endCollection(at:)` then `builder.discardWorkout()` then nil out builder
- `endWorkoutSession()` (~line 508) — currently calls `finishWorkout()` unconditionally; must branch: if the session originated as a proactive session (`isProactiveOrigin`), call `discardWorkout()` instead
- `finishMonitoringAfterTrigger()` (~line 282) — defers to `endWorkoutSession()`, so inherits the fix automatically
- The `didChangeTo(.ended)` delegate (~line 1270) — if the session ends externally during proactive mode, the builder may still be live; teardown must discard, not finish
- The `didFailWithError` delegate (~line 1285) — same as above

A `isProactiveOrigin` flag (set at proactive start, cleared when a fresh builder-backed session replaces it at monitoring start) gates the branch.

**Caveat**: Apple docs say `discardWorkout()` "discards the workout and any associated data that the builder collected." Whether HR samples also exist independently in HealthKit's general store (i.e., survive the discard) needs validation. If discarding kills the HR data that the heuristic engine already consumed from the anchored query, this is a non-issue — the heuristic already has the data in memory. But it could affect the historical seed for subsequent sessions.

**Option B — accept the workout artifact:**
Keep using `finishWorkout()` and accept that an overnight `.other` workout appears in Health app. This is the simplest path but pollutes workout history. Some sleep-tracking apps (AutoSleep, Sleep Cycle) do this already.

**The spike result determines which code path is implemented. Do not proceed with Issue 1 until one of these paths is validated.**

---

## Cross-Cutting: True Foreground Detection

**Problem:** `WKApplication.shared().applicationState` returns `.active` during extended runtime session execution, even though the app is not in true foreground. The March 19 log proves this: at 07:31:03, `schedulesDidUpdate()` passed the `applicationState == .active` guard (line 456) and reached `scheduleAlarmSession()` → `start(at:)`, which watchOS then rejected at 07:31:04 with "The app must be active and before applicationWillResignActive." This means `applicationState` is unreliable for distinguishing true foreground from extended-runtime-active context.

**Solution:** Track a `isSceneActive` flag on `SmartAlarmScheduler`, driven by SwiftUI scene phase changes rather than `applicationState`. Scene phase callbacks do NOT fire during extended runtime execution, WCSession background delivery, or process recovery — they only fire when the user actually brings the app to foreground.

### Changes

#### SmartAlarmScheduler.swift

S1. **Add property** `private(set) var isSceneActive = false`

S2. **Modify `onAppForeground()`** — Set `isSceneActive = true` before calling `schedulesDidUpdate()`.

S3. **Add method `onAppBackground()`** — Sets `isSceneActive = false`. Does NOT call `schedulesDidUpdate()` or any other evaluation.

S4. **Replace `WKApplication.shared().applicationState == .active` at line 456** with `isSceneActive`. This is the primary gate that prevents session scheduling from background contexts. The existing `applicationState` check passes during extended runtime execution (proven by the March 19 log); `isSceneActive` does not.

S5. **Use `isSceneActive` everywhere the plan needs a foreground check** — Steps 11a, 11b, and 34 all reference foreground guards. They all use `isSceneActive` instead of `applicationState`.

#### LightsTimerWatchApp.swift

S6. **Modify `onChange(of: scenePhase)`** — Add an `else` branch that calls `services.alarmScheduler.onAppBackground()` when `newPhase != .active`. This ensures `isSceneActive` is cleared when the app goes to `.inactive` or `.background`.

S7. **Fix cold-launch hole in `.task`** — The existing `.task` (line 42) calls `schedulesDidUpdate()` before `onChange(of: scenePhase)` ever fires. On a cold foreground launch with schedules already hydrated, `isSceneActive` is still `false`, so the scheduler would incorrectly take the `needsForegroundToArm` path even though the user is visibly in the app.

**Timing subtlety:** SwiftUI's `.task` runs when the view first appears, which can happen while `scenePhase` is still `.inactive` (mid-launch transition). On a cold foreground launch, the typical sequence is: `.task` fires → `scenePhase` transitions to `.active` → `.onChange` fires. If `.task` evaluates schedules with `isSceneActive = false` while the phase is `.inactive`, it would transiently set `armingState = .needsForegroundToArm` and persist a pending wake (Step 34a) — then `.onChange` fires `.active` shortly after and re-evaluates correctly. The end state is correct, but the transient evaluation is wasteful (unnecessary UserDefaults write from 34a) and may flash "Needs foreground to arm" in the UI.

**Fix:** At the top of the `.task` block, before the `schedulesDidUpdate()` call (line 42), branch on the current scene phase with a three-way check:
```swift
if scenePhase == .active {
    // Cold foreground launch where .task runs after scene is already active
    services.alarmScheduler.onAppForeground()
} else if scenePhase == .inactive {
    // Mid-launch transition — .active is imminent.
    // Skip evaluation entirely; .onChange(of: scenePhase) will fire .active
    // momentarily and call onAppForeground() → schedulesDidUpdate().
    // Evaluating here with isSceneActive=false would transiently hit
    // needsForegroundToArm and persist stale state via Step 34a.
    services.logStore.log("APP", "Deferring schedule evaluation — scenePhase is .inactive, .active onChange imminent")
} else {
    // .background — genuine background launch (recovery/WKExtensionDelegate).
    // Evaluate with isSceneActive=false so the inactive-app path runs correctly.
    services.alarmScheduler.schedulesDidUpdate(services.sessionManager.activeSchedules)
}
```
This replaces the current bare `schedulesDidUpdate()` call at line 42. The `.inactive` branch defers to `.onChange` rather than evaluating with incorrect `isSceneActive` state. The `.background` branch preserves the existing recovery behavior. The `.active` branch handles the case where `.task` runs late (after the scene is already active).

**Why this works:** `isSceneActive` starts as `false` (process launch default). It becomes `true` either via `onAppForeground()` in the `.task` block (cold launch where `.task` runs after `.active`) or via `onChange(of: scenePhase)` (the more common path, plus all subsequent foreground transitions). It becomes `false` when the scene goes inactive/background. Extended runtime callbacks, WCSession background deliveries, and `WKExtensionDelegate.handle(_:)` recovery never change scene phase, so `isSceneActive` remains `false` in all those contexts. This is exactly the distinction `applicationState` fails to make.

**Edge case — `.task` defers but `.onChange` never fires:** This cannot happen on a cold foreground launch. The `.inactive` → `.active` transition is guaranteed by the system for a user-initiated launch. The only scenario where `.onChange` wouldn't fire `.active` is if the app was launched directly into background (recovery), which takes the `.background` branch, not the `.inactive` branch.

---

## Issue 1: Pre-start Workout Session from Foreground

### Root Cause

Apple requires `HKWorkoutSession.startActivity()` to be called while the app is in the **foreground**. The `WKExtendedRuntimeSession` alarm callback gives background execution time but NOT foreground status. The `workout-processing` background mode keeps an *already-running* workout alive overnight — it cannot *start* a new one from the background.

### Solution

Start the `HKWorkoutSession` from foreground when the user is actively using the watch app, not when the extended runtime session fires hours later. The workout session stays alive overnight via `workout-processing` background mode and is already providing frequent HR data when monitoring begins.

**Critical timing constraint — not at arming time.** The scheduler arms any wake within a 35-hour horizon (`armingHorizon` at line 70). If the user opens the watch app at 9 AM for a 7:30 AM next-morning wake, arming happens immediately — starting a workout session then would mean ~22 hours of active HR sensing, a severe battery regression. Instead, the proactive workout start is deferred until the monitoring start time is within a `maxProactiveLeadTime` window (10 hours). This window is checked both at arming time and on each subsequent foreground re-evaluation, so the workout starts at the latest foreground visit that falls within the lead time. If no foreground visit occurs within the window, the proactive workout never starts and monitoring falls through to the existing try-from-background path (which will likely fail → degraded mode). This is the same outcome as today's behavior.

**Key design decision — no builder for the proactive session (contingent on prerequisite spike).** The current `startWorkoutSession()` creates an `HKLiveWorkoutBuilder` and calls `builder.beginCollection()` / `builder.finishWorkout()`. This saves an `.other` workout to HealthKit. An 8-hour overnight workout would pollute workout history and skew activity metrics. The fix: the proactive session uses `HKWorkoutSession` alone — no builder, no `beginCollection()`, no `finishWorkout()`. The session still keeps the app alive and triggers frequent HR hardware sampling. HR samples go into HealthKit's general store regardless of whether a builder is collecting them. The existing `startWorkoutSession()` (with builder) remains available for the monitoring-phase fallback path. **If the prerequisite spike fails, this switches to the discardWorkout() or accept-artifact path per the Prerequisite section.**

**Battery tradeoff**: The proactive workout runs for up to `maxProactiveLeadTime` (10 hours) of active HR sensing — similar to sleep tracking apps (AutoSleep, Sleep Cycle). The `.other` activity type with no GPS minimizes impact. The 10-hour cap prevents the pathological case where early arming would run the workout all day.

### Changes

#### SmartWakeSessionController.swift

1. **Add property** `private(set) var isProactiveWorkoutRunning = false` near existing state properties (~line 38)

2. **Add property** `private var lastHRSampleDate: Date?` for diagnostic display only (shown in WatchRootView diagnostics as "Last HR: Xs ago" so the user can verify overnight HR delivery is active)

3. **Add property** `private var seenSampleUUIDs = Set<UUID>()` for cross-path deduplication (also used in Issue 2)

4. **Add method `preStartWorkoutSession()`** — Synchronous (not async). Creates `HKWorkoutSession` with the same `.other` / `.unknown` config, sets its delegate, calls `startActivity(with: Date())`. Does NOT create `HKLiveWorkoutBuilder`, call `beginCollection()`, or store a builder reference. Sets `isProactiveWorkoutRunning = true` and `isWorkoutSessionRunning = true`. If `HKWorkoutSession(healthStore:configuration:)` throws, logs the error but does NOT enter degraded mode (monitoring hasn't started). Because both `HKWorkoutSession.init` (throws, sync) and `startActivity` (void, sync) are synchronous, there is no race with the app losing foreground status.

    **State machine note:** After `preStartWorkoutSession()` returns, `isProactiveWorkoutRunning` is `true`. The delegate may later report `.ended` or failure asynchronously — but because the delegate uses `Task { @MainActor in }`, this callback is serialized on the main actor after `preStartWorkoutSession()` completes. There is no mid-method race. Steps 9-10 handle the async delegate callbacks and reset the flags. Between the sync return and the async delegate callback, the state is transiently optimistic — this is intentional and safe because no code path reads the flags in that sub-runloop window.

5. **Add method `isWorkoutSessionUsable() -> Bool`** — Returns `true` if `workoutSession != nil` and its state is `.running`. The `.prepared` state is excluded because it means `startActivity()` was never called, so the session is not actively sensing HR.

6. **Add method `stopProactiveWorkout()`** — Called from true teardown paths only: user-initiated disarm, session invalidation, wake-identity change (see Step 12 for the full list), or dead-session cleanup at monitoring start (Step 7). NOT called from `cancelAlarmSession()` because that is also used by the internal reschedule path. Calls `workoutSession?.end()`, nils out `workoutSession`, resets `isProactiveWorkoutRunning` and `isWorkoutSessionRunning`. Does NOT touch builder state since there is no builder (or calls `discardWorkout()` if using the fallback path). This ensures no workout is saved to HealthKit.

7. **Modify `startMonitoring()` (~line 256)** — Replace the current stale-teardown + `startWorkoutSession()` block with:
   - If proactive workout is usable (`isWorkoutSessionUsable()`) → reuse it. Log "Reusing proactive workout session for monitoring". Set `isProactiveWorkoutRunning = false` (now "owned" by monitoring). Proceed to start HR query, exact-wake timer, historical seed.
   - If proactive workout exists but died (session non-nil but not usable) → tear it down via `stopProactiveWorkout()`, then try `startWorkoutSession()` (the existing async/builder path). Fall back to degraded if that also fails.
   - If no proactive workout → original path (try `startWorkoutSession()`, catch → degraded)

8. **Modify `endWorkoutSession()` (~line 508)** — Also reset `isProactiveWorkoutRunning = false`. If using the `discardWorkout()` fallback path (spike failed), branch on `isProactiveOrigin`: call `discardWorkout()` for proactive-origin sessions, `finishWorkout()` for monitoring-origin sessions.

9. **Modify workout session delegate `didChangeTo` (~line 1270)** — Add branch: if `toState == .ended` and `isProactiveWorkoutRunning` but NOT `isMonitoringActive`, log "Proactive workout session ended before monitoring started" and reset `isProactiveWorkoutRunning` and `isWorkoutSessionRunning`. This makes overnight session death visible in the UI and logs.

10. **Same for `didFailWithError` delegate (~line 1285)** — Handle the proactive-but-not-yet-monitoring case identically.

**Known limitation — no recovery from overnight proactive session death.** If the proactive workout dies at (say) 2 AM, there is no way to restart it from background — that is the fundamental watchOS constraint this entire plan exists to work around. Steps 9-10 provide observability only. When monitoring starts at 7:05 AM via the extended runtime callback, Step 7's fallback path will attempt `startWorkoutSession()` from background, which will almost certainly fail with the same "cannot start while in background" error, resulting in degraded mode. This is identical to today's behavior. The proactive approach is a best-effort improvement for the happy path (session survives overnight), not a guarantee.

**Known limitation — process relaunch loses the proactive workout.** If watchOS evicts the process overnight and later relaunches it for the alarm session, `WatchExtensionDelegate.handle(_:)` (line 6) recovers the `WKExtendedRuntimeSession` via `attachRecoveredExtendedRuntimeSession()` (line 177), but there is no watchOS API to recover an in-flight `HKWorkoutSession`. The proactive workout is lost. Monitoring will attempt `startWorkoutSession()` from the recovered background session context — same failure as today → degraded mode. This materially limits Issue 1's upside: the proactive workout only helps when the process survives the full overnight period without eviction. Process survival is typical for workout-processing apps but not guaranteed.

#### SmartAlarmScheduler.swift

11. **Add constant** `private let maxProactiveLeadTime: TimeInterval = 10 * 3600` (10 hours).

11a. **Modify `scheduleAlarmSession()` (~line 620)** — After `session.start(at: date)`, check whether `baselineStart - now <= maxProactiveLeadTime` (use `baselineStart` from the `PendingWake`, NOT `scheduledSessionStart` — `baselineStart` is the computed monitoring start, while `scheduledSessionStart` may be a preserved value from a prior arming). If yes, call `sessionController.preStartWorkoutSession()` directly (synchronous, no `Task {}`). If no (too early), log "Deferring proactive workout start — monitoring is \(hours)h away, max lead time is 10h" and skip the workout start. The app is guaranteed foreground here because `scheduleAlarmSession()` is only reached after the `isSceneActive` guard (Step S4). Both the session init and `startActivity` are sync calls.

11b. **Add deferred proactive workout start in foreground re-evaluation** — In the `schedulesDidUpdate()` path (line ~295), after confirming the wake is still armed (`hasEquivalentArmedWake` returns true, line ~395), add a check: if `!sessionController.isProactiveWorkoutRunning` and `pendingSchedule.baselineStart - now <= maxProactiveLeadTime` and `isSceneActive`, call `sessionController.preStartWorkoutSession()` and log "Starting deferred proactive workout — monitoring in \(hours)h". Use `baselineStart` from the pending wake, same as Step 11a.

**The `isSceneActive` guard is mandatory.** `schedulesDidUpdate()` is called from `WatchAppServices.sessionManager.onSchedulesUpdated` (line 28-29 of `WatchAppServices.swift`), which receives WCSession deliveries on a background queue and transitions to `@MainActor` via `Task {}`. The `hasEquivalentArmedWake` early-return path (line 395-424) runs before the `isSceneActive` guard at line 456 (which only gates new arming). Without the explicit `isSceneActive` check here, a background WCSession delivery would attempt `preStartWorkoutSession()` from background — the exact failure this plan exists to fix.

This is the mechanism that picks up the workout start on a later foreground visit when arming happened too early. The foreground re-evaluation path already runs on every foreground entry (`App returned to foreground — re-evaluating schedules`).

12. **Do NOT hook `stopProactiveWorkout()` into `cancelAlarmSession()`.** `cancelAlarmSession()` (~line 672) is called from multiple paths including `rescheduleAlarmSession()` (~line 642), which is an internal reschedule for the same wake — not a true cancellation. If `cancelAlarmSession()` tears down the proactive workout, a premature extended runtime session that gets rescheduled (line 1105) would kill a valid proactive workout from background where it cannot be restarted. Instead, call `stopProactiveWorkout()` explicitly only in true teardown paths:
    - `disarmUpcomingWake()` (Step 14 — user-initiated disarm)
    - `didInvalidateWith` delegate (Step 13 — session invalidated)
    - `schedulesDidUpdate()` when the wake identity changes (different schedule ID or wake time than the current proactive workout's wake) — call `stopProactiveWorkout()` before arming the new wake

    `rescheduleAlarmSession()` preserves the proactive workout because the wake hasn't changed — only the extended runtime session timing is being adjusted.

13. **Modify `didInvalidateWith` delegate (~line 1153)** — After existing invalidation handling, if `sessionController.isProactiveWorkoutRunning` is true and monitoring is NOT active, call `sessionController.stopProactiveWorkout()`. The proactive workout should not outlive the extended runtime session that it was paired with. If the pending wake is preserved for foreground re-arm, the proactive workout will be restarted at re-arm time from foreground.

14. **Add public method `disarmUpcomingWake()`** — A dedicated public API for the UI layer. Disarm skips this occurrence on the watch immediately and sends a best-effort request to the phone to remove the HomeKit fallback scene. This is final for the specific occurrence and not reversible (re-arming the same occurrence would require toggling the schedule off and back on, or waiting for it to prune after 2 hours).

    **Phone-side disarm is best-effort.** If the phone is unreachable, the `disarmWake` message falls back to `transferUserInfo` which may arrive late — potentially after wake time, at which point the fallback scene has already fired. The watch UI surfaces this via a `disarmPending` state (see Step 14d) so the user knows the phone hasn't confirmed yet. If the phone never receives the disarm, the HomeKit fallback scene remains the tertiary safety net it always was — it fires, which is a worse outcome than a clean disarm but better than silently claiming the disarm succeeded.

    Encapsulates:
    1. Read the pending wake's `(scheduleID, wakeUpTime)` and persist it as the completed wake occurrence in `SmartWakePendingWakeStore` (new `saveCompletedWakeOccurrence` method — see Step 14a). This survives process relaunch so a recovered session doesn't re-arm the same disarmed wake. The existing `findNextRelevantOccurrence()` skips it. The record naturally prunes after 2 hours via `pruneCompletedWake()` (line 584), which is fine — by then the wake time has passed.
    2. Call `sessionController.stopProactiveWorkout()` explicitly (per Step 12, this is a true teardown path).
    3. `cancelAlarmSession(clearPersistedWake: true)` — handles the extended runtime session teardown and clears the persisted pending wake record, so process relaunch won't restore it.
    4. Send a `disarmWake` message to the phone (see Step 14b) so the phone removes its `LT_<shortID>_fallback` scene and suppresses recreation. Persist an unacked disarm record for this occurrence (see Step 14e) so `phoneDisarmPending` becomes true.
    5. Set `armingState = .noUpcomingWake`
    6. Log the disarm.

14a. **Add persistence for completed wake occurrence** — Add `saveCompletedWakeOccurrence(_ occurrence: (scheduleID: UUID, wakeUpTime: Date))` and `loadCompletedWakeOccurrence() -> (scheduleID: UUID, wakeUpTime: Date)?` and `clearCompletedWakeOccurrence()` to `SmartWakePendingWakeStore`. Uses a separate UserDefaults key (`smartWakeCompletedOccurrence`). `SmartAlarmScheduler.init` loads this on startup into `completedWakeOccurrence`. `pruneCompletedWake()` clears both the in-memory and persisted records.

14b. **Add `disarmWake` message type and phone-side handling** — New watch→phone message:

**Watch side** (both copies of `SmartWakeMessage.swift` + `WatchSessionManager.swift`):
- Add `WCMessageKey.disarmWake = "disarmWake"`
- Add `SmartWakeDisarmPayload: Codable` with `scheduleID: UUID` and `wakeUpTime: Date`
- Add `WatchSessionManager.sendDisarmWake(scheduleID:wakeUpTime:)` using `sendMessage` (fallback `transferUserInfo`)

**Phone side** (`WatchConnectivityService.swift` + `SmartWakeCoordinator.swift` + `ScheduleEngine.swift`):
- Add `disarmWake` case in `WatchConnectivityService.handleMessage`
- Wire to `SmartWakeCoordinator.handleDisarmWake(payload:)` which:
  1. **Validates occurrence freshness**: If `payload.wakeUpTime` is in the past (already expired), reject the disarm — send `disarmWakeAck` with `success: false` and `reason: "stale occurrence"` immediately, then return. This prevents a delayed `transferUserInfo` delivery of a March 19 disarm from affecting March 20's scene. The rejection ack is important: without it, the watch's unacked disarm record would linger until the 2h prune, showing a misleading pending warning for a disarm that will never be processed. No occurrence-match check beyond freshness — the original plan validated against `nextOccurrence(for:)`, but that function is purely calendar-based (line 776) and does not skip disarmed occurrences. After occurrence A is disarmed and persisted, `nextOccurrence(for:)` still returns A → occurrence B's disarm would be rejected as a mismatch. Since the plan supports overlapping disarms (Step 14e), occurrence-matching is incompatible. The freshness check is sufficient: a March 19 disarm arriving on March 20 is rejected because its `wakeUpTime` is in the past. A same-day disarm for a valid future `wakeUpTime` is always accepted — `addDisarmedOccurrence` is idempotent, and scene names are schedule-scoped so there is no risk of deleting the wrong day's scene (there is only ever one `LT_<shortID>_fallback` scene per schedule in HomeKit).
  3. If valid: persist the disarmed occurrence in `ScheduleEngine` (see Step 14c). If a sync is currently in flight (`isSyncing == true`), skip the immediate scene removal attempt and defer to the post-sync cleanup (see Step 14b-sync below). Otherwise, attempt `ScheduleEngine.removeSmartWakeFallbackScene(scheduleID:)` to delete the `LT_<shortID>_fallback` action set and its timer trigger.
  4. **Branch on scene removal outcome**:
     - **Sync in flight** (`isSyncing == true`): Do NOT attempt immediate removal or send an ack yet. The disarmed occurrence is already persisted (Step 14c). The in-flight sync may create a scene that needs to be cleaned up. Defer the ack to the post-sync cleanup path (Step 14b-sync).
     - **Scene removed successfully** (or no matching scene found — already gone): Send `disarmWakeAck` with `scheduleID`, `wakeUpTime`, and `success: true`.
     - **Scene removal failed** (HomeKit not ready — `homes.isEmpty`, or `removeActionSet` throws): Send `disarmWakeAck` with `scheduleID`, `wakeUpTime`, and `success: false` plus `reason`. The disarmed occurrence is still persisted (Step 14c), so `createScenesForSchedule()` will NOT recreate the scene on the next sync — but the existing scene/trigger remains live in HomeKit until the next `syncBackgroundScenes()` call cleans it up.

     **No separate retry tracking is needed for the non-racing case.** `syncBackgroundScenes()` (line 486) already calls `cleanupOldScenesAndTriggers()` (line 514) which wipes ALL `LT_`-prefixed scenes and triggers (line 567), then recreates only scenes for non-disarmed occurrences (gated by `isOccurrenceDisarmed()` from Step 14c). This means any stale fallback scene is always deleted on the next full sync — which happens on every phone foreground (`onAppActive()` → `syncBackgroundScenes()`) and on `onHomesUpdated` retry. If the phone never foregrounds before wake time, the stale scene fires (the user is warned via the watch pending banner).

14b-sync. **Handle disarms that arrive during an in-flight sync** — There is a race between `syncBackgroundScenes()` and `handleDisarmWake()`. Both run on `@MainActor`, but `syncBackgroundScenes()` is `async` with multiple `await` suspension points (HomeKit calls at lines 560, 570, 609, etc.). A disarm can execute during any of these suspensions:

**The race scenario:**
1. `syncBackgroundScenes()` starts → `cleanupOldScenesAndTriggers()` deletes all `LT_` scenes
2. `createScenesForSchedule()` enters for the disarmed schedule, passes the `isOccurrenceDisarmed()` check (not yet disarmed), reaches `await addActionSet(...)` — suspends
3. `handleDisarmWake()` runs at the suspension point: persists the disarmed occurrence, sees no matching scene (it's being created right now), would send `success: true`
4. `createScenesForSchedule()` resumes — creates the scene with actions and trigger
5. The watch cleared the pending warning on a false `success: true`, but the scene is now live

**Fix — defer ack when `isSyncing`:**
- In `handleDisarmWake()` (Step 14b item 3-4): when `isSyncing == true`, persist the disarmed occurrence but do NOT attempt removal and do NOT send the ack. Instead, record the pending ack in a `deferredDisarmAcks: [(scheduleID: UUID, wakeUpTime: Date)]` array on `ScheduleEngine`.
- At the end of `syncBackgroundScenes()`, after the `defer { isSyncing = false }` block completes the sync, check `deferredDisarmAcks`. For each entry:
  1. The disarmed occurrence is already persisted, so the just-completed `createScenesForSchedule()` either skipped the scene (if it read `isOccurrenceDisarmed()` after the persist) or created it (if it read before the persist — the race case).
  2. Attempt `removeSmartWakeFallbackScene(scheduleID:)` to clean up any scene that was created despite the disarm.
  3. Send the ack based on the removal outcome (success/failure, same logic as Step 14b item 4).
  4. Clear the entry from `deferredDisarmAcks`.
- `deferredDisarmAcks` is in-memory only. If the phone process restarts mid-sync, `isSyncing` resets to `false` and the next `syncBackgroundScenes()` handles the disarmed occurrence correctly via `isOccurrenceDisarmed()`. The watch's unacked disarm record survives (Step 14e) so the pending warning remains truthful.

**Why this is sufficient:** The race only exists while `isSyncing == true`. Outside of a sync, immediate removal + ack is safe because no concurrent scene creation can occur (single `@MainActor` thread, no suspension between the disarm persist and the ack send). The deferred ack ensures the watch only clears its pending state after the phone has confirmed the scene is truly gone.

14c. **Add phone-side disarmed occurrence persistence** — `ScheduleEngine` owns the persisted set of disarmed occurrences: `disarmedOccurrences: [(scheduleID: UUID, wakeUpTime: Date)]`, stored in UserDefaults via a private helper. `ScheduleEngine` is the sole owner because it is the only consumer — `createScenesForSchedule()` must check the set during every sync. Pruned on each `syncBackgroundScenes()` call when `wakeUpTime + 2 hours` has passed.

- Add `ScheduleEngine.addDisarmedOccurrence(scheduleID:wakeUpTime:)` — persists to UserDefaults.
- Add `ScheduleEngine.isOccurrenceDisarmed(scheduleID:wakeUpTime:) -> Bool` — checked by scene creation.
- Add `ScheduleEngine.pruneDisarmedOccurrences()` — called at the top of `syncBackgroundScenes()`.
- Add `ScheduleEngine.removeSmartWakeFallbackScene(scheduleID:)` — finds and removes the `LT_<shortID>_fallback` action set and its associated timer trigger from the HomeKit home. Called immediately when a valid disarm arrives.

**Phone-side scene sync must honor disarmed occurrences.** `ScheduleEngine.createScenesForSchedule()` (~line 578) currently calls `nextOccurrence(for:)` and always creates the fallback scene if the schedule has `usesSmartWake`. After this change, before creating the fallback scene, it checks `isOccurrenceDisarmed(scheduleID: schedule.id, wakeUpTime: wakeUpTime)`. If yes, skip the fallback scene for this occurrence and log the skip. This prevents `syncBackgroundScenes()` (triggered by every phone foreground via `onAppActive()` → `syncBackgroundScenes()`) from recreating the scene that the disarm just removed.

14d. **Add disarm ack and watch-side pending state** — The phone-side disarm is best-effort. The watch must surface whether the phone has confirmed scene removal.

**Watch side**:
- `phoneDisarmPending` is now a **computed property** derived from persisted state (see Step 14e), not an in-memory `Bool`. It returns `true` when an unacked disarm record exists in `SmartWakePendingWakeStore`. This survives process relaunch — if the watch sends a disarm, gets killed before the ack arrives, and relaunches, the UI still shows "(phone fallback pending)".
- `WatchRootView` shows the pending warning **independently of `armingState`**, not gated on `.noUpcomingWake`. After disarming, the scheduler will advance to tomorrow's wake on the next reevaluation (the completed/disarmed occurrence is skipped at line 869-873), so `armingState` typically moves to `.armed` within seconds. If the warning were gated on `.noUpcomingWake`, it would flash briefly and then vanish — even though today's phone fallback scene is still live and unconfirmed.
  - When `phoneDisarmPending` is true: show a persistent banner for each unacked disarm record in `unackedDisarmRecords`, e.g., "Phone fallback pending for 7:30 AM". Multiple banners can appear simultaneously if the user disarmed multiple occurrences (rare but possible). The banners are visible regardless of the current `armingState`, even when the scheduler is `.armed` for a future wake.
  - Each banner's display time comes from the corresponding `UnackedDisarmRecord.wakeUpTime`, formatted as time-only (e.g., "7:30 AM").
  - Individual banners disappear as their matching acks arrive (`success == true`) or when `pruneUnackedDisarms()` clears expired records.

**Phone side**:
- Add `WCMessageKey.disarmWakeAck = "disarmWakeAck"` to both copies of `SmartWakeMessage.swift`.
- Add `SmartWakeDisarmAckPayload: Codable` with `scheduleID: UUID`, `wakeUpTime: Date`, `success: Bool`, `scenePending: Bool`, and `reason: String?`. The `wakeUpTime` field makes the ack occurrence-aware so the watch can match it to the correct unacked disarm record (see rationale in Step 14e). The `scenePending` field tells the watch whether a live fallback scene remains on the phone (see ack semantics below).
- `SmartWakeCoordinator.handleDisarmWake()` sends an ack in all non-deferred cases (see Step 14b-sync for the deferred case):
  - `success: false, scenePending: false, reason: "stale occurrence"` on freshness rejection (Step 14b item 1) — sent immediately, no scene mutation, watch clears the unacked record
  - `success: true, scenePending: false` after successful scene removal (or scene already absent)
  - `success: false, scenePending: true, reason` on operational HomeKit failure (homes empty, removeActionSet threw) — the disarmed occurrence is still persisted to prevent recreation, but the existing scene remains live until the next `syncBackgroundScenes()` cleans it up (see Step 14b item 4); watch keeps the pending warning
- `SmartWakeDisarmAckPayload` fields: `scheduleID: UUID`, `wakeUpTime: Date`, `success: Bool`, `reason: String?`, `scenePending: Bool`. The `scenePending` field distinguishes between "disarm rejected, nothing to worry about" (`false`) and "disarm accepted but scene is still live" (`true`).
  - Stale rejection: `success: false, scenePending: false, reason: "stale occurrence"` — the disarm was invalid, no scene was touched, and the occurrence has passed.
  - Operational failure: `success: false, scenePending: true, reason: "HomeKit not ready"` — the disarm was valid and persisted, but the scene couldn't be removed yet.
  - Success: `success: true, scenePending: false` — scene removed or already absent.
- `WatchSessionManager` receives the ack, matches it to the unacked disarm record by `(scheduleID, wakeUpTime)`, and branches:
  - **`success == true`**: Remove the matching record from the persisted unacked disarm set (Step 14e). If no record matches (already pruned or cleared), this is a no-op.
  - **`success == false, scenePending == false`** (stale rejection): Remove the matching record. The phone definitively rejected the disarm — there is no pending scene to worry about. Keeping the record would show a misleading pending warning for a disarm that will never be processed.
  - **`success == false, scenePending == true`** (operational failure): The matching unacked disarm record remains. Log `"Phone disarm accepted but scene still live for \(wakeUpTime): \(reason)"`. The fallback scene is still live on the phone and may fire at wake time. The watch UI continues to show the pending warning for that specific occurrence. The pending state eventually clears when `pruneUnackedDisarms()` runs (wake time + 2h) — by then the scene has either fired or the wake time has passed and the warning is moot. **Known limitation:** `scenePending` is only truthful at ack time. The next `syncBackgroundScenes()` on the phone will clean up the stale scene (via `cleanupOldScenesAndTriggers()` + `isOccurrenceDisarmed()` blocking recreation), but the phone does not send a follow-up ack after that cleanup. The watch pending warning may therefore outlive the actual scene by up to one phone-foreground cycle. This errs on the side of caution (warning when no scene exists) rather than the dangerous direction (claiming clean when the scene is live). A proactive follow-up ack mechanism was considered and rejected — the complexity of tracking outstanding operational failures across syncs is not justified for a conservative warning that self-clears at the 2h prune.
  - **No matching record found** (ack for an already-cleared or pruned disarm): Log and ignore. This handles the case where a delayed `transferUserInfo` ack arrives after the disarm was already pruned.

14e. **Persist unacked disarm state as an occurrence-keyed set** — The unacked disarm state must survive watch process restarts AND support overlapping disarms. After disarming occurrence A, the scheduler advances to occurrence B immediately (line 869-873 skips the completed occurrence). The user can then disarm B while A's ack is still in flight. A singleton record would cause A's delayed ack to incorrectly clear B's pending state, or B's disarm to overwrite A's record.

**SmartWakePendingWakeStore.swift**:
- Add `UnackedDisarmRecord: Codable` with `scheduleID: UUID` and `wakeUpTime: Date`.
- Add `saveUnackedDisarm(_ record: UnackedDisarmRecord)` — appends to the persisted array under UserDefaults key `smartWakeUnackedDisarms`. Deduplicates by `(scheduleID, wakeUpTime)` before appending.
- Add `loadUnackedDisarms() -> [UnackedDisarmRecord]` — reads the full array.
- Add `removeUnackedDisarm(scheduleID: UUID, wakeUpTime: Date)` — removes the matching record from the persisted array. No-op if not found.
- Add `pruneUnackedDisarms()` — removes all records where `wakeUpTime + 2 hours < now`. Called alongside `pruneCompletedWake()`.
- Add `clearAllUnackedDisarms()` — empties the array. Used only in full state reset paths.

**SmartAlarmScheduler.swift**:
- `phoneDisarmPending` is a computed property that returns `true` when any unacked disarm record exists:
  ```swift
  var phoneDisarmPending: Bool {
      !pendingWakeStore.loadUnackedDisarms().isEmpty
  }
  ```
- Add `unackedDisarmRecords: [UnackedDisarmRecord]` computed property (delegates to `pendingWakeStore.loadUnackedDisarms()`) for UI access — `WatchRootView` iterates this to show per-occurrence pending banners.
- In `disarmUpcomingWake()` (Step 14, item 4): call `pendingWakeStore.saveUnackedDisarm(UnackedDisarmRecord(scheduleID: ..., wakeUpTime: ...))`. This appends to the set; it does not overwrite.
- When a phone ack arrives with `success == true`: call `pendingWakeStore.removeUnackedDisarm(scheduleID: ack.scheduleID, wakeUpTime: ack.wakeUpTime)`. Only the matching occurrence is cleared. Other unacked disarms are unaffected.
- When a phone ack arrives with `success == false`: the matching record remains. No state change.
- When `pruneCompletedWake()` runs: also call `pendingWakeStore.pruneUnackedDisarms()`. Records older than 2h are cleared — the warning is moot.
- On scheduler init: no special loading needed — `phoneDisarmPending` and `unackedDisarmRecords` are computed from the store on every access.

**Why an array instead of a dictionary**: The set is bounded (at most ~7 entries — one per active day in a week, and realistically 1-2 at a time). An array of `Codable` structs is simpler to persist in UserDefaults than a keyed dictionary, and linear scan for match/prune is trivially fast at this size.

**Why computed instead of cached**: Same rationale as before — UserDefaults reads are fast enough for UI access, and computed properties are always consistent with the persisted state by definition. No synchronization bugs possible.

Note: `rescheduleAlarmSession()` is only reached from `extendedRuntimeSessionDidStart` (line 1105), which is background execution. Starting a proactive workout there would hit the same background restriction we are solving. No proactive workout start in `rescheduleAlarmSession()`. The proactive workout is intentionally preserved across reschedules since the wake identity hasn't changed. Similarly, if the deferred-start check in Step 11b runs during a foreground pass but the extended runtime session has already started (i.e., we're already in the monitoring window), there is no value in starting a proactive workout — monitoring will handle the workout session directly.

#### WatchRootView.swift

15. **Update diagnostics section (~line 209)** — Show proactive workout status: green checkmark + "Workout Session (overnight)" when `isProactiveWorkoutRunning`, vs "(monitoring)" when `isWorkoutSessionRunning && !isProactiveWorkoutRunning`, vs gray xmark otherwise.

16. **Update armed status subtitle** — Append "(HR active)" when proactive workout is running, so the user gets confirmation that overnight HR monitoring is engaged.

17. **Add disarm action** — When the alarm is `.armed` (not yet monitoring), show a "Disarm" button that calls `SmartAlarmScheduler.disarmUpcomingWake()`. This is needed because the proactive workout runs overnight and there was previously no watch UI to cancel an armed (but not monitoring) alarm.

---

## Issue 2: Filter Future-Dated HR Samples + Deduplicate Seed/Live Overlap

### Root Cause

The `HKAnchoredObjectQuery` uses `predicate: HKQuery.predicateForSamples(withStart: Date(), end: nil)` with `anchor: nil`. The initial callback returns ALL matching samples in HealthKit's store — including samples with corrupted future dates (June-July 2026). These are likely HealthKit beta artifacts or data written by a source with incorrect dates. They are correctly rejected by the heuristic engine but generate per-sample log warnings.

Additionally, `startMonitoring()` starts the live anchored query at time T1 (`Date()` at line 264) and then seeds history up to time T2 (`Date()` at line 269, slightly after T1). Both feed into `WakeHeuristicEngine` which blindly appends. With denser overnight workout data, boundary samples near 07:05 are likely to appear in both the anchored query's initial callback and the historical seed, producing duplicates that skew HRV calculations and confidence scores.

### Changes

#### SmartWakeSessionController.swift

18. **Modify `startHeartRateQuery(from:)` (~line 622)** — Change signature to `startHeartRateQuery(from:until:)`. Set the predicate's `end` date to `wakeUpTime + 5 minutes`:
    ```swift
    let predicate = HKQuery.predicateForSamples(
        withStart: startDate,
        end: endDate?.addingTimeInterval(300)
    )
    ```
    The `updateHandler` still delivers new samples in real-time as long as their `startDate` falls within the predicate window. Samples with dates months in the future are excluded at the HealthKit level.

    **Edge case — monitoring starts after `wakeUpTime`:** If `startDate > endDate` (e.g., delayed extended runtime session fires after the wake time has passed), clamp: use `end: max(startDate.addingTimeInterval(300), endDate.addingTimeInterval(300))` so the query window is always valid.

19. **Update call sites** to pass wake time:
    - In `startMonitoring()` (~line 264): pass `until: wakeUpTime`
    - In `startDegradedMonitoring()` (~line 530): pass `until: wakeUpTime` (access via stored `self.wakeUpTime`)

20. **Add batch pre-filter in `processHeartRateSamples()` (~line 643)** — Before the per-sample loop, filter out samples > 120s in the future and log a single consolidated warning:
    ```
    "Filtered N future-dated sample(s) from anchored query batch of M"
    ```
    This reduces log noise from N lines to 1. The heuristic engine's per-sample filter remains as defense-in-depth.

21. **Add UUID-based deduplication in `processHeartRateSamples()` (~line 643)** — After the future-date filter, check each sample's `HKSample.uuid` against `seenSampleUUIDs`. Skip samples whose UUID is already in the set; insert new UUIDs. This is done at the controller level because both data paths (live query and historical seed) converge here and the controller has access to raw `HKQuantitySample` objects with their UUIDs.

21a. **Guard against empty-after-filtering batches** — After both the future-date filter (Step 20) and UUID dedup (Step 21), check if the remaining sample array is empty. If so, return early WITHOUT calling `checkForWakeTrigger()` and without updating `lastHRSampleDate`. This prevents stale heuristic re-evaluation when a batch arrives that contains only future-dated or duplicate samples.

22. **Add UUID-based deduplication in `seedHistoricalHeartRateSamples()` (~line 576)** — Before mapping `[HKQuantitySample]` to `(date, bpm)` tuples (line 581), filter out samples whose `.uuid` is already in `seenSampleUUIDs`, then insert the new UUIDs. This handles the case where the anchored query's initial callback delivered boundary samples before the seed completes. After dedup, if the remaining sample array is empty, skip the `heuristicEngine.seedHeartRateSamples()` call and the subsequent `checkForWakeTrigger()` (line 593) — a fully-deduped seed contains no new data, so evaluating would produce the same stale result.

23. **Clear `seenSampleUUIDs` in monitoring teardown paths** (`tearDownMonitoringSession()`, `stopProactiveWorkout()`) so it doesn't grow unbounded across sessions.

Note: The heuristic engine (`WakeHeuristicEngine.swift`) does NOT change for dedup. It continues to receive pre-deduplicated `(date, bpm)` tuples. Sample identity is a HealthKit concern, not a heuristic concern.

---

## Issue 3: Eliminate Redundant Wake Checks

### Root Cause

Without an active `HKWorkoutSession`, the watch only measures HR passively every ~5 minutes. The 10-second wake-check timer evaluates the same stale data ~30 times between samples. This is wasteful and clutters logs. Even in the success path (workout active, samples every few seconds), the 10-second timer creates redundant evaluations because `processHeartRateSamples()` already calls `checkForWakeTrigger()` on every sample arrival (line 660).

Fixing Issue 1 is the primary solution — with an active workout session, HR data arrives every few seconds.

### Solution

The periodic heuristic timer is unnecessary in both modes. `processHeartRateSamples()` already calls `checkForWakeTrigger()` on every sample arrival, and `seedHistoricalHeartRateSamples()` also calls it after seeding (line 593). The heuristic result cannot change without new data, so timer-driven re-evaluation between samples produces identical results every time.

Replace the current 10-second periodic timer with:
- **Sample-driven `checkForWakeTrigger()` calls** — already exist in both `processHeartRateSamples()` (line 660) and `seedHistoricalHeartRateSamples()` (line 593). These are the only meaningful evaluation points.
- **A one-shot exact-wake timer** that fires precisely at `wakeUpTime` for guaranteed force-fire. This is the safety net that ensures the alarm fires even if no new HR data arrives.
- **A one-shot seed-timeout timer** that fires 30 seconds after monitoring starts, to preserve the heuristic engine's seed-timeout escape hatch (see Step 26a).

This eliminates the `wakeCheckTimer`, the `hasNewDataSinceLastCheck` flag, the `wakeCheckInterval` computed property, and `restartWakeCheckTimerIfNeeded()`. The design is strictly simpler and produces identical behavior: evaluations happen exactly when new data arrives (which is the only time the result can change), plus a guaranteed force-fire at wake time, plus a targeted seed-timeout check.

In degraded mode with passive HR (~5 min intervals), evaluations happen on each passive sample arrival — slower but correct, since there is no new data to evaluate between arrivals. The one-shot timers guarantee the force-fire backstop and seed-timeout regardless.

### Changes

#### SmartWakeSessionController.swift

24. **Add properties**:
    - `private var exactWakeTimer: Timer?` for the one-shot wake-time backstop
    - `private var seedTimeoutTimer: Timer?` for the one-shot seed-timeout check

25. **Remove `startWakeCheckTimer()` (~line 666)** — Delete the periodic 10-second timer entirely. Remove the `wakeCheckTimer` property.

26. **Add `scheduleExactWakeTimer()`** — Schedules a one-shot `Timer` that fires at exactly `wakeUpTime`. The timer callback calls `checkForWakeTrigger()`, which already handles the `now >= wakeUpTime` force-fire path (line 724). This guarantees the force-fire happens within milliseconds of wake time. If `wakeUpTime` is already in the past when called (e.g., `startDegradedMonitoring()` after wake time), the timer fires immediately.

26a. **Add `scheduleSeedTimeoutTimer()`** — Schedules a one-shot `Timer` that fires 30 seconds after monitoring starts. The timer callback calls `checkForWakeTrigger()`, which calls `shouldTrigger()` (line 240-242), which calls `freezeBaselineIfNeeded()` (line 123-138). This preserves the existing seed-timeout escape hatch: if the historical seed stalls AND no live samples arrive (the degraded-mode scenario), `freezeBaselineIfNeeded()` detects that `awaitingSeedSince` is >30s ago and proceeds with baseline freeze.

**Why this is necessary:** Without the periodic 10-second timer, `freezeBaselineIfNeeded()` is only called from `refreshMetrics()` → called from `addHeartRateSample()` and `seedHeartRateSamples()`. If the seed stalls and no live samples arrive, nothing ever calls `freezeBaselineIfNeeded()`, and the baseline stays locked in "awaiting seed" for the entire wake window. The heuristic engine would be completely dead until the one-shot exact-wake timer fires the force-fire path (which bypasses `shouldTrigger()` entirely at line 724). The seed-timeout timer ensures the 30-second escape hatch still works.

27. **Update `processHeartRateSamples()` (~line 643)** — After processing valid samples (post-filtering per Issue 2), update `lastHRSampleDate` to the latest sample's date. The existing `checkForWakeTrigger()` call at line 660 remains unchanged — it is now the primary heuristic evaluation path.

28. **Update `seedHistoricalHeartRateSamples()` (~line 576)** — After successful seeding, update `lastHRSampleDate` to the latest seeded sample's date. The existing `checkForWakeTrigger()` call at line 593 remains unchanged. **Also cancel `seedTimeoutTimer`** — the seed completed successfully, so the timeout is no longer needed.

29. **Wire timers at monitoring start** — In `startMonitoring()` (~line 265) and `startDegradedMonitoring()` (~line 530), replace the `startWakeCheckTimer()` call with:
    - `scheduleExactWakeTimer()`
    - `scheduleSeedTimeoutTimer()`

30. **Keep the existing startup `checkForWakeTrigger()` calls** at `startMonitoring()` (line 266) and `startDegradedMonitoring()` (line 540). These are intentional one-shot evaluations at monitoring startup, not periodic timer ticks. They serve two purposes:
    - **Immediate force-fire**: If monitoring starts at or after `wakeUpTime` (e.g., delayed extended runtime session), the `now >= wakeUpTime` check (line 724) triggers force-fire without waiting for the first sample or the one-shot timer.
    - **Wake-window-start logging**: The `didLogWakeWindowStart` check (line 716) logs when the wake window begins, producing a clear timeline entry at monitoring start.

    These calls produce at most one evaluation log entry each at startup. They are distinct from the eliminated periodic timer, which produced identical evaluations every 10 seconds between samples.

31. **`checkForWakeTrigger()` (~line 708) — no structural changes needed.** The existing logic already handles all callers:
    - Force-fire at wake time (line 724: `if now >= wakeUpTime`) — triggered by one-shot timer, startup call, or session-loss emergency check
    - Heuristic evaluation (line 745: `shouldTrigger(...)`) — triggered by sample-driven calls, startup call, or seed-timeout timer
    No data-freshness guard is needed because callers are: (a) sample arrival (new data), (b) seed completion (new data), (c) one-shot exact-wake timer (force-fire only), (d) one-shot startup evaluation, (e) one-shot seed-timeout timer (baseline freeze check), (f) `forceImmediateWakeCheck()` (line 678) — called by the scheduler from `extendedRuntimeSessionWillExpire` (line 1148) and `extendedRuntimeSession(didInvalidateWith:)` (line 1153) as a last-chance emergency check before background execution is lost. These are not periodic — they fire at most once each per session lifecycle.

32. **Invalidate both `exactWakeTimer` and `seedTimeoutTimer` in teardown paths** — `tearDownMonitoringSession()`, `stopMonitoring()`, `tearDownMonitoringWithoutCompletion()` must invalidate both timers. Remove all `wakeCheckTimer` invalidation calls (the timer no longer exists).

33. **Remove degraded-mode timer restart logic** — The `didChangeTo` delegate (~line 1278) and `didFailWithError` delegate (~line 1310) no longer need to restart any timer when switching to degraded mode. The one-shot exact-wake timer is already scheduled for the correct time, the seed-timeout timer handles its own concern, and sample-driven evaluation continues to work regardless of mode.

---

## Issue 4: Residual Issues

### 4a: Re-arming from background after wake completion

**Problem**: `cleanUpAfterCompletedWake()` (line 556) calls `schedulesDidUpdate()` which evaluates and tries to arm the next day's wake. At 7:31:03, it successfully calls `WKExtendedRuntimeSession.start(at:)` for tomorrow's 7:05am, but at 7:31:04 watchOS invalidates it: "The app must be active and before applicationWillResignActive to start or schedule a WKExtendedRuntimeSession."

**Root cause**: `WKApplication.shared().applicationState` returns `.active` during extended runtime execution, so the existing `applicationState` guard at line 456 passes. But watchOS has a stricter internal precondition for scheduling new extended runtime sessions — it requires true foreground, not just extended-runtime-active. Adding the same `applicationState` check inside `scheduleAlarmSession()` would also pass and change nothing.

**Fix**: The `isSceneActive` flag (Cross-Cutting section) solves this. During extended runtime callback execution, `isSceneActive` is `false` (no scene phase change occurred). `schedulesDidUpdate()` still runs — it evaluates the next occurrence and reaches the `isSceneActive` guard (Step S4, replacing the `applicationState` check at line 456). Since `isSceneActive` is false, it takes the inactive-app path: persists the `PendingWake` via `equivalentPersistedPendingWake` / `restorePendingWakeState`, or falls through to `armingState = .needsForegroundToArm`. No `WKExtendedRuntimeSession` is created. No `start(at:)` is called. No zombie session. No error log.

**Why this still persists tomorrow's wake**: The inactive-app path at line 458-476 checks for an `equivalentPersistedPendingWake`. Since `cleanUpAfterCompletedWake()` called `clearSchedulerState(clearPersistedWake: true)` (line 568) before `schedulesDidUpdate()`, there's no equivalent persisted wake to restore. It falls through to line 478-489: `armingState = .needsForegroundToArm`. Tomorrow's wake is NOT persisted in this path — it's the `scheduleAlarmSession()` path that does persistence.

**This means we need an additional change**: In the `needsForegroundToArm` branch (line 478-489), after setting `armingState`, also persist the `PendingWake` so recovery works. Add:
```swift
savePendingWakeRecord(for: nextWake)
pendingSchedule = nextWake
```
This ensures tomorrow's wake is persisted even when the session can't be scheduled yet. The next foreground pass picks up the persisted record, finds an equivalent persisted wake, and calls `scheduleAlarmSession()` from a valid context.

#### SmartAlarmScheduler.swift

34. **No changes to `scheduleAlarmSession()` itself.** The `isSceneActive` replacement of the `applicationState` guard (Step S4) prevents `scheduleAlarmSession()` from being reached during background execution. No zombie `WKExtendedRuntimeSession` is created.

34a. **Modify the `needsForegroundToArm` branch (~line 478-489)** — After setting `armingState = .needsForegroundToArm`, also persist the pending wake:
```swift
pendingSchedule = nextWake
currentSessionScheduleID = nextSchedule.id
currentSessionWakeTime = wakeUpTime
savePendingWakeRecord(for: nextWake)
```
This ensures recovery works even if the process is killed before the next foreground visit. Without this, the inactive-app path would set `armingState` but leave no persisted record, and process relaunch would have nothing to restore.

### 4b: Watch HomeKit "Missing entitlement for API"

**Problem**: Watch-local fallback failed with "Missing entitlement for API" on both lights. The watch entitlements file (`Lights_Timer_Watch.entitlements`) correctly includes `com.apple.developer.homekit = true`.

**Investigation needed — not a code fix.** This is likely a provisioning profile or build-signing configuration issue (the entitlement is declared but the profile may not include the HomeKit capability), or a watchOS restriction on HomeKit writes during background/extended-runtime execution. This needs separate investigation of:
- The provisioning profile in the Apple Developer portal (does it include HomeKit for the watch app ID?)
- Whether HomeKit characteristic writes are restricted during `WKExtendedRuntimeSession` execution
- Whether the watch has been set up as a home hub or has the correct home/accessory pairing

This is tracked separately from the session issues above.

---

## Verification

1. **Prerequisite spike (HARD GATE)**: Run the no-builder workout session test on a physical watch (see Prerequisite section). Do not proceed with Issue 1 implementation until the spike result is known. If it fails, choose Option A (discardWorkout) or Option B (accept artifact) and validate that path before proceeding.
2. **Build check**: `xcodebuild -target 'Lights Timer Watch App' -sdk watchsimulator26.2 build CODE_SIGNING_ALLOWED=NO`
3. **Proactive workout timing**: Arm an alarm >10h before monitoring start → verify proactive workout does NOT start (log shows "Deferring proactive workout start"). Return to foreground within 10h of monitoring → verify proactive workout starts on that visit.
4. **Proactive workout lifecycle**: Arm within 10h of monitoring → verify "Workout Session (overnight)" shows in diagnostics and no `.other` workout appears in Health app → use new disarm button → verify workout stops and no workout is saved
5. **Monitoring reuse path**: (Requires physical watch) Arm alarm, let extended runtime fire → verify log shows "Reusing proactive workout session" and HR samples arrive significantly more frequently than passive ~5min intervals
6. **Sample-driven evaluation**: Verify that heuristic evaluations appear in the log only: (a) once at monitoring startup (the intentional one-shot startup evaluation per Step 30), (b) immediately after "Live heart-rate sample" or "Historical seed" log entries, (c) once ~30s after monitoring start (seed-timeout timer, Step 26a), (d) at exact wake time via the one-shot timer, or (e) on session-loss emergency checks from `forceImmediateWakeCheck()` (at most once per expiry/invalidation event). There should be NO periodic 10-second evaluation spam between samples.
7. **Seed timeout**: In degraded mode with no seed arriving, verify baseline freezes ~30s after monitoring start (seed-timeout timer fires and `freezeBaselineIfNeeded()` detects the timeout). Before this fix, the periodic 10-second timer served this role.
8. **Query bounding**: Verify no future-dated samples appear in the log (filtered at HealthKit level)
9. **UUID deduplication**: With proactive workout providing dense overnight data, verify no duplicate samples at the seed/live query boundary (~07:05). Check that `seenSampleUUIDs` is cleared on teardown.
10. **Empty-batch guard**: Inject a batch of only future-dated samples → verify no `checkForWakeTrigger()` call and no `lastHRSampleDate` update.
11. **Cleanup paths**: Disarm from watch UI → verify workout stops. Let extended runtime session invalidate → verify workout stops. Verify no orphaned workout sessions after any scheduler teardown path.
12. **Disarm durability (watch)**: Disarm → force-kill watch app → relaunch → verify the same occurrence is NOT re-armed (completed wake occurrence persisted in UserDefaults).
13. **Disarm durability (phone)**: Disarm with phone reachable → bring phone to foreground → verify `syncBackgroundScenes()` does NOT recreate the `LT_<shortID>_fallback` scene for the disarmed occurrence (`ScheduleEngine.isOccurrenceDisarmed()` blocks it).
14. **Stale disarm rejection**: Arm March 20 wake → deliver a stale March 19 disarm via `transferUserInfo` → verify the phone sends `disarmWakeAck` with `success: false, scenePending: false, reason: "stale occurrence"` → verify the March 20 fallback scene is NOT deleted → verify the watch clears the unacked disarm record for March 19 on receipt (the record is removed because `scenePending == false` — no scene is at risk).
15. **Disarm ack success flow**: Disarm with phone reachable → verify `phoneDisarmPending` clears when ack with `success: true` arrives → watch UI shows clean "Disarmed" without "(phone fallback pending)".
16. **Disarm ack operational failure**: Disarm with phone reachable but HomeKit homes empty → verify phone sends ack with `success: false, scenePending: true` → verify watch keeps the unacked disarm record → `phoneDisarmPending` remains `true` → watch UI shows "(phone fallback pending)" → verify reason is logged on watch.
17. **Disarm without phone**: Disarm with phone unreachable → verify watch UI shows "Disarmed (phone fallback pending)" → verify `phoneDisarmPending` remains true → when phone becomes reachable and processes the queued `transferUserInfo`, verify ack with `success: true` clears the pending state.
18. **Disarm pending survives relaunch**: Disarm with phone unreachable → force-kill watch app → relaunch → verify `phoneDisarmPending` is still `true` (derived from persisted unacked disarm record in UserDefaults, Step 14e) → watch UI shows "(phone fallback pending)". Then simulate the phone ack arriving → verify the record is cleared and `phoneDisarmPending` becomes `false`.
19. **Disarm pending auto-prune**: Disarm with phone unreachable → wait for `pruneCompletedWake()` (wake time + 2h) → verify unacked disarm record is also pruned → `phoneDisarmPending` becomes `false` (warning is moot — wake time has long passed).
20. **Post-wake re-arm via isSceneActive**: After wake completion at ~07:31, verify `schedulesDidUpdate()` runs but hits the `isSceneActive == false` path → logs `needsForegroundToArm` → persists tomorrow's wake (Step 34a). No `WKExtendedRuntimeSession` created. No error log. Next foreground visit arms cleanly.
21. **isSceneActive correctness**: Verify `isSceneActive` is `true` during foreground app usage (including cold launch), `false` after app goes to background, `false` during extended runtime callbacks, and `false` during WCSession background delivery.
22. **isSceneActive cold launch (active path)**: Cold-launch the watch app where `.task` runs after `scenePhase` is already `.active` → verify `onAppForeground()` is called → alarm arms correctly on first launch.
23. **isSceneActive cold launch (inactive path)**: Cold-launch the watch app where `.task` runs while `scenePhase` is still `.inactive` → verify `.task` defers evaluation (log shows "Deferring schedule evaluation") → verify `.onChange` fires `.active` shortly after → `onAppForeground()` runs → alarm arms correctly. No transient `needsForegroundToArm` flash in the UI.
24. **Disarm with HomeKit not ready**: Disarm with phone reachable but HomeKit homes empty → verify phone sends ack with `success: false, reason: "HomeKit not ready"` → verify `phoneDisarmPending` stays true on watch → verify disarmed occurrence IS persisted on phone (scene won't be recreated) → bring phone to foreground so `syncBackgroundScenes()` runs → verify `cleanupOldScenesAndTriggers()` removes the stale fallback scene and `createScenesForSchedule()` skips recreation for the disarmed occurrence.
25. **Pending warning survives re-arm**: Disarm today's 7:30 AM wake with phone unreachable → verify scheduler advances to tomorrow's wake and `armingState` becomes `.armed` → verify "(phone fallback pending for 7:30 AM)" banner is still visible alongside the armed state for tomorrow's wake. The two states are independent — one is about tomorrow's alarm, the other is about today's unconfirmed disarm.
26. **Overlapping disarms**: Disarm occurrence A (today 7:30 AM) with phone unreachable → scheduler advances and arms occurrence B (tomorrow 7:30 AM) → disarm occurrence B → verify both unacked disarm records exist in the persisted set → delayed ack for A arrives with `success: true` → verify only A's record is removed, B's record remains → `phoneDisarmPending` is still true → watch UI still shows pending banner for B's wake time.
27. **Overlapping disarms phone-side**: Disarm occurrence A → verify phone persists A as disarmed → disarm occurrence B → verify phone also persists B → phone `nextOccurrence(for:)` is irrelevant (no occurrence-match check). Both disarmed occurrences block scene creation independently.
28. **Disarm during in-flight sync**: Trigger `syncBackgroundScenes()` → while sync is in flight (`isSyncing == true`), send a disarm → verify disarmed occurrence is persisted immediately → verify no ack is sent yet → verify `deferredDisarmAcks` contains the entry → when sync completes, verify deferred cleanup removes any scene created by the in-flight sync for the disarmed occurrence → verify ack is sent after cleanup → verify watch clears the pending state only after this deferred ack.
29. **Exact-wake backstop**: In degraded mode, verify force-fire happens within 1 second of wake time via the one-shot timer.
30. **Full overnight test**: Arm before sleep → verify proactive workout starts → verify frequent HR data during wake window → verify heuristic triggers before exact wake time
31. **Background schedule delivery**: Receive a WCSession schedule update while in background with an equivalent armed wake → verify proactive workout is NOT started (`isSceneActive` is false).

## Critical Files
- `Lights Timer Watch App/Services/SmartWakeSessionController.swift` — Core changes (Steps 1-10, 18-22, 24-33)
- `Lights Timer Watch App/Services/SmartAlarmScheduler.swift` — Foreground detection (Steps S1-S5), wiring (Steps 11-14, 34, 34a)
- `Lights Timer Watch App/LightsTimerWatchApp.swift` — Scene phase tracking (Step S6)
- `Lights Timer Watch App/Services/SmartWakePendingWakeStore.swift` — Persistence (Steps 14a, 14e)
- `Lights Timer Watch App/Models/SmartWakeMessage.swift` — Disarm message type (Step 14b)
- `Lights Timer/Models/SmartWakeMessage.swift` — Disarm message type (Step 14b, iPhone copy)
- `Lights Timer/Services/WatchConnectivityService.swift` — Disarm handler (Step 14b)
- `Lights Timer/Services/SmartWakeCoordinator.swift` — Disarm validation + persistence (Steps 14b, 14c)
- `Lights Timer/Services/ScheduleEngine.swift` — Disarm-aware scene creation (Step 14c)
- `Lights Timer Watch App/Views/WatchRootView.swift` — UI (Steps 15-17)
- `CLAUDE.md` — Documentation update
