# Plan 1: Fix Smart Wake Overnight Session Issues

## Context

The Smart Wake feature failed during an overnight session on 2026-03-19. Three issues were identified from the runtime log:

1. **HKWorkoutSession died immediately** — "Client application cannot start a workout session while in the background" when the extended runtime session fired at 7:05am
2. **Future-dated HR samples** — 15 samples with dates in June-July 2026 arrived in the initial anchored query callback, creating log noise (correctly rejected by the heuristic engine)
3. **Infrequent HR sampling** — Without an active workout session, passive HR monitoring only delivered samples every ~5 minutes. The wake-check timer ran every 10 seconds against the same stale data, and the heuristic never reached the 0.6 confidence threshold, forcing a fallback fire at exactly 7:30am

These issues are interconnected: Issue 1 directly causes Issue 3. The fix for Issue 1 is the primary change.

Two additional residual issues were identified in the runtime log and are addressed in Issue 4.

**Scope:** This plan covers only the session/query/timer bug fixes. The watch-side disarm feature (with phone ack protocol) is deferred to a separate plan (PLAN-disarm.md) to keep this changeset targeted and reduce risk.

**Reliability framing:** Issue 1's proactive-workout approach is a **happy-path improvement**, not a reliability fix. It improves the outcome when the process survives overnight and the proactive workout stays alive — but there is no watchOS API to recover an `HKWorkoutSession` after process eviction, and overnight proactive-session death has no recovery path from background. In those cases, the result is identical to today's behavior: degraded mode with passive HR sampling. The plan explicitly does not claim to fix the reliability story — that would require a fundamentally different approach (e.g., a companion phone-side HR proxy, or Apple adding workout session recovery). Degraded mode, the force-fire backstop, and the phone-side fallback scene remain the safety nets. See "Known limitation" notes under Issue 1 for details.

**Implementation status:** This plan is **not** a single go-ahead changeset. It contains:
- **Resolved gate**: The Prerequisite spike was completed on 2026-03-20. The no-builder path is technically viable and is the selected Issue 1 implementation path. See the Prerequisite section for the exact outcome and accepted tradeoff.
- **Implemented on the current branch (2026-03-20)**: Cross-Cutting foreground detection, Issue 1's proactive-workout path, Issue 2's query/filter/dedup cleanup, and Issue 3's one-shot timer cleanup are now in code and the watch target builds successfully.
- **Blocked reliability work**: Issue 4b does not block all code changes, but it blocks treating the watch-local HomeKit fallback as production-reliable until the background-write investigation is complete.
- **Remaining safe-to-implement work once the above is acknowledged**: Issue 4a re-arm persistence fixes.

---

## Prerequisite: Validate No-Builder Workout Session (COMPLETED 2026-03-20)

**Result:** The spike is complete. Issue 1 can proceed on the no-builder path.

The core of this plan assumes `HKWorkoutSession` without `HKLiveWorkoutBuilder` provides three things: overnight background execution (via `workout-processing` mode), workout-frequency HR sampling, and HR samples that are queryable by the historical seed path at monitoring start. The current codebase only exercises the builder-backed path (`SmartWakeSessionController.swift` line 485). This assumption is unproven.

**Validation spike** (physical watch required):
1. Create an `HKWorkoutSession` with `.other` activity type, set its delegate, call `startActivity(with: Date())`. Do NOT create a builder or call `beginCollection()`.
2. Start an `HKAnchoredObjectQuery` for heart rate.
3. Send the app to background. Observe:
   - **Pass criterion A**: App stays alive in background (workout-processing mode engaged)
   - **Pass criterion B**: HR samples arrive via the anchored query at noticeably higher frequency than passive (~5min) — expect every few seconds
   - **Pass criterion C**: After calling `session.end()`, no workout entry appears in the Health app and no Activity Rings credit is added
   - **Pass criterion D**: While the no-builder session is active, the watch does NOT show workout-in-progress indicators (green workout ring on watch face, workout complication dot, or "Workout in progress" in the app switcher). This criterion did **not** pass in the spike: the watch showed an app-owned in-progress indicator using the app icon. Product decision on 2026-03-20: this indicator is acceptable and is not a blocker for Issue 1.
   - **Pass criterion E**: While the no-builder session is still running, an `HKSampleQuery` for the last 2 hours can read the fresh HR samples that would be consumed by `seedHistoricalHeartRateSamples()` at 07:05. If the overnight data is only visible to the anchored query and not to the seed query, the proactive session does not actually solve the baseline problem.

**Observed result on 2026-03-20:**
- Criterion A: Passed. The app remained alive in background and the sample count kept increasing.
- Criterion B: Passed. Fresh HR samples arrived every few seconds instead of passive ~5 minute cadence.
- Criterion C: Passed. No workout entry appeared in Health/Activity and no rings credit was added.
- Criterion D: Failed as originally written, but explicitly accepted as a product tradeoff because the indicator is app-owned and otherwise non-problematic.
- Criterion E: Passed. A 2-hour seed query while the no-builder session was still active returned fresh samples from the active session.

**Conclusion:** Proceed with Issue 1 as designed (no-builder proactive session), with the explicit understanding that the watch may show an app-owned in-progress indicator while the proactive session is active.

**If the spike fails** (no frequent HR without a builder, OR Activity Rings pollution without a builder): Two options, requiring a product decision before proceeding:

**Option A — discardWorkout() path (preferred if rings pollution is unacceptable):**
Use the builder but call `builder.discardWorkout()` instead of `builder.finishWorkout()` for proactive sessions. This substitution must be made in **every** workout teardown path that can run while a proactive-origin session is active:
- `stopProactiveWorkout()` (new method, pre-monitoring teardown) — must call `builder.endCollection(at:)` then `builder.discardWorkout()` then nil out builder
- `endWorkoutSession()` (~line 508) — currently calls `finishWorkout()` unconditionally; must branch: if the session originated as a proactive session (`isProactiveOrigin`), call `discardWorkout()` instead
- `finishMonitoringAfterTrigger()` (~line 282) — defers to `endWorkoutSession()`, so inherits the fix automatically
- The `didChangeTo(.ended)` delegate (~line 1270) — if the session ends externally during proactive mode, the builder may still be live; teardown must discard, not finish
- The `didFailWithError` delegate (~line 1285) — same as above

A `isProactiveOrigin` flag (set at proactive start) gates the branch.

**Reuse semantics for the builder path:** When Step 7b reuses a proactive workout for monitoring, the session keeps its `isProactiveOrigin = true` because the same `HKWorkoutSession` + builder continue running. The transition sets `isProactiveWorkoutRunning = false` (session now "owned" by monitoring) but does NOT clear `isProactiveOrigin`. This means `endWorkoutSession()` (called from `finishMonitoringAfterTrigger()` or monitoring teardown) still calls `discardWorkout()` instead of `finishWorkout()`, preventing the overnight workout from being saved. This is correct: the builder has been collecting data since the proactive start, and saving it would create the same multi-hour `.other` workout we're trying to avoid. If the monitoring phase needs a fresh workout (proactive died → Step 7b fallback → `startWorkoutSession()`), that creates a new session with `isProactiveOrigin = false` and a new builder, so `finishWorkout()` runs normally for the short monitoring-only workout.

**Caveat**: Apple docs say `discardWorkout()` "discards the workout and any associated data that the builder collected." Whether HR samples also exist independently in HealthKit's general store (i.e., survive the discard) needs validation. If discarding kills the HR data that the heuristic engine already consumed from the anchored query, this is a non-issue — the heuristic already has the data in memory. But it could affect the historical seed for subsequent sessions.

**Option B — accept the workout artifact:**
Keep using `finishWorkout()` and accept that an overnight `.other` workout appears in Health app. This is the simplest path but pollutes workout history. Some sleep-tracking apps (AutoSleep, Sleep Cycle) do this already.

**The spike result determined the selected code path:** proceed with the no-builder proactive session. Option A and Option B are retained here only as documented fallback paths if a later regression invalidates the chosen approach.

---

## Product Decision: Proactive Workout Tradeoffs

The proactive-workout approach introduces tradeoffs that are product decisions, not purely technical ones. These must be acknowledged before implementation:

| Tradeoff | Impact | Mitigation in plan |
|----------|--------|-------------------|
| **Overnight battery drain** | Up to 10 hours of active HR sensing via `workout-processing` mode. Similar to sleep-tracking apps (AutoSleep, Sleep Cycle), but users may not expect this from a light timer. | `maxProactiveLeadTime` caps at 10h. `.other` activity type with no GPS minimizes drain. |
| **User-visible workout state** | The no-builder proactive session still shows an app-owned in-progress indicator while active. It is not the Workout app UI, but it is visible overnight state. | Accepted product tradeoff on 2026-03-20. The plan no longer assumes "no builder" means "no visible indicator." |
| **Workout-history pollution** | If the no-builder spike fails, Option B saves an overnight `.other` workout to Health app. Option A (`discardWorkout`) avoids this but may discard HR data. | Spike determines which path. Option A is preferred if rings pollution is unacceptable. |
| **Conflicts with genuine workouts** | If the user starts a real workout (e.g., late-night gym session) while the proactive session is running, the behavior is undefined. watchOS may terminate the proactive session. | The proactive session dies → Steps 9-10 log it → monitoring falls through to the try-from-background path at 7:05am (likely degraded). This is acceptable degradation but the user gets no warning. |
| **No reliability improvement** | Process eviction or proactive-session death overnight → identical to today's behavior (degraded mode). The plan improves the happy path only. | Degraded mode, force-fire backstop, and phone-side fallback scene remain safety nets. See "Reliability framing" in Context section. |
| **Denied-user battery waste** | A user who denied HealthKit access still pays up to 10h of battery for a proactive workout that can never deliver HR data. The proactive workout is gated on `isHealthKitAuthorized` (prompt completed), not `hasConfirmedHRAccess` (data confirmed). | Cannot gate on `hasConfirmedHRAccess` without also blocking authorized-but-no-history users (new watch) from generating their first overnight HR data. Both cases have `isHealthKitAuthorized = true, hasConfirmedHRAccess = false`. Distinguishing denied-vs-data-sparse requires expanding `SmartWakePermissionStatus` — deferred as follow-up. Today's code has the same issue at a smaller scale (monitoring-time workout start, not overnight). |

**Decision required before implementation:** The team must accept that Smart Wake will consume overnight battery for a best-effort HR improvement. If overnight battery drain is unacceptable, the proactive-workout approach should not be implemented, and the plan reduces to Issues 2-4 only (filtering, timer cleanup, residual fixes). Degraded mode would remain the permanent smart-wake HR path.

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

S5. **Use `isSceneActive` everywhere the plan needs a foreground check** — Steps 11a, 11b, and the later foreground-gated scheduler paths all use `isSceneActive` instead of `applicationState`.

#### LightsTimerWatchApp.swift

S6. **Modify `onChange(of: scenePhase)`** — Add an `else` branch that calls `services.alarmScheduler.onAppBackground()` when `newPhase != .active`. This ensures `isSceneActive` is cleared when the app goes to `.inactive` or `.background`.

S7. **Fix cold-launch hole in `.task`** — The existing `.task` (line 42) calls `schedulesDidUpdate()` before `onChange(of: scenePhase)` ever fires. On a cold foreground launch with schedules already hydrated, `isSceneActive` is still `false`, so the scheduler would incorrectly take the `needsForegroundToArm` path even though the user is visibly in the app.

**Timing subtlety:** SwiftUI's `.task` runs when the view first appears, which can happen while `scenePhase` is still `.inactive` (mid-launch transition). On a cold foreground launch, the typical sequence is: `.task` fires → `scenePhase` transitions to `.active` → `.onChange` fires. If `.task` evaluates schedules with `isSceneActive = false` while the phase is `.inactive`, it would transiently set `armingState = .needsForegroundToArm` and persist a pending wake (Step 32b) — then `.onChange` fires `.active` shortly after and re-evaluates correctly. The end state is correct, but the transient evaluation is wasteful (unnecessary UserDefaults write from Step 32b) and may flash "Needs foreground to arm" in the UI.

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
    // needsForegroundToArm and persist stale state via Step 32b.
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

**Key design decision — no builder for the proactive session.** The prerequisite spike completed on 2026-03-20 and validated the no-builder path as the chosen implementation. The current `startWorkoutSession()` creates an `HKLiveWorkoutBuilder` and calls `builder.beginCollection()` / `builder.finishWorkout()`. This saves an `.other` workout to HealthKit. An 8-hour overnight workout would pollute workout history and skew activity metrics. The fix: the proactive session uses `HKWorkoutSession` alone — no builder, no `beginCollection()`, no `finishWorkout()`. The session still keeps the app alive and triggers frequent HR hardware sampling. HR samples go into HealthKit's general store regardless of whether a builder is collecting them. The existing `startWorkoutSession()` (with builder) remains available for the monitoring-phase fallback path. The accepted tradeoff is that the watch may still show an app-owned in-progress indicator while the proactive session is running.

**Battery tradeoff**: The proactive workout runs for up to `maxProactiveLeadTime` (10 hours) of active HR sensing — similar to sleep tracking apps (AutoSleep, Sleep Cycle). The `.other` activity type with no GPS minimizes impact. The 10-hour cap prevents the pathological case where early arming would run the workout all day.

### Prerequisite: Fix `isHealthKitAuthorized` Flag (Required Before Step 4)

**Problem:** `requestAuthorization()` (~line 186) computes:
```swift
isHealthKitAuthorized = status == .sharingAuthorized || status != .notDetermined
```
`HKAuthorizationStatus` has three cases: `.notDetermined` (0), `.sharingDenied` (1), `.sharingAuthorized` (2). The expression evaluates `.sharingDenied` as `false || true` → `true`, so a denied user reads as authorized.

Additionally, `authorizationStatus(for:)` on a **read** type (heart rate) is fundamentally unreliable — Apple's HealthKit privacy model intentionally returns `.sharingDenied` for read types regardless of whether the user granted or denied access, to prevent apps from inferring health data preferences.

**Blast radius of the current bug:**
- `WatchRootView` (~line 54): "Grant Health Access" button is hidden even when denied — user has no way to re-authorize
- `LightsTimerWatchApp` (~line 26): phone-side `HealthKitAuthorizationService` receives a false positive
- Step 4's `isHealthKitAuthorized` guard: would pass after denial, starting a pointless proactive workout that can't deliver HR data

**Fix — two-layer approach:** Use both a corrected `authorizationStatus` check AND a data probe, with distinct roles:

1. **`isHealthKitAuthorized`** (the existing flag) — set to `true` when the authorization prompt has been completed and status is not `.notDetermined`. This is the UI/gating flag. It answers: "has the user been through the prompt?" Since HealthKit returns `.sharingDenied` for read types regardless of actual grant/deny, this flag becomes `true` after the first prompt and stays `true` unless the request itself throws. This is intentional — after the prompt, we should attempt to use HealthKit and let the query results tell us whether data is actually accessible. The "Grant Health Access" button (`WatchRootView` line 54) should only show when the prompt hasn't been presented yet (`.notDetermined`), not when the user denied — re-tapping the button after denial does nothing (HealthKit only shows the prompt once; subsequent calls to `requestAuthorization` are no-ops). For denied users, the button text and behavior would need to direct them to Settings, which is a separate UI concern outside this plan's scope.

2. **`hasConfirmedHRAccess`** (new flag) — set to `true` only when a data probe returns actual heart rate samples. This is the operational flag. It answers: "can we actually read HR data right now?" Used for the phone-side permission status (Step 0f) and any future logic that needs to know "will HR queries return data?" **Not used for the proactive workout guard** — see the table and rationale below.

**Why two flags:** Using the probe alone (as previously proposed) conflates "no recent HR data" with "permission denied." An authorized user who just paired their watch or hasn't worn it recently would have `probeHeartRateReadAccess() == false`, which would: (a) show a misleading "Grant Health Access" button for a user who already granted access, and (b) block the proactive workout for exactly the users who need overnight HR collection to generate their first data. The two-layer approach avoids both problems: the UI flag tracks prompt completion, the operational flag tracks actual data availability, and they gate different things.

#### SmartWakeSessionController.swift

**0a. Fix the boolean logic at ~line 186** — Replace:
```swift
isHealthKitAuthorized = status == .sharingAuthorized || status != .notDetermined
```
with:
```swift
isHealthKitAuthorized = status != .notDetermined
```
This correctly means "the user has been through the authorization prompt." Both `.sharingDenied` and `.sharingAuthorized` set it to `true`, which is correct for gating the UI button (re-prompting after denial is a no-op). The `.notDetermined` case sets it to `false`, showing the prompt button.

**0b. Add property** `private(set) var hasConfirmedHRAccess: Bool = false` near `isHealthKitAuthorized` (~line 35).

**0c. Add method `probeHeartRateReadAccess() async -> Bool`** — Runs a `HKSampleQuery` for `HKQuantityType(.heartRate)`, sorted by end date descending, limit 1, with a predicate for the last 24 hours. Returns `true` if the query returns ≥1 sample, `false` otherwise. Uses `withCheckedContinuation` to bridge the callback-based `HKSampleQuery` API. Log the result: `"HealthKit heart-rate probe: found=\(found)"`.

**0d. Call the probe after authorization** — At the end of the `do` block in `requestAuthorization()` (~line 186), after setting `isHealthKitAuthorized`, add:
```swift
hasConfirmedHRAccess = await probeHeartRateReadAccess()
```
Log both values: `"Authorization complete. promptCompleted=\(isHealthKitAuthorized) hrDataAccessible=\(hasConfirmedHRAccess)"`.

**0e. Update `hasConfirmedHRAccess` opportunistically and resend to phone** — In `processHeartRateSamples()` (~line 643), after successfully processing ≥1 valid sample, if `hasConfirmedHRAccess` is `false`: set it to `true`, log once `"HR access confirmed via live sample"`, and call a new callback `onHRAccessConfirmed?()`. This handles the new-watch edge case: the probe at launch may return `false` (no history yet), but once the workout session generates HR data, the flag upgrades automatically.

**0e-wire. Wire the resend callback** — In `WatchAppServices.swift`, after constructing the session controller, set:
```swift
sessionController.onHRAccessConfirmed = { [weak self] in
    self?.sessionManager.sendHeartRateStatus(active: true)
}
```
This ensures the phone receives the updated HR-active status when `hasConfirmedHRAccess` upgrades from `false` to `true` during overnight monitoring.

**0e-durable. Make `sendHeartRateStatus` delivery durable** — The current `sendPermissionStatus` (WatchSessionManager.swift line 75, renamed to `sendHeartRateStatus` in Step 0f-rename) only sends via `session.sendMessage` when `session.isReachable`, and silently drops the message otherwise. The `onHRAccessConfirmed` callback fires during overnight monitoring when the phone is almost certainly asleep (not reachable). Fix: replace the current reachability-gated send with the same try-realtime-then-fallback pattern used by `sendSmartWakeTrigger`:
```swift
if session.isReachable {
    session.sendMessage(message, replyHandler: nil) { [weak self] error in
        self?.logStore.log(
            "CONNECTIVITY",
            "sendMessage failed for heart rate status, falling back to transferUserInfo: \(error.localizedDescription)",
            level: .warning
        )
        session.transferUserInfo(message)
    }
} else {
    session.transferUserInfo(message)
}
```
This covers both cases: (a) phone unreachable (overnight/sleep) → `transferUserInfo` queued immediately, and (b) phone nominally reachable but `sendMessage` fails (stale reachability, transient connectivity loss) → `errorHandler` falls back to `transferUserInfo`. The phone-side handler in `WatchConnectivityService.handleMessage` already processes both `sendMessage` and `transferUserInfo` payloads through the same `handleMessage(_:)` path, so no receiver changes are needed.

**Known limitation:** Unlike `updateApplicationContext` (latest-state-wins), `transferUserInfo` is FIFO and all messages are delivered. If the flag upgrades and then downgrades (impossible in practice since `hasConfirmedHRAccess` is a monotonic latch), the phone would process them in order. This is fine for a one-way `false → true` upgrade.

**How the two flags are used:**
| Flag | Gates | `true` means |
|------|-------|-------------|
| `isHealthKitAuthorized` | "Grant Health Access" button visibility (WatchRootView line 54), Step 4 proactive workout guard | User has completed the HealthKit prompt |
| `hasConfirmedHRAccess` | Permission status sent to phone (LightsTimerWatchApp line 26), any future logic that needs to know "will HR queries return data?" | We have evidence that HR reads actually work |

**Why `isHealthKitAuthorized` (not `hasConfirmedHRAccess`) gates the proactive workout:** The proactive workout's purpose is to keep the app alive via `workout-processing` mode AND to generate frequent HR samples. Blocking it when `hasConfirmedHRAccess` is false would prevent the very mechanism that could generate the first HR data. The proactive workout should start as long as the user has been through the authorization prompt (`isHealthKitAuthorized == true`). If authorization was actually denied, the workout session will start but the anchored HR query will return no data — the heuristic engine handles data-sparse scenarios gracefully (baseline never freezes → no early trigger → force-fire at wake time). This is correct degraded behavior, not a failure.

**Why `hasConfirmedHRAccess` (not `isHealthKitAuthorized`) is sent to the phone:** The phone receives this value via `sendHeartRateStatus(active:)` (renamed in Step 0f-rename) and displays it as "Heart rate data active on Apple Watch" / "Waiting for heart rate data from Apple Watch" via `HealthKitAuthorizationService.updateFromWatch(heartRateActive:)`. This status should reflect whether the watch can actually deliver HR data, not just whether the prompt was completed. A denied user should show "Waiting" on the phone. An authorized user with no recent HR history will also show "Waiting" until the first sample arrives and `hasConfirmedHRAccess` upgrades — this is slightly conservative but accurate (no HR data is accessible yet).

**0f. Update phone heart-rate status source** — In `LightsTimerWatchApp.swift` (~line 25), change:
```swift
services.sessionManager.sendPermissionStatus(
    authorized: services.sessionController.isHealthKitAuthorized
)
```
to:
```swift
services.sessionManager.sendHeartRateStatus(
    active: services.sessionController.hasConfirmedHRAccess
)
```
**0f-rename. Rename the permission-status protocol to match the new semantics.** The parameter/method/property names currently say "authorized" but the semantic is now "HR data is accessible." Leaving the old names creates a maintenance trap where future readers assume "authorized" means HealthKit authorization. Rename across the protocol boundary:

| File | Old name | New name |
|------|----------|----------|
| `SmartWakePermissionStatus` (both copies) | `healthKitAuthorized: Bool` | `heartRateDataActive: Bool` |
| `WatchSessionManager.swift` | `sendPermissionStatus(authorized:)` | `sendHeartRateStatus(active:)` |
| `HealthKitAuthorizationService.swift` | `updateFromWatch(authorized:)` | `updateFromWatch(heartRateActive:)` |
| `HealthKitAuthorizationService.swift` | `isAuthorizedOnWatch` | `isHeartRateActiveOnWatch` |
| `WatchConnectivityService.swift` | handler call site | update to match new method name |
| `ContentView.swift` | environment read of `isAuthorizedOnWatch` | update to `isHeartRateActiveOnWatch` |

The `WCMessageKey.permissionStatus` key and the `WCMessageKey.type` envelope stay the same. The Swift property is renamed but the **wire key must stay stable** — watch and iPhone don't update atomically, so a new sender must produce payloads that old receivers can still decode. Use `CodingKeys` to map the new property name to the old wire key:
```swift
struct SmartWakePermissionStatus: Codable {
    var heartRateDataActive: Bool
    var watchConnected: Bool

    private enum CodingKeys: String, CodingKey {
        case heartRateDataActive = "healthKitAuthorized"  // wire key stable
        case watchConnected
    }
}
```
No custom encoder. No custom decoder. No backward-compatibility fallback needed. The JSON payload still contains `{"healthKitAuthorized": true, "watchConnected": true}` — old receivers decode it fine. New receivers decode it fine (CodingKeys maps the wire key to the new property). This is what `CodingKeys` is for.

**0f-ui. Update phone-side display text** — In `HealthKitAuthorizationService.swift` (~line 18), update to use the renamed parameter and status messages:
```swift
func updateFromWatch(heartRateActive: Bool) {
    isHeartRateActiveOnWatch = heartRateActive
    updateStatusMessage(
        heartRateActive
            ? "Heart rate data active on Apple Watch"
            : "Waiting for heart rate data from Apple Watch"
    )
}
```
The old "Authorized" / "Not authorized" text implied a binary permission state. With `hasConfirmedHRAccess` as the source, `false` can mean either "denied" or "authorized but no recent data yet." The new text ("Waiting for heart rate data") is accurate-enough for both cases: a denied user genuinely has no data coming, and a new-watch user just needs to wait for the first HR sample. This avoids the regression where a granted-but-data-sparse user would see "Not authorized" — which would be misleading and could prompt them to re-check Settings unnecessarily.

**0g. Re-evaluate schedules immediately after a manual authorization attempt from the watch UI.** The current `WatchRootView` button only calls `requestAuthorization()`. That leaves an implementation hole: if the user grants access while already in the app and a wake is already armed within `maxProactiveLeadTime`, the proactive workout would not start until some later scene-phase change or schedule update. Fix: after the button-triggered `requestAuthorization()` call returns, call `alarmScheduler.onAppForeground()` directly. This is intentionally simple: the user is visibly in the app, so reusing the normal foreground reevaluation path is correct and avoids inventing another scheduler entry point.

**Known limitation — phone cannot distinguish denied from data-sparse.** `SmartWakePermissionStatus` carries a single `Bool`, so the phone UI cannot show "Permission denied — check Watch Settings" vs. "Authorized, waiting for first sample." Expanding the payload to a three-state enum would require changes to both copies of `SmartWakeMessage.swift`, the phone-side handler, and the UI — significant protocol churn for a debug-level status line. "Waiting for heart rate data" is an accurate description of the phone's actual state in both scenarios. If precise phone-side denied-vs-sparse UI becomes a product requirement, expand `SmartWakePermissionStatus` in a follow-up.

**Known limitation — no watch-side recovery UI for denied users.** After the user completes the HealthKit prompt, `isHealthKitAuthorized` becomes `true` regardless of grant/deny (Step 0a), which hides the "Grant Health Access" button in WatchRootView (line 54). Re-tapping that button after denial is a no-op anyway — HealthKit only shows the system prompt once; subsequent `requestAuthorization()` calls are silent no-ops. The actual recovery path for denied users is Settings > Privacy & Security > Health on the watch (or paired iPhone). Adding a "Health access may be denied — check Settings" banner when `isHealthKitAuthorized && !hasConfirmedHRAccess` persists beyond a reasonable timeout is a follow-up UI concern outside this plan's scope.

**Revised Step 4 guard:** Check `isHealthKitAuthorized` (not `hasConfirmedHRAccess`). The guard catches only the `.notDetermined` case — the user hasn't been prompted yet, so starting a workout session is premature. After the prompt (regardless of grant/deny), the proactive workout is allowed to attempt.

### Changes

#### SmartWakeSessionController.swift

1. **Add property** `private(set) var isProactiveWorkoutRunning = false` near existing state properties (~line 38)

2. **Add property** `private var lastHRSampleDate: Date?` for diagnostic display only (shown in WatchRootView diagnostics as "Last HR: Xs ago" so the user can verify overnight HR delivery is active)

3. **Add property** `private var seenSampleUUIDs = Set<UUID>()` for cross-path deduplication (also used in Issue 2)

4. **Add method `preStartWorkoutSession()`** — Synchronous (not async). Must be guarded: if `isProactiveWorkoutRunning` or `isWorkoutSessionRunning` is already true, log "Proactive workout already running — skipping" and return. This idempotency guard is essential because schedule reevaluation can fire twice on a single WCSession delivery: once from `WatchAppServices.sessionManager.onSchedulesUpdated` (line 28) and again from `LightsTimerWatchApp.onChange(of: activeSchedules)` (line 46). Also check `isHealthKitAuthorized` — if the user hasn't been through the authorization prompt yet (`.notDetermined`), log and return (no point starting a workout before the user has seen the HealthKit prompt). **This guard is now correct because Step 0a fixes the boolean logic so `.notDetermined` is the only `false` case.**

    **Stale-session cleanup before creating a new session.** After the boolean guards pass, check for and clean up a stale `workoutSession` reference:
    ```swift
    if workoutSession != nil {
        log("HEALTHKIT", "Cleaning up stale workout session reference before proactive start", level: .warning)
        if workoutBuilder != nil {
            // A stale builder should never be present here. Proactive sessions have no
            // builder, and monitoring-origin sessions go through teardown paths that nil
            // the builder. If we reach this, something is deeply wrong.
            log("HEALTHKIT", "Unexpected non-nil workoutBuilder during proactive cleanup — nilling without teardown", level: .error)
            workoutBuilder = nil
        }
        workoutSession?.end()  // No-op if already ended, but ensures clean state
        workoutSession = nil
    }
    ```
    The workout delegate at line 1270 sets `isWorkoutSessionRunning = false` on `.ended` but does NOT nil `workoutSession`. If a proactive workout dies overnight (Step 9a resets the boolean flags), `workoutSession` remains non-nil but dead. Without this cleanup, creating a new `HKWorkoutSession` would orphan the dead reference. The `end()` call on an already-ended session is a safe no-op per HealthKit documentation.

    The builder assertion is intentionally not a crash — in production, nilling and logging is preferable to crashing the watch app at 10 PM. But the error-level log makes it visible for debugging. If this ever fires, it indicates a missed teardown path that should be investigated.

    Creates `HKWorkoutSession` with the same `.other` / `.unknown` config, sets its delegate, calls `startActivity(with: Date())`. Does NOT create `HKLiveWorkoutBuilder`, call `beginCollection()`, or store a builder reference. Sets `isProactiveWorkoutRunning = true` and `isWorkoutSessionRunning = true`. If `HKWorkoutSession(healthStore:configuration:)` throws, logs the error but does NOT enter degraded mode (monitoring hasn't started). Because both `HKWorkoutSession.init` (throws, sync) and `startActivity` (void, sync) are synchronous, there is no race with the app losing foreground status.

    **State machine note:** After `preStartWorkoutSession()` returns, `isProactiveWorkoutRunning` is `true`. The delegate may later report `.ended` or failure asynchronously — but because the delegate uses `Task { @MainActor in }`, this callback is serialized on the main actor after `preStartWorkoutSession()` completes. There is no mid-method race. Steps 9-10 handle the async delegate callbacks and reset the flags. Between the sync return and the async delegate callback, the state is transiently optimistic — this is intentional and safe because no code path reads the flags in that sub-runloop window.

5. **Add method `isWorkoutSessionUsable() -> Bool`** — Returns `true` if `workoutSession != nil` and its state is `.running`. The `.prepared` state is excluded because it means `startActivity()` was never called, so the session is not actively sensing HR.

6. **Add method `stopProactiveWorkout()`** — Called from true teardown paths only: session invalidation, wake-identity change (see Step 12 for the full list), or dead-session cleanup at monitoring start (Step 7). NOT called from `cancelAlarmSession()` because that is also used by the internal reschedule path. Calls `workoutSession?.end()`, nils out `workoutSession`, resets `isProactiveWorkoutRunning` and `isWorkoutSessionRunning`. Does NOT touch builder state since there is no builder (or calls `discardWorkout()` if using the fallback path). This ensures no workout is saved to HealthKit.

7. **Modify `startMonitoring()` (~line 256)** — Three changes:

    **7a. Add `isMonitoringStartupInProgress` flag and use it to prevent duplicate entry.** The plan needs `isMonitoringActive` set AFTER workout setup so the workout delegate doesn't misclassify a proactive workout death during the setup gap as a monitoring failure. But the workout setup includes an `await startWorkoutSession()` call. During that `await`, the main actor is yielded, and `schedulesDidUpdate()` can fire (via either WatchAppServices line 28 or LightsTimerWatchApp line 46). With `isMonitoringActive` still `false`, the `schedulesDidUpdate()` guard at line 384, the `startMonitoringNow()` guard at line 726, and `startMonitoring()`'s own `guard !isMonitoringActive` at line 225 all pass — producing duplicate workout sessions, HR queries, and timers.

    Add `private(set) var isMonitoringStartupInProgress = false` alongside `isMonitoringActive`. At the top of `startMonitoring()`, immediately after the existing `guard !isMonitoringActive` (line 225), add:
    ```swift
    guard !isMonitoringStartupInProgress else {
        log("SESSION", "Ignoring duplicate startMonitoring — startup already in progress")
        return
    }
    isMonitoringStartupInProgress = true
    ```
    This closes the re-entry window immediately. `isMonitoringActive` stays `false` until the workout setup resolves, preventing the workout delegate from misclassifying a proactive workout death as a monitoring failure. But `isMonitoringStartupInProgress` blocks duplicate entry during the async gap.

    `sessionState = .monitoring` and `notifyStateChange()` can stay before the workout setup for UI responsiveness — they don't gate the delegate logic.

    **Downstream guard updates required by 7a:**
    - `startMonitoringNow()` (line 726): change guard to `guard !sessionController.isMonitoringActive && !sessionController.isMonitoringStartupInProgress`
    - `schedulesDidUpdate()` existing `isMonitoringActive` check (line 384): change to `sessionController.isMonitoringActive || sessionController.isMonitoringStartupInProgress`
    - `seedHistoricalHeartRateSamples()` (line 580): change `guard isMonitoringActive` to `guard isMonitoringActive || isMonitoringStartupInProgress` — the seed fetch is async and may complete during the startup gap; discarding valid seed data because the flag hasn't flipped yet would break the baseline
    - `startDegradedMonitoring()` (line 522): at the top, before starting queries/timers, set `isMonitoringActive = true` and `isMonitoringStartupInProgress = false` — degraded mode is the final monitoring state commitment, and the methods it calls (`startHeartRateQuery`, `checkForWakeTrigger`, `startHistoricalSeed`) assume `isMonitoringActive` is true
    - All teardown paths (`tearDownMonitoringSession()`, `stopMonitoring()`, `tearDownMonitoringWithoutCompletion()`): also reset `isMonitoringStartupInProgress = false`

    **7b. Replace the current stale-teardown + `startWorkoutSession()` block with a three-way branch, preceded by unconditional stale-session cleanup for non-proactive dead sessions:**

   First, unconditional stale cleanup (preserves the existing teardown at line 256):
   ```swift
   if !isProactiveWorkoutRunning && workoutSession != nil {
       // Dead monitoring-origin session still referenced — clean it up
       // exactly as the current code does at line 256.
       log("SESSION", "Tearing down stale workout state before fresh monitoring start", level: .warning)
       await endWorkoutSession()
   }
   ```
   This preserves the current generic cleanup for the case where monitoring starts without a proactive session but with a dead monitoring-origin `workoutSession` still referenced. Without this, the branch below would fall through to the "no proactive workout" path and call `startWorkoutSession()` without cleaning up the dead one — a regression from the current code.

   Then the three-way branch:
   - If proactive workout is usable (`isWorkoutSessionUsable()`) → reuse it. Log "Reusing proactive workout session for monitoring". Set `isProactiveWorkoutRunning = false` (now "owned" by monitoring). Proceed to start HR query, exact-wake timer, historical seed.
   - If proactive workout exists but died (`isProactiveWorkoutRunning` was true but `isWorkoutSessionUsable()` is false) → tear it down via `stopProactiveWorkout()`, then try `startWorkoutSession()` (the existing async/builder path). Fall back to degraded if that also fails.
   - If no proactive workout → original path (try `startWorkoutSession()`, catch → degraded). The stale-session cleanup above guarantees no dead session is orphaned here.

    **7c. Reconcile the workout startup result before committing monitoring active.** Immediately after the workout setup block resolves (reuse or fresh start), but before wiring HR queries/timers, check:
    ```swift
    if isDegradedMode || !isWorkoutSessionUsable() {
        log("SESSION", "Workout startup resolved without a usable session — entering degraded monitoring", level: .warning)
        await endWorkoutSession()   // or a helper that clears the dead reference/builder without saving
        startDegradedMonitoring()
        return
    }
    ```
    This is the explicit handoff that was missing from the March 19 path. The delegate-side Step 9b sets the signal (`isDegradedMode = true`) while `await beginCollection()` is suspended; this step consumes that signal and turns it into an actual degraded-mode transition instead of letting the normal path continue with a dead session reference.

    On the non-degraded path, set `isMonitoringActive = true` and clear `isMonitoringStartupInProgress = false` before wiring HR queries, timers, and the startup `checkForWakeTrigger()` call. `checkForWakeTrigger()` hard-guards on `isMonitoringActive` (line 708: `guard isMonitoringActive`), so if the flag is still `false` when the startup evaluation runs, the evaluation is silently dropped. The correct ordering on the non-degraded path is:

    ```
    1. Workout setup resolves (reuse or fresh start)
    2. isMonitoringActive = true, isMonitoringStartupInProgress = false
    3. Start HR query, schedule timers (exact-wake, seed-timeout, window-start)
    4. Start historical seed
    5. Startup checkForWakeTrigger()
    ```

    If the workout setup falls through to degraded, `startDegradedMonitoring()` handles the flag transition (see 7a downstream updates — it sets `isMonitoringActive = true` at its top before calling any methods that depend on it). Now the delegate correctly distinguishes proactive-phase workout death (Steps 9-10) from monitoring-phase workout death (existing line 1272 logic), and the suspended startup path has a deterministic degraded-mode exit.

8. **Modify `endWorkoutSession()` (~line 508)** — Also reset `isProactiveWorkoutRunning = false`. If using the `discardWorkout()` fallback path (spike failed), branch on `isProactiveOrigin`: call `discardWorkout()` for proactive-origin sessions, `finishWorkout()` for monitoring-origin sessions.

9. **Modify workout session delegate `didChangeTo` (~line 1270)** — The existing branch at line 1272 checks `isMonitoringActive && !isDegradedMode`. With the delayed `isMonitoringActive` flag (Step 7a), this branch no longer catches workout failures during the monitoring startup gap. Two new branches are needed, checked in this order before the existing branch:

    **9a. Proactive-phase death** (new): if `toState == .ended` and `isProactiveWorkoutRunning` but NOT `isMonitoringActive` and NOT `isMonitoringStartupInProgress`, log "Proactive workout session ended before monitoring started" and reset `isProactiveWorkoutRunning` and `isWorkoutSessionRunning`. This makes overnight session death visible. It does NOT enter degraded mode (monitoring hasn't started).

    **9b. Monitoring-startup-phase death** (new): if `toState == .ended` and `isMonitoringStartupInProgress` and NOT `isMonitoringActive`, log "Workout session ended during monitoring startup — marking degraded startup result" and set `isDegradedMode = true`. This is the exact March 19 failure scenario: `startWorkoutSession()` calls `startActivity()`, the delegate fires `.ended` asynchronously during `await beginCollection()` (line 504), and the failure lands while `isMonitoringStartupInProgress == true` but `isMonitoringActive == false`. This branch intentionally does NOT try to start queries/timers itself; Step 7c is the single place that consumes the degraded signal, tears down the dead session reference, and enters `startDegradedMonitoring()`.

    **Existing branch** (line 1272): `isMonitoringActive && !isDegradedMode` → degraded mode. Unchanged. Handles workout death after the startup gap has resolved and `isMonitoringActive` is true.

10. **Same for `didFailWithError` delegate (~line 1285)** — Add the same two branches (proactive-phase and monitoring-startup-phase) before the existing handling.

**Known limitation — no recovery from overnight proactive session death.** If the proactive workout dies at (say) 2 AM, there is no way to restart it from background — that is the fundamental watchOS constraint this entire plan exists to work around. Steps 9-10 provide observability only. When monitoring starts at 7:05 AM via the extended runtime callback, Step 7's fallback path will attempt `startWorkoutSession()` from background, which will almost certainly fail with the same "cannot start while in background" error, resulting in degraded mode. This is identical to today's behavior. The proactive approach is a best-effort improvement for the happy path (session survives overnight), not a guarantee.

**Known limitation — process relaunch loses the proactive workout.** If watchOS evicts the process overnight and later relaunches it for the alarm session, `WatchExtensionDelegate.handle(_:)` (line 6) recovers the `WKExtendedRuntimeSession` via `attachRecoveredExtendedRuntimeSession()` (line 177), but there is no watchOS API to recover an in-flight `HKWorkoutSession`. The proactive workout is lost. Monitoring will attempt `startWorkoutSession()` from the recovered background session context — same failure as today → degraded mode. **This materially limits Issue 1's upside: the proactive workout only helps when the process survives the full overnight period without eviction.** Process survival is typical for workout-processing apps but not guaranteed. This is the single biggest risk factor for the proactive approach, and the reason degraded mode must remain a robust fallback.

#### SmartAlarmScheduler.swift

11. **Add constant** `private let maxProactiveLeadTime: TimeInterval = 10 * 3600` (10 hours).

11a. **Modify `scheduleAlarmSession()` (~line 620)** — After `session.start(at: date)`, check whether `baselineStart - now <= maxProactiveLeadTime` (use `baselineStart` from the `PendingWake`, NOT `scheduledSessionStart` — `baselineStart` is the computed monitoring start, while `scheduledSessionStart` may be a preserved value from a prior arming). If yes, call `sessionController.preStartWorkoutSession()` directly (synchronous, no `Task {}`). If no (too early), log "Deferring proactive workout start — monitoring is \(hours)h away, max lead time is 10h" and skip the workout start. The app is guaranteed foreground here because `scheduleAlarmSession()` is only reached after the `isSceneActive` guard (Step S4). Both the session init and `startActivity` are sync calls.

11b. **Add deferred proactive workout start in foreground re-evaluation** — In the `schedulesDidUpdate()` path (line ~295), after confirming the wake is still armed (`hasEquivalentArmedWake` returns true, line ~395), add a check: if `!sessionController.isProactiveWorkoutRunning` and `pendingSchedule.baselineStart - now <= maxProactiveLeadTime` and `isSceneActive`, call `sessionController.preStartWorkoutSession()` and log "Starting deferred proactive workout — monitoring in \(hours)h". Use `baselineStart` from the pending wake, same as Step 11a.

**The `isSceneActive` guard is mandatory.** `schedulesDidUpdate()` is called from `WatchAppServices.sessionManager.onSchedulesUpdated` (line 28-29 of `WatchAppServices.swift`), which receives WCSession deliveries on a background queue and transitions to `@MainActor` via `Task {}`. The `hasEquivalentArmedWake` early-return path (line 395-424) runs before the `isSceneActive` guard at line 456 (which only gates new arming). Without the explicit `isSceneActive` check here, a background WCSession delivery would attempt `preStartWorkoutSession()` from background — the exact failure this plan exists to fix.

**The idempotency guard in `preStartWorkoutSession()` (Step 4) handles double-evaluation.** `schedulesDidUpdate()` can fire twice on a single WCSession delivery (once from `onSchedulesUpdated` at WatchAppServices.swift:28, once from `onChange(of: activeSchedules)` at LightsTimerWatchApp.swift:46). The first call starts the proactive workout; the second call hits the `isProactiveWorkoutRunning` guard and returns immediately.

This is the mechanism that picks up the workout start on a later foreground visit when arming happened too early. The foreground re-evaluation path already runs on every foreground entry (`App returned to foreground — re-evaluating schedules`).

12. **Hook `stopProactiveWorkout()` into `cancelAlarmSession()` with a reschedule guard.** `cancelAlarmSession()` (~line 672) is the single chokepoint for all extended runtime session teardown. The original plan avoided hooking into it because `rescheduleAlarmSession()` (~line 642) calls `cancelAlarmSession()` as an internal reschedule for the same wake. But the code at line 672-680 shows that `cancelAlarmSession()` sets `extendedSession = nil` *before* calling `invalidate()`, which means the `didInvalidateWith` delegate (line 1159) hits the `extendedRuntimeSession === self.extendedSession` stale-session guard and returns early. Step 13's cleanup would never fire for app-initiated cancellations (schedule disable/delete/change, no-upcoming-wake at line 343, monitoring cancellation at line 525, or `clearStaleArmedWakeIfNeeded` at lines 932/945).

    **Fix:** Add a `isRescheduling` parameter to `cancelAlarmSession()`:
    ```swift
    private func cancelAlarmSession(clearPersistedWake: Bool, isRescheduling: Bool = false)
    ```
    At the top of `cancelAlarmSession()`, before `clearSchedulerState()`:
    ```swift
    if !isRescheduling && sessionController.isProactiveWorkoutRunning && !sessionController.isMonitoringActive {
        sessionController.stopProactiveWorkout()
    }
    ```
    Update `rescheduleAlarmSession()` (~line 642) to pass `isRescheduling: true`. All other call sites keep the default `false`. This preserves the proactive workout across timing-only reschedules while ensuring every true cancellation path cleans up the workout.

    **Why `!isMonitoringActive`:** If monitoring is already active, the workout session is owned by the monitoring phase (Step 7b set `isProactiveWorkoutRunning = false`). Monitoring teardown handles its own workout cleanup. The guard prevents `cancelAlarmSession()` from interfering with an active monitoring session.

13. **Keep `didInvalidateWith` delegate (~line 1153) as a secondary safety net** — The delegate still checks `sessionController.isProactiveWorkoutRunning && !sessionController.isMonitoringActive` and calls `stopProactiveWorkout()` if true. This catches the edge case where the system invalidates the session externally (not via `cancelAlarmSession()`), e.g., watchOS killing the session due to resource pressure. For app-initiated cancellations, Step 12 handles cleanup before the delegate fires (and the delegate's stale-session guard makes it a no-op anyway).

Note: `rescheduleAlarmSession()` is only reached from `extendedRuntimeSessionDidStart` (line 1105), which is background execution. Starting a proactive workout there would hit the same background restriction we are solving. No proactive workout start in `rescheduleAlarmSession()`. The proactive workout is intentionally preserved across reschedules since the wake identity hasn't changed. Similarly, if the deferred-start check in Step 11b runs during a foreground pass but the extended runtime session has already started (i.e., we're already in the monitoring window), there is no value in starting a proactive workout — monitoring will handle the workout session directly.

13a. **Update `extendedRuntimeSessionWillExpire` (~line 1119) to handle `isMonitoringStartupInProgress`** — The current code at line 1136 checks `!self.sessionController.isMonitoringActive` to decide whether to start monitoring as a last resort, and line 1141 checks `self.sessionController.isMonitoringActive` to decide whether to force an immediate wake check. If the session expires during the startup gap (`isMonitoringStartupInProgress == true`, `isMonitoringActive == false`), neither branch matches correctly: the first branch would try to start monitoring *again* (producing a duplicate since `isMonitoringStartupInProgress` blocks `startMonitoring()` but `startMonitoringNow()` calls it), and the second branch (force wake check) wouldn't run because `isMonitoringActive` is false.

    **Fix:** Add a third branch before the existing two:
    ```swift
    if self.sessionController.isMonitoringStartupInProgress,
       self.sessionController.sessionState != .triggered {
        // Monitoring startup is in progress but hasn't committed yet.
        // Force an immediate wake check — checkForWakeTrigger() guards on
        // isMonitoringActive, but the force-fire path at `now >= wakeUpTime`
        // must still work. Call forceImmediateWakeCheck() which bypasses the
        // isMonitoringActive guard for the force-fire case.
        self.logStore.log(
            "SCHEDULER",
            "Session expiring during monitoring startup — forcing wake check",
            level: .warning
        )
        self.sessionController.forceImmediateWakeCheck()
    } else if !self.sessionController.isMonitoringActive ...  // existing branch
    ```

    **Also update `forceImmediateWakeCheck()`** — This method currently just calls `checkForWakeTrigger()`, which hard-guards on `isMonitoringActive`. For the session-loss emergency path, the force-fire (`now >= wakeUpTime`) and the teardown must work regardless of whether startup has committed. Change `forceImmediateWakeCheck()` to bypass the `isMonitoringActive` guard for the exact-wake force-fire path only:
    ```swift
    func forceImmediateWakeCheck() {
        guard let wakeUpTime, let currentSchedule else { return }
        // Bypass isMonitoringActive guard — this is a last-chance emergency check
        // before background execution is lost.
        let now = Date()
        if now >= wakeUpTime, !heuristicEngine.hasTriggered {
            // Force-fire path — reuse the existing fireTrigger() which bundles
            // state changes, haptics, phone handoff, deferred fallback, and
            // post-trigger cleanup (SmartWakeSessionController.swift line 754).
            log("WAKE_WINDOW", "Emergency force-fire at \(formatTimestamp(now)) — session loss during startup gap")
            fireTrigger(
                schedule: currentSchedule,
                confidence: 1.0,
                fallbackMode: .exactWakeFinalState
            )
        } else if isMonitoringActive {
            // Normal heuristic evaluation is only meaningful once monitoring has
            // fully committed. During the startup gap, checkForWakeTrigger() still
            // guards on isMonitoringActive and would just return.
            checkForWakeTrigger()
        }
    }
    ```
    Note: `fireTrigger()` (line 754) is the single trigger path that bundles `heuristicEngine.markTriggered`, state changes, haptics, phone handoff, deferred local fallback, and monitoring teardown. The emergency path must use it, not inline a subset of trigger logic.

    **Important nuance:** If startup is still in progress and exact wake time has NOT yet been reached, `forceImmediateWakeCheck()` intentionally does nothing heuristic-related. That is correct. During the startup gap the controller has not fully committed monitoring state yet, so a heuristic evaluation is not reliable. The last-chance emergency behavior for that gap is: force-fire if already at/after wake time; otherwise tear down without completion and rely on a later foreground rescue pass.

13b. **Update `extendedRuntimeSession(didInvalidateWith:)` (~line 1209) to handle `isMonitoringStartupInProgress`** — Same pattern. The existing branch at line 1209 checks `isMonitoringActive`. Add `|| isMonitoringStartupInProgress` to that condition so invalidation during the startup gap also triggers the last-chance wake check and teardown:
    ```swift
    } else if self.sessionController.isMonitoringActive || self.sessionController.isMonitoringStartupInProgress,
              self.sessionController.sessionState != .triggered {
        // ... existing force-wake-check + teardown logic
    }
    ```
    The `tearDownMonitoringWithoutCompletion()` call inside this branch already resets both `isMonitoringActive` and `isMonitoringStartupInProgress` (per Step 7a downstream updates), so no additional cleanup is needed.

#### WatchRootView.swift

14. **Update diagnostics section (~line 209)** — Show proactive workout status: green checkmark + "Workout Session (overnight)" when `isProactiveWorkoutRunning`, vs "(monitoring)" when `isWorkoutSessionRunning && !isProactiveWorkoutRunning`, vs gray xmark otherwise.

15. **Update armed status subtitle** — Append "(HR active)" when proactive workout is running, so the user gets confirmation that overnight HR monitoring is engaged.

---

## Issue 2: Filter Future-Dated HR Samples + Deduplicate Seed/Live Overlap (IMPLEMENTED 2026-03-20)

**Result:** The watch-side implementation is in the current branch. The anchored query is bounded to `wakeUpTime + 5m`, future-dated batches are filtered before reaching the heuristic engine, and seed/live overlap is deduplicated by `HKSample.uuid` on both ingestion paths. A sub-agent diff review using `.claude/code-reviewer.md` found no actionable issues; the remaining gap is automated regression coverage for mixed duplicate/future-dated HealthKit batches.

### Root Cause

The `HKAnchoredObjectQuery` uses `predicate: HKQuery.predicateForSamples(withStart: Date(), end: nil)` with `anchor: nil`. The initial callback returns ALL matching samples in HealthKit's store — including samples with corrupted future dates (June-July 2026). These are likely HealthKit beta artifacts or data written by a source with incorrect dates. They are correctly rejected by the heuristic engine but generate per-sample log warnings.

Additionally, `startMonitoring()` starts the live anchored query at time T1 (`Date()` at line 264) and then seeds history up to time T2 (`Date()` at line 269, slightly after T1). Both feed into `WakeHeuristicEngine` which blindly appends. With denser overnight workout data, boundary samples near 07:05 are likely to appear in both the anchored query's initial callback and the historical seed, producing duplicates that skew HRV calculations and confidence scores.

### Changes

#### SmartWakeSessionController.swift

16. **Modify `startHeartRateQuery(from:)` (~line 622)** — Change signature to `startHeartRateQuery(from:until:)`. Set the predicate's `end` date to `wakeUpTime + 5 minutes`:
    ```swift
    let predicate = HKQuery.predicateForSamples(
        withStart: startDate,
        end: endDate?.addingTimeInterval(300)
    )
    ```
    The `updateHandler` still delivers new samples in real-time as long as their `startDate` falls within the predicate window. Samples with dates months in the future are excluded at the HealthKit level.

    **Edge case — monitoring starts after `wakeUpTime`:** If `startDate > endDate` (e.g., delayed extended runtime session fires after the wake time has passed), clamp: use `end: max(startDate.addingTimeInterval(300), endDate.addingTimeInterval(300))` so the query window is always valid.

17. **Update call sites** to pass wake time:
    - In `startMonitoring()` (~line 264): pass `until: wakeUpTime`
    - In `startDegradedMonitoring()` (~line 530): pass `until: wakeUpTime` (access via stored `self.wakeUpTime`)

18. **Add batch pre-filter in `processHeartRateSamples()` (~line 643)** — Before the per-sample loop, filter out samples > 120s in the future and log a single consolidated warning:
    ```
    "Filtered N future-dated sample(s) from anchored query batch of M"
    ```
    This reduces log noise from N lines to 1. The heuristic engine's per-sample filter remains as defense-in-depth.

18b. **Differentiate initial-batch vs live-update logging.** The `HKAnchoredObjectQuery` in `startHeartRateQuery()` (line 622) uses the same `processHeartRateSamples()` handler for both the `resultsHandler` (initial batch of all matching samples in HealthKit's store) and the `updateHandler` (real-time hardware updates). The per-sample log at line 654 says "Live heart-rate sample" for all of them, which is misleading: the initial batch is historical data that arrived at query creation time, not real-time sensor readings. The March 19 runtime log made the future-dated June samples look like the hardware was producing real-time readings months in the future, when they were actually stale HealthKit artifacts returned in the initial query result set.

    **Fix:** Add a `source: String` parameter to `processHeartRateSamples()`:
    ```swift
    nonisolated private func processHeartRateSamples(_ samples: [HKSample]?, source: String)
    ```
    Update the callers in `startHeartRateQuery()`:
    ```swift
    ) { [weak self] _, samples, _, _, _ in
        self?.processHeartRateSamples(samples, source: "initial-query")
    }
    query.updateHandler = { [weak self] _, samples, _, _, _ in
        self?.processHeartRateSamples(samples, source: "live")
    }
    ```
    Change the per-sample log from `"Live heart-rate sample"` to `"Heart-rate sample (\(source))"`. This makes the log unambiguous: initial-query samples that arrive in a batch are clearly distinguishable from genuine live hardware readings. The consolidated future-date warning from Step 18 also benefits — `"Filtered N future-dated sample(s) from initial-query batch of M"` immediately tells the reader these were stale HealthKit artifacts, not live sensor anomalies.

19. **Add UUID-based deduplication in `processHeartRateSamples()` (~line 643)** — After the future-date filter, check each sample's `HKSample.uuid` against `seenSampleUUIDs`. Skip samples whose UUID is already in the set; insert new UUIDs. This is done at the controller level because both data paths (live query and historical seed) converge here and the controller has access to raw `HKQuantitySample` objects with their UUIDs.

19a. **Guard against empty-after-filtering batches** — After both the future-date filter (Step 18) and UUID dedup (Step 19), check if the remaining sample array is empty. If so, return early WITHOUT calling `checkForWakeTrigger()` and without updating `lastHRSampleDate`. This prevents stale heuristic re-evaluation when a batch arrives that contains only future-dated or duplicate samples.

20. **Add UUID-based deduplication in `seedHistoricalHeartRateSamples()` (~line 576)** — Before mapping `[HKQuantitySample]` to `(date, bpm)` tuples (line 581), filter out samples whose `.uuid` is already in `seenSampleUUIDs`, then insert the new UUIDs. This handles the case where the anchored query's initial callback delivered boundary samples before the seed completes. After dedup, if the remaining sample array is empty, skip the `heuristicEngine.seedHeartRateSamples()` call and the subsequent `checkForWakeTrigger()` (line 593) — a fully-deduped seed contains no new data, so evaluating would produce the same stale result.

21. **Clear `seenSampleUUIDs` in monitoring teardown paths** (`tearDownMonitoringSession()`, `stopProactiveWorkout()`) so it doesn't grow unbounded across sessions.

Note: The heuristic engine (`WakeHeuristicEngine.swift`) does NOT change for dedup. It continues to receive pre-deduplicated `(date, bpm)` tuples. Sample identity is a HealthKit concern, not a heuristic concern.

---

## Issue 3: Eliminate Redundant Wake Checks (IMPLEMENTED 2026-03-20)

**Result:** The periodic 10-second wake-check timer has been removed from `SmartWakeSessionController`. Monitoring now evaluates on new HR data plus three one-shot timers: exact wake time (force-fire backstop), wake-window start (re-evaluate pre-window confidence the instant the window opens), and seed timeout (preserve the 30-second baseline-freeze escape hatch when no seed/live data arrives). The watch target builds successfully with this change.

### Root Cause

Without an active `HKWorkoutSession`, the watch only measures HR passively every ~5 minutes. The 10-second wake-check timer evaluates the same stale data ~30 times between samples. This is wasteful and clutters logs. Even in the success path (workout active, samples every few seconds), the 10-second timer creates redundant evaluations because `processHeartRateSamples()` already calls `checkForWakeTrigger()` on every sample arrival (line 660).

Fixing Issue 1 is the primary solution — with an active workout session, HR data arrives every few seconds.

### Solution

The periodic heuristic timer is unnecessary in both modes. `processHeartRateSamples()` already calls `checkForWakeTrigger()` on every sample arrival, and `seedHistoricalHeartRateSamples()` also calls it after seeding (line 593). The heuristic result cannot change without new data, so timer-driven re-evaluation between samples produces identical results every time.

Replace the current 10-second periodic timer with:
- **Sample-driven `checkForWakeTrigger()` calls** — already exist in both `processHeartRateSamples()` (line 660) and `seedHistoricalHeartRateSamples()` (line 593). These are the only meaningful evaluation points.
- **A one-shot exact-wake timer** that fires precisely at `wakeUpTime` for guaranteed force-fire. This is the safety net that ensures the alarm fires even if no new HR data arrives.
- **A one-shot seed-timeout timer** that fires 30 seconds after monitoring starts, to preserve the heuristic engine's seed-timeout escape hatch (see Step 24a).

This eliminates the `wakeCheckTimer` and `startWakeCheckTimer()`. The symbols `hasNewDataSinceLastCheck`, `wakeCheckInterval`, and `restartWakeCheckTimerIfNeeded()` do not exist in the current codebase — no removal needed.

In degraded mode with passive HR (~5 min intervals), evaluations happen on each passive sample arrival — slower but correct, since there is no new data to evaluate between arrivals. The one-shot timers guarantee the force-fire backstop and seed-timeout regardless.

**Important limitation:** This issue removes redundant 10-second *evaluations*; it does NOT create 10-second HR *sampling* in degraded mode. If the proactive workout is gone, there is no reliable watchOS API in the current design that forces a fresh HR measurement every 10 seconds. The plan improves the happy path and makes degraded mode quieter and more honest, but degraded mode still depends on passive HR cadence.

### Changes

#### SmartWakeSessionController.swift

22. **Add properties**:
    - `private var exactWakeTimer: Timer?` for the one-shot wake-time backstop
    - `private var seedTimeoutTimer: Timer?` for the one-shot seed-timeout check
    - `private var windowStartTimer: Timer?` for the one-shot wake-window-boundary check

23. **Remove `startWakeCheckTimer()` (~line 666)** — Delete the periodic 10-second timer entirely. Remove the `wakeCheckTimer` property.

24. **Add `scheduleExactWakeTimer()`** — Schedules a one-shot `Timer` that fires at exactly `wakeUpTime`. The timer callback calls `checkForWakeTrigger()`, which already handles the `now >= wakeUpTime` force-fire path (line 724). This guarantees the force-fire happens within milliseconds of wake time. If `wakeUpTime` is already in the past when called (e.g., `startDegradedMonitoring()` after wake time), the timer fires immediately.

24b. **Add `scheduleWindowStartTimer()`** — Schedules a one-shot `Timer` that fires at exactly `windowStartTime`. The timer callback calls `checkForWakeTrigger()`, which re-evaluates with `inWakeWindow: now >= windowStartTime` now returning `true`. This guarantees that any confidence accumulated during the pre-window setup buffer (up to 2 minutes, per `computeSessionStart()`) is re-evaluated the instant the wake window opens. Without this timer, a high-confidence sample arriving during the pre-window buffer would call `shouldTrigger(inWakeWindow: false)` → return false, and the next evaluation would only happen on the next HR sample arrival — which in degraded mode could be 5+ minutes later, missing an early trigger opportunity.

    If `windowStartTime` is already past when called (e.g., monitoring starts inside the wake window), skip scheduling — the startup `checkForWakeTrigger()` call (Step 28) already evaluates with `inWakeWindow: true`. Similarly, if monitoring starts exactly at `windowStartTime`, skip — the startup call handles it.

24a. **Add `scheduleSeedTimeoutTimer()`** — Schedules a one-shot `Timer` that fires 30 seconds after monitoring starts. The timer callback calls `checkForWakeTrigger()`, which calls `shouldTrigger()` (line 240-242), which calls `freezeBaselineIfNeeded()` (line 123-138). This preserves the existing seed-timeout escape hatch: if the historical seed stalls AND no live samples arrive (the degraded-mode scenario), `freezeBaselineIfNeeded()` detects that `awaitingSeedSince` is >30s ago and proceeds with baseline freeze.

**Why this is necessary:** Without the periodic 10-second timer, `freezeBaselineIfNeeded()` is only called from `refreshMetrics()` → called from `addHeartRateSample()` and `seedHeartRateSamples()`. If the seed stalls and no live samples arrive, nothing ever calls `freezeBaselineIfNeeded()`, and the baseline stays locked in "awaiting seed" for the entire wake window. The heuristic engine would be completely dead until the one-shot exact-wake timer fires the force-fire path (which bypasses `shouldTrigger()` entirely at line 724). The seed-timeout timer ensures the 30-second escape hatch still works.

25. **Update `processHeartRateSamples()` (~line 643)** — After processing valid samples (post-filtering per Issue 2), update `lastHRSampleDate` to the latest sample's date. The existing `checkForWakeTrigger()` call at line 660 remains unchanged — it is now the primary heuristic evaluation path.

26. **Update `seedHistoricalHeartRateSamples()` (~line 576)** — After successful seeding, update `lastHRSampleDate` to the latest seeded sample's date. The existing `checkForWakeTrigger()` call at line 593 remains unchanged. **Cancel `seedTimeoutTimer` only if the heuristic engine actually accepted samples** — i.e., only if `heuristicEngine.awaitingHistoricalSeed == false` after the `seedHeartRateSamples()` call. The heuristic engine's `seedHeartRateSamples()` (line 59-86) early-returns without clearing `awaitingHistoricalSeed` when the input is empty (line 60-63) or when all samples are future-dated (line 71-73). If after dedup (Step 20) the remaining samples are empty, or if all valid samples are future-dated, the heuristic engine stays in `awaitingHistoricalSeed = true` and the seed-timeout timer must survive to trigger the 30-second escape hatch in `freezeBaselineIfNeeded()` (line 126-137). Cancelling the timer prematurely would strand the heuristic with no way to unblock baseline freeze until force-fire at wake time.

27. **Wire timers at monitoring start** — In `startMonitoring()` (~line 265) and `startDegradedMonitoring()` (~line 530), replace the `startWakeCheckTimer()` call with:
    - `scheduleExactWakeTimer()`
    - `scheduleSeedTimeoutTimer()`
    - `scheduleWindowStartTimer()` (only if `windowStartTime` is in the future; skip if monitoring starts inside or at the wake window)

28. **Keep the existing startup `checkForWakeTrigger()` calls** at `startMonitoring()` (line 266) and `startDegradedMonitoring()` (line 540). These are intentional one-shot evaluations at monitoring startup, not periodic timer ticks. They serve two purposes:
    - **Immediate force-fire**: If monitoring starts at or after `wakeUpTime` (e.g., delayed extended runtime session), the `now >= wakeUpTime` check (line 724) triggers force-fire without waiting for the first sample or the one-shot timer.
    - **Wake-window-start logging**: The `didLogWakeWindowStart` check (line 716) logs when the wake window begins, producing a clear timeline entry at monitoring start.

    These calls produce at most one evaluation log entry each at startup. They are distinct from the eliminated periodic timer, which produced identical evaluations every 10 seconds between samples.

29. **`checkForWakeTrigger()` (~line 708) — no structural changes needed.** The existing logic already handles all callers:
    - Force-fire at wake time (line 724: `if now >= wakeUpTime`) — triggered by one-shot timer, startup call, or session-loss emergency check
    - Heuristic evaluation (line 745: `shouldTrigger(...)`) — triggered by sample-driven calls, startup call, seed-timeout timer, or window-start timer
    No data-freshness guard is needed because callers are: (a) sample arrival (new data), (b) seed completion (new data), (c) one-shot exact-wake timer (force-fire only), (d) one-shot startup evaluation, (e) one-shot seed-timeout timer (baseline freeze check), (f) one-shot window-start timer (re-evaluates pre-window confidence with `inWakeWindow: true`), (g) `forceImmediateWakeCheck()` (line 678) — called by the scheduler from `extendedRuntimeSessionWillExpire` (line 1148) and `extendedRuntimeSession(didInvalidateWith:)` (line 1153) as a last-chance emergency check before background execution is lost. These are not periodic — they fire at most once each per session lifecycle.

30. **Invalidate `exactWakeTimer`, `seedTimeoutTimer`, and `windowStartTimer` in teardown paths** — `tearDownMonitoringSession()`, `stopMonitoring()`, `tearDownMonitoringWithoutCompletion()` must invalidate all three timers. Remove all `wakeCheckTimer` invalidation calls (the timer no longer exists).

31. **Remove degraded-mode timer restart logic** — The `didChangeTo` delegate (~line 1278) and `didFailWithError` delegate (~line 1310) no longer need to restart any timer when switching to degraded mode. The one-shot exact-wake timer is already scheduled for the correct time, the seed-timeout timer handles its own concern, and sample-driven evaluation continues to work regardless of mode.

---

## Issue 4: Residual Issues

### 4a: Re-arming from background after wake completion

**Problem**: `cleanUpAfterCompletedWake()` (line 556) calls `schedulesDidUpdate()` which evaluates and tries to arm the next day's wake. At 7:31:03, it successfully calls `WKExtendedRuntimeSession.start(at:)` for tomorrow's 7:05am, but at 7:31:04 watchOS invalidates it: "The app must be active and before applicationWillResignActive to start or schedule a WKExtendedRuntimeSession."

**Root cause**: `WKApplication.shared().applicationState` returns `.active` during extended runtime execution, so the existing `applicationState` guard at line 456 passes. But watchOS has a stricter internal precondition for scheduling new extended runtime sessions — it requires true foreground, not just extended-runtime-active. Adding the same `applicationState` check inside `scheduleAlarmSession()` would also pass and change nothing.

**Fix**: The `isSceneActive` flag (Cross-Cutting section) solves this. During extended runtime callback execution, `isSceneActive` is `false` (no scene phase change occurred). `schedulesDidUpdate()` still runs — it evaluates the next occurrence and reaches the `isSceneActive` guard (Step S4, replacing the `applicationState` check at line 456). Since `isSceneActive` is false, it takes the inactive-app path: persists the `PendingWake` via `equivalentPersistedPendingWake` / `restorePendingWakeState`, or falls through to `armingState = .needsForegroundToArm`. No `WKExtendedRuntimeSession` is created. No `start(at:)` is called. No zombie session. No error log.

**Why this still persists tomorrow's wake**: The inactive-app path at line 458-476 checks for an `equivalentPersistedPendingWake`. Since `cleanUpAfterCompletedWake()` called `clearSchedulerState(clearPersistedWake: true)` (line 568) before `schedulesDidUpdate()`, there's no equivalent persisted wake to restore. It falls through to line 478-489: `armingState = .needsForegroundToArm`. Tomorrow's wake is NOT persisted in this path — it's the `scheduleAlarmSession()` path that does persistence.

**This means we need an additional change**: In the `needsForegroundToArm` branch (line 478-489), persist the `PendingWake` so recovery works — but use a distinct persisted state so background reevaluation doesn't promote it to `.armed`.

#### SmartAlarmScheduler.swift

32. **No additional Issue 4a changes to `scheduleAlarmSession()` itself beyond Step 11a.** The `isSceneActive` replacement of the `applicationState` guard (Step S4) prevents `scheduleAlarmSession()` from being reached during background execution. No zombie `WKExtendedRuntimeSession` is created.

32a. **Add a `isSessionScheduled` flag to the persisted wake record.** Extend `SmartWakePendingWakeRecord` with a new stored property:
```swift
var isSessionScheduled: Bool
```
Adding a custom `init(from:)` to a struct suppresses Swift's synthesized memberwise initializer. Since `SmartAlarmScheduler.savePendingWakeRecord(for:)` (~line 993) constructs the record via memberwise init, both initializers must be provided explicitly:

**Explicit memberwise initializer:**
```swift
init(
    schedule: WatchScheduleSnapshot,
    wakeUpTime: Date,
    windowStart: Date,
    baselineStart: Date,
    scheduledSessionStart: Date,
    savedAt: Date,
    isSessionScheduled: Bool = true
) {
    self.schedule = schedule
    self.wakeUpTime = wakeUpTime
    self.windowStart = windowStart
    self.baselineStart = baselineStart
    self.scheduledSessionStart = scheduledSessionStart
    self.savedAt = savedAt
    self.isSessionScheduled = isSessionScheduled
}
```
The `= true` default preserves source compatibility — existing call sites at line 993 that don't pass `isSessionScheduled` get `true` automatically. Only the `needsForegroundToArm` branch (Step 32b) passes `false` explicitly.

**Custom decoder for backward compatibility:**
```swift
private enum CodingKeys: String, CodingKey {
    case schedule
    case wakeUpTime
    case windowStart
    case baselineStart
    case scheduledSessionStart
    case savedAt
    case isSessionScheduled
}

init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schedule = try container.decode(WatchScheduleSnapshot.self, forKey: .schedule)
    wakeUpTime = try container.decode(Date.self, forKey: .wakeUpTime)
    windowStart = try container.decode(Date.self, forKey: .windowStart)
    baselineStart = try container.decode(Date.self, forKey: .baselineStart)
    scheduledSessionStart = try container.decode(Date.self, forKey: .scheduledSessionStart)
    savedAt = try container.decode(Date.self, forKey: .savedAt)
    isSessionScheduled = try container.decodeIfPresent(Bool.self, forKey: .isSessionScheduled) ?? true
}
```
The explicit `CodingKeys` keeps the custom decoder compile-ready and preserves synthesized `Encodable` behavior with the same field names. The `?? true` default means any existing record (which was always saved from `scheduleAlarmSession()`) correctly decodes as having a scheduled session. Without this, `loadPendingWakeRecord()` (line 32) would return `nil` via `try?` and overnight recovery would silently fail after update.

`scheduleAlarmSession()` persists with `isSessionScheduled: true` (the existing path). The `needsForegroundToArm` branch persists with `isSessionScheduled: false`.

32b. **Modify the `needsForegroundToArm` branch (~line 478-489)** — After setting `armingState = .needsForegroundToArm(wakeUpTime: wakeUpTime)`, persist the pending wake with the new flag:
```swift
pendingSchedule = nextWake
currentSessionScheduleID = nextSchedule.id
currentSessionWakeTime = wakeUpTime
savePendingWakeRecord(for: nextWake, isSessionScheduled: false)
```
This ensures process-kill recovery works — the persisted record survives — without claiming a session exists.

32c. **Modify the inactive-app branch (~line 458-476)** — `equivalentPersistedPendingWake` finds matching records regardless of `isSessionScheduled`. But the branch that currently sets `armingState = .armed(...)` (line 466) must now check the record's `isSessionScheduled` flag:
- If `isSessionScheduled == true` → set `.armed(...)` as before (a real session was scheduled before the process was killed; the session may fire via `WKExtensionDelegate.handle(_:)` recovery)
- If `isSessionScheduled == false` → set `.needsForegroundToArm(wakeUpTime: record.wakeUpTime)` (the wake was saved from a prior `needsForegroundToArm` branch; no session was ever scheduled, so `.armed` would be a lie)

This prevents the feedback loop: background reevaluation → finds persisted record → `restorePendingWakeState` → `.armed` → UI shows "Armed" with no session backing it.

32d. **Patch the pre-WCSession-hydration restore path (lines 322-340)** — This is a separate cold-start path that fires when `!sessionManager.hasLoadedInitialScheduleContext` and a persisted wake record exists. It currently unconditionally sets `armingState = .armed(...)` for any persisted record, regardless of `isSessionScheduled`. If a wake was persisted with `isSessionScheduled: false` (from the `needsForegroundToArm` branch, Step 32b), this path would claim it's `.armed` — a lie, since no `WKExtendedRuntimeSession` was ever scheduled.

After `restorePendingWakeState(from: record, ...)`, check `record.isSessionScheduled`:
```swift
if record.isSessionScheduled {
    armingState = .armed(
        wakeUpTime: record.wakeUpTime,
        monitoringStart: record.baselineStart
    )
} else {
    armingState = .needsForegroundToArm(wakeUpTime: record.wakeUpTime)
}
```
Note: `SmartWakeArmingState.needsForegroundToArm` carries an associated `wakeUpTime` value so the UI can show when the pending wake is for, even though no session backs it yet. Step 32b and Step 32c must also use the associated-value form: `.needsForegroundToArm(wakeUpTime: wakeUpTime)`.

The rest of the branch (error clearing, log message, early return) stays the same. This is the same pattern as Step 32c but applied to the pre-hydration cold-start path.

### 4b: Watch HomeKit "Missing entitlement for API"

**Problem**: Watch-local HomeKit fallback failed with "Missing entitlement for API" on both lights at 07:30:11 on March 19. The watch entitlements file (`Lights_Timer_Watch.entitlements`) correctly includes `com.apple.developer.homekit = true`.

**This is NOT a pure provisioning issue.** The same build successfully wrote HomeKit characteristics from the watch during a manual test at 22:37 on March 18 (smartwake-runtime.log line 34: "Starting local watch fallback for 'Wake Up' reason=manual test"). The only difference: the successful write was from foreground (user-initiated test), the failure was during extended runtime background execution at 07:30. This strongly suggests watchOS restricts HomeKit characteristic writes during `WKExtendedRuntimeSession` execution, not that the entitlement is misconfigured.

**Investigation steps (must be completed before relying on the watch fallback path):**
1. **Confirm the foreground/background hypothesis**: Run a manual HomeKit write test from the watch while in extended runtime session (not just background — specifically during the alarm callback). Compare against the same write from true foreground.
2. **Check Apple documentation**: Search for any documented restrictions on HomeKit writes during `WKExtendedRuntimeSession` or `workout-processing` background modes.
3. **Test with active workout session**: If the proactive workout (Issue 1) keeps the app alive via `workout-processing` mode, do HomeKit writes succeed from that context? This would determine whether the proactive workout fix also fixes the watch fallback path.
4. **Fallback strategy if confirmed**: If HomeKit writes are genuinely blocked during background/extended-runtime execution on watchOS, the watch-local HomeKit fallback is unreliable as a safety net. The phone-side fallback scene (`LT_<shortID>_fallback`) becomes the only reliable backstop, which increases the importance of phone reachability.

**This is tracked as a blocker for the watch-local fallback path, not a side investigation.** Even with Issues 1-3 fixed, the graceful degradation story depends on this path working. If it doesn't, the "phone unreachable → watch handles lights" chain is broken.

**Degradation matrix after Issues 1-3 are fixed:**

| Scenario | Outcome |
|----------|---------|
| Proactive workout survives + phone reachable | Full smart wake (best case) |
| Proactive workout dies + phone reachable | Degraded HR + phone ramp (same as today but with better logging) |
| Proactive workout survives + phone unreachable + watch HomeKit works | Watch-local ramp (untested in extended-runtime context) |
| Proactive workout survives + phone unreachable + watch HomeKit blocked | **Fallback scene snap-on only** — no gradual ramp |
| Process evicted overnight | Same as today — degraded mode, fallback scene backstop |

The Issue 4b investigation determines whether row 3 is achievable. If watch HomeKit is confirmed blocked during extended runtime, the watch-local fallback code (`scheduleDeferredLocalLightFallback` / `startLocalLightFallback`) is effectively dead code in production, and the fallback scene is the only non-phone safety net. If confirmed, this must be documented as a Known Limitation in CLAUDE.md, not left as an open investigation.

---

## Verification

1. **Prerequisite spike (HARD GATE)**: Run the no-builder workout session test on a physical watch (see Prerequisite section). Do not proceed with Issue 1 implementation until the spike result is known. If it fails, choose Option A (discardWorkout) or Option B (accept artifact) and validate that path before proceeding.
2. **Issue 4b investigation (BLOCKER)**: Complete the HomeKit background write investigation before relying on the watch fallback path in any verification step.
3. **Build check**: `xcodebuild -target 'Lights Timer Watch App' -sdk watchsimulator26.2 build CODE_SIGNING_ALLOWED=NO`
4. **Proactive workout timing**: Arm an alarm >10h before monitoring start → verify proactive workout does NOT start (log shows "Deferring proactive workout start"). Return to foreground within 10h of monitoring → verify proactive workout starts on that visit.
5. **Proactive workout lifecycle**: Arm within 10h of monitoring → verify "Workout Session (overnight)" shows in diagnostics. If the spike passed (no-builder path) or Option A (`discardWorkout()`) was selected, verify no `.other` workout appears in Health app. If Option B (accept artifact) was selected, verify the overnight `.other` workout behavior matches the product decision instead of treating it as a failure.
6. **Proactive workout idempotency**: Trigger `schedulesDidUpdate()` twice in rapid succession (simulating the double-evaluation from WatchAppServices + LightsTimerWatchApp) → verify `preStartWorkoutSession()` is called only once (second call logs "Proactive workout already running — skipping").
7. **Proactive workout — never-prompted user**: Reset HealthKit authorization (fresh install or Settings reset) → arm alarm within 10h → verify proactive workout is NOT started (log shows "HealthKit prompt not completed"). After tapping "Grant Health Access" and granting → verify the button path triggers `alarmScheduler.onAppForeground()` and proactive workout starts immediately, without requiring a leave/re-enter foreground cycle.
7a. **Two-flag correctness after denial**: Deny HealthKit authorization → verify `isHealthKitAuthorized = true` (prompt completed) and `hasConfirmedHRAccess = false` (probe returned no data). Verify "Grant Health Access" button is hidden (prompt already completed — re-prompting is a no-op). Verify proactive workout IS allowed to start (gated on `isHealthKitAuthorized`, not `hasConfirmedHRAccess`).
7b. **hasConfirmedHRAccess upgrade + phone resend (reachable)**: With phone reachable: watch has authorization granted but no recent HR data → verify `hasConfirmedHRAccess = false` after launch probe → phone shows "Waiting for heart rate data from Apple Watch". Start proactive workout → once live HR sample arrives → verify `hasConfirmedHRAccess` upgrades to `true` (log shows "HR access confirmed via live sample") AND phone receives `sendHeartRateStatus(active: true)` via `sendMessage` → phone shows "Heart rate data active on Apple Watch".
7b2. **hasConfirmedHRAccess upgrade + phone resend (unreachable)**: With phone asleep/unreachable: same as 7b but verify `sendHeartRateStatus` falls back to `transferUserInfo` instead of dropping the update. Wake phone → verify queued `transferUserInfo` is delivered → phone updates to "Heart rate data active on Apple Watch".
7b3. **Renamed protocol wire stability**: Verify `SmartWakePermissionStatus.heartRateDataActive` encodes to JSON key `healthKitAuthorized` (via CodingKeys mapping). Verify an old-format payload (`{"healthKitAuthorized": true, "watchConnected": true}`) decodes correctly. Verify a new-format payload also uses the same wire key, so mixed-version phone/watch pairs are safe.
7c. **Two-flag correctness after grant**: Grant HealthKit authorization on a watch with recent HR history → verify `isHealthKitAuthorized = true` AND `hasConfirmedHRAccess = true` after launch.
7d. **Phone-side status text**: Deny HealthKit authorization → verify phone shows "Waiting for heart rate data from Apple Watch" (not "Not authorized"). Grant authorization with HR history → verify phone shows "Heart rate data active on Apple Watch".
8. **Monitoring reuse path**: (Requires physical watch) Arm alarm, let extended runtime fire → verify log shows "Reusing proactive workout session" and HR samples arrive significantly more frequently than passive ~5min intervals.
9. **Proactive workout death before monitoring starts**: Simulate a proactive workout ending just as `startMonitoring()` enters → verify the delegate does NOT misclassify it as a monitoring failure (because `isMonitoringActive` is set AFTER workout setup per Step 7a). Verify Step 9a branch matches (proactive, not monitoring-startup).
9a. **Monitoring startup duplicate prevention**: Simulate two rapid `schedulesDidUpdate()` calls while `startMonitoring()` is in its async workout setup gap → verify the second call is blocked by `isMonitoringStartupInProgress` (log shows "Ignoring duplicate startMonitoring — startup already in progress" or scheduler-level equivalent). Verify no duplicate workout sessions, HR queries, or timers.
9b. **Seed survival during startup gap**: Start monitoring where the historical seed completes before the workout setup resolves (i.e., while `isMonitoringStartupInProgress = true` but `isMonitoringActive = false`) → verify the seed is NOT discarded (the `guard isMonitoringActive || isMonitoringStartupInProgress` passes). Verify seed data appears in the heuristic engine.
9c. **Monitoring-origin workout death during startup gap (March 19 scenario)**: Start monitoring without a proactive session (fallback to `startWorkoutSession()`). Simulate the workout delegate firing `.ended` with "cannot start while in background" during the `await beginCollection()` suspension (i.e., `isMonitoringStartupInProgress = true`, `isMonitoringActive = false`, `isProactiveWorkoutRunning = false`) → verify Step 9b marks the degraded startup result, Step 7c consumes it after the await resolves, dead workout state is torn down, and `startDegradedMonitoring()` is entered. This is the exact failure from March 19 that the plan must not regress.
9d. **Session loss during monitoring startup gap**: Simulate extended runtime session invalidation while `isMonitoringStartupInProgress = true` but `isMonitoringActive = false` → verify `didInvalidateWith` delegate (Step 13b) recognizes the startup-in-progress state → forces a last-chance wake check via `forceImmediateWakeCheck()` → calls `tearDownMonitoringWithoutCompletion()` → resets both `isMonitoringActive` and `isMonitoringStartupInProgress`. No orphaned half-started monitoring state.
9e. **Session expiry during monitoring startup gap**: Same as 9d but for `extendedRuntimeSessionWillExpire` (Step 13a). Verify the new branch fires before the existing "not monitoring" branch and forces a wake check.
9f. **forceImmediateWakeCheck bypass**: At exact wake time with `isMonitoringStartupInProgress = true` but `isMonitoringActive = false`, verify `forceImmediateWakeCheck()` still force-fires (bypasses the `isMonitoringActive` guard for the `now >= wakeUpTime` path).
10. **Sample-driven evaluation**: Verify that heuristic evaluations appear in the log only: (a) once at monitoring startup (the intentional one-shot startup evaluation per Step 28), (b) immediately after "Heart-rate sample" or "Historical seed" log entries, (c) once ~30s after monitoring start (seed-timeout timer, Step 24a), (d) at exact wake time via the one-shot timer, (e) once at wake-window boundary (window-start timer, Step 24b), or (f) on session-loss emergency checks from `forceImmediateWakeCheck()` (at most once per expiry/invalidation event). There should be NO periodic 10-second evaluation spam between samples.
11. **Seed timeout**: In degraded mode with no seed arriving, verify baseline freezes ~30s after monitoring start (seed-timeout timer fires and `freezeBaselineIfNeeded()` detects the timeout). Before this fix, the periodic 10-second timer served this role.
12. **Query bounding**: Verify no future-dated samples appear in the log (filtered at HealthKit level).
13. **UUID deduplication**: With proactive workout providing dense overnight data, verify no duplicate samples at the seed/live query boundary (~07:05). Check that `seenSampleUUIDs` is cleared on teardown.
14. **Empty-batch guard**: Inject a batch of only future-dated samples → verify no `checkForWakeTrigger()` call and no `lastHRSampleDate` update.
14a0. **Stale monitoring-origin session cleanup in startMonitoring()**: Start monitoring without a proactive session but with a dead monitoring-origin `workoutSession` still referenced (e.g., from a prior crashed monitoring attempt) → verify the unconditional stale-cleanup block in Step 7b fires → `endWorkoutSession()` tears it down → fresh `startWorkoutSession()` proceeds. Verify no orphaned dead session.
14a. **Stale-session cleanup in preStartWorkoutSession()**: Simulate an overnight proactive workout death (delegate fires `.ended`, Step 9 resets boolean flags, but `workoutSession` remains non-nil) → on next foreground visit, verify `preStartWorkoutSession()` logs "Cleaning up stale workout session reference before proactive start" → creates a fresh session successfully → no orphaned dead session reference.
14b. **Log source differentiation**: Start monitoring → verify initial anchored query batch logs as `"Heart-rate sample (initial-query)"` and subsequent real-time hardware readings log as `"Heart-rate sample (live)"`. Verify the consolidated future-date warning (Step 18) includes the source tag.
15. **Cleanup paths — cancelAlarmSession**: With a proactive workout running and monitoring NOT active: (a) disable the schedule → verify `cancelAlarmSession(isRescheduling: false)` calls `stopProactiveWorkout()` and no orphaned workout remains; (b) delete the schedule → same; (c) change to a different schedule → same. Verify `rescheduleAlarmSession()` does NOT stop the proactive workout (passes `isRescheduling: true`).
15a. **Cleanup paths — system invalidation**: Let the system invalidate the extended runtime session externally (not via `cancelAlarmSession`) → verify `didInvalidateWith` delegate fires and calls `stopProactiveWorkout()` as secondary safety net.
15b. **Seed timeout with empty/noisy seed**: Start monitoring with an empty HealthKit store (no historical HR data). Verify `seedHistoricalHeartRateSamples` returns 0 usable samples → heuristic stays in `awaitingHistoricalSeed = true` → `seedTimeoutTimer` is NOT cancelled → timer fires at ~30s → `freezeBaselineIfNeeded()` clears `awaitingHistoricalSeed` → baseline proceeds to freeze. Without this fix, the heuristic would be stranded until force-fire.
16. **Post-wake re-arm via isSceneActive**: After wake completion at ~07:31, verify `schedulesDidUpdate()` runs but hits the `isSceneActive == false` path → logs `needsForegroundToArm` → persists tomorrow's wake with `isSessionScheduled: false` (Step 32b). No `WKExtendedRuntimeSession` created. No error log.
16a. **needsForegroundToArm persistence — no false `.armed` (inactive-app path)**: After Step 16 persists a `isSessionScheduled: false` record, simulate a background reevaluation (WCSession delivery) → verify `equivalentPersistedPendingWake` finds the record → `isSessionScheduled == false` → sets `armingState = .needsForegroundToArm`, NOT `.armed`. UI shows "Needs foreground to arm", not "Armed".
16a2. **needsForegroundToArm persistence — no false `.armed` (cold-start path)**: Simulate a cold launch with a `isSessionScheduled: false` persisted record before WCSession hydration completes (i.e., `!sessionManager.hasLoadedInitialScheduleContext`) → verify the pre-hydration restore path (Step 32d) sets `armingState = .needsForegroundToArm`, NOT `.armed`.
16b. **needsForegroundToArm → foreground transition**: After 16a, bring the app to foreground → verify `isSceneActive = true` → `schedulesDidUpdate()` reaches `scheduleAlarmSession()` → session is created → `isSessionScheduled: true` persisted → `armingState = .armed`. Next foreground visit arms cleanly.
17. **isSceneActive correctness**: Verify `isSceneActive` is `true` during foreground app usage (including cold launch), `false` after app goes to background, `false` during extended runtime callbacks, and `false` during WCSession background delivery.
18. **isSceneActive cold launch (active path)**: Cold-launch the watch app where `.task` runs after `scenePhase` is already `.active` → verify `onAppForeground()` is called → alarm arms correctly on first launch.
19. **isSceneActive cold launch (inactive path)**: Cold-launch the watch app where `.task` runs while `scenePhase` is still `.inactive` → verify `.task` defers evaluation (log shows "Deferring schedule evaluation") → verify `.onChange` fires `.active` shortly after → `onAppForeground()` runs → alarm arms correctly. No transient `needsForegroundToArm` flash in the UI.
20. **Exact-wake backstop**: In degraded mode, verify force-fire happens within 1 second of wake time via the one-shot timer.
20a. **Window-start timer**: Start monitoring 2 minutes before the wake window with a high-confidence HR sample arriving during the pre-window buffer → verify `shouldTrigger(inWakeWindow: false)` returns false for the sample-driven call → verify the window-start timer fires at exactly `windowStartTime` → `shouldTrigger(inWakeWindow: true)` re-evaluates and triggers. Without the window-start timer, the trigger would be delayed until the next HR sample.
20b. **Window-start timer skip**: Start monitoring inside the wake window (e.g., "Already inside the monitoring period" path) → verify `windowStartTimer` is NOT scheduled (window already passed). The startup `checkForWakeTrigger()` call handles the evaluation.
21. **Full overnight test**: Arm before sleep → verify proactive workout starts → verify frequent HR data during wake window → verify heuristic triggers before exact wake time.
22. **Background schedule delivery**: Receive a WCSession schedule update while in background with an equivalent armed wake → verify proactive workout is NOT started (`isSceneActive` is false).
23. **Persisted wake record migration**: Save a wake record using the current schema (without `isSessionScheduled`), then update the app to include the new field → verify `loadPendingWakeRecord()` decodes the old record successfully with `isSessionScheduled == true` (backward-compatible default). Verify no `nil` return from the decoder.

## Critical Files
- `Lights Timer Watch App/Services/SmartWakeSessionController.swift` — HealthKit auth fix (Steps 0a-0e, 0e-wire), proactive workout with stale-session cleanup (Steps 1-10), monitoring startup race prevention (Step 7a `isMonitoringStartupInProgress`), `forceImmediateWakeCheck()` bypass for startup gap (Step 13a), HR filtering + log source differentiation (Steps 16-21, 18b), timer replacement + window-start timer (Steps 22-31, 24b)
- `Lights Timer Watch App/Services/SmartAlarmScheduler.swift` — Foreground detection (Steps S1-S5), proactive workout wiring (Steps 11-13, cancelAlarmSession isRescheduling guard), session-loss startup-gap handling (Steps 13a-13b), re-arm fix (Steps 32, 32a-32d)
- `Lights Timer Watch App/Services/WatchAppServices.swift` — onHRAccessConfirmed callback wiring (Step 0e-wire)
- `Lights Timer Watch App/Services/SmartWakePendingWakeStore.swift` — `isSessionScheduled` field on `SmartWakePendingWakeRecord` (Step 32a)
- `Lights Timer Watch App/LightsTimerWatchApp.swift` — Scene phase tracking (Steps S6-S7), phone permission source fix (Step 0f)
- `Lights Timer Watch App/Views/WatchRootView.swift` — UI (Steps 0g, 14-15)
- `Lights Timer Watch App/Models/SmartWakeMessage.swift` — `SmartWakePermissionStatus` rename: `healthKitAuthorized` → `heartRateDataActive` + wire-key-stable `CodingKeys` mapping (Step 0f-rename)
- `Lights Timer/Models/SmartWakeMessage.swift` — Same rename (duplicated file, Step 0f-rename)
- `Lights Timer Watch App/Services/WatchSessionManager.swift` — `sendPermissionStatus(authorized:)` → `sendHeartRateStatus(active:)` (Step 0f-rename)
- `Lights Timer/Services/WatchConnectivityService.swift` — Updated handler call site for renamed method (Step 0f-rename)
- `Lights Timer/Services/HealthKitAuthorizationService.swift` — Renamed `updateFromWatch(heartRateActive:)` + `isHeartRateActiveOnWatch` + updated status text (Steps 0f-rename, 0f-ui)
- `Lights Timer/ContentView.swift` — Updated environment read for renamed property (Step 0f-rename)
- `CLAUDE.md` — Documentation update: Known Limitations section (add HomeKit background restriction if confirmed by Issue 4b investigation) AND Smart Wake domain workflow section (update to reflect proactive workout lifecycle, sample-driven evaluation model, and changed timer architecture). CLAUDE.md serves as the AGENTS.md for this repo, so both the domain workflows and the known limitations live in the same file.
