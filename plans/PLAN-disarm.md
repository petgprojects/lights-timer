# Plan 2: Watch-Side Disarm with Phone Ack

## Context

This plan adds a watch-side "Disarm" action that cancels an armed Smart Wake occurrence and coordinates with the phone to remove the HomeKit fallback scene. It depends on the bug fixes in PLAN-bugfixes.md being implemented first — specifically the `isSceneActive` foreground detection (Cross-Cutting section) and the proactive workout lifecycle (Issue 1).

**Why this is separate from the bug fixes:** The disarm feature is a net-new UX capability, not a fix for an observed failure. Shipping it atomically with the session/query/timer fixes would block the bug fixes on the most complex and least-tested part of the plan. The bug fixes are independently valuable and testable.

---

## Prerequisites

- **PLAN-bugfixes.md implemented**: `isSceneActive`, proactive workout, `stopProactiveWorkout()`, sample-driven evaluation, and the re-arm fix (Steps S1-S7, 1-15, 16-32a) are all in place.
- **`completedWakeOccurrence` upgraded to a set**: The existing scheduler tracks a single `completedWakeOccurrence` (`SmartAlarmScheduler.swift` line 53) and skips only that one occurrence in `nextWakeTime()` (line 869). Disarming occurrence A then B would overwrite A's record, letting A become eligible again and re-arm. This must be upgraded before overlapping disarms are safe.

---

## Step D1: Upgrade `completedWakeOccurrence` to a Set

**Problem:** `SmartAlarmScheduler.swift` line 53 declares `private var completedWakeOccurrence: (scheduleID: UUID, wakeUpTime: Date)?` — a single optional. Line 869-873 skips only this one occurrence in `nextWakeTime()`. If occurrence A is completed/disarmed and then occurrence B is also disarmed before A prunes, overwriting the singleton lets A become re-eligible.

**Fix:**

#### SmartAlarmScheduler.swift

D1a. Replace `private var completedWakeOccurrence: (scheduleID: UUID, wakeUpTime: Date)?` with:
```swift
private var completedWakeOccurrences: [(scheduleID: UUID, wakeUpTime: Date)] = []
```

D1b. Update `nextWakeTime(for:)` (~line 869) to check the array:
```swift
if completedWakeOccurrences.contains(where: {
    $0.scheduleID == schedule.id && $0.wakeUpTime == wakeUpTime
}) {
    continue
}
```

D1c. Update `pruneCompletedWake()` (~line 584) to prune all entries older than 2 hours:
```swift
completedWakeOccurrences.removeAll { occurrence in
    occurrence.wakeUpTime.addingTimeInterval(2 * 3600) < now
}
```

D1d. Update all call sites that set/clear `completedWakeOccurrence`:
- `markOccurrenceCompleted()` → append to `completedWakeOccurrences`
- `clearSchedulerState()` → clear the array
- Any existing checks for `completedWakeOccurrence != nil` → check `completedWakeOccurrences.contains(...)`

#### SmartWakePendingWakeStore.swift

D1e. Upgrade the persistence to support the array:
- `saveCompletedWakeOccurrence()` → `saveCompletedWakeOccurrences(_ occurrences: [(scheduleID: UUID, wakeUpTime: Date)])`
- `loadCompletedWakeOccurrence()` → `loadCompletedWakeOccurrences() -> [(scheduleID: UUID, wakeUpTime: Date)]`
- `clearCompletedWakeOccurrence()` → `clearCompletedWakeOccurrences()`
- UserDefaults key remains `smartWakeCompletedOccurrence` (or rename to `smartWakeCompletedOccurrences`)
- `SmartAlarmScheduler.init` loads the array on startup

**Bounded size:** The array is bounded by the number of active schedule days (at most 7) × the prune window (2 hours). Realistically 1-2 entries at a time. No cap needed.

---

## Step D2: Add `disarmUpcomingWake()` on the Watch

#### SmartAlarmScheduler.swift

D2a. **Add public method `disarmUpcomingWake()`** — A dedicated public API for the UI layer. Disarm skips this occurrence on the watch immediately and sends a best-effort request to the phone to remove the HomeKit fallback scene. This is final for the specific occurrence and not reversible (re-arming the same occurrence would require toggling the schedule off and back on, or waiting for it to prune after 2 hours).

Encapsulates:
1. Read the pending wake's `(scheduleID, wakeUpTime)` and append it to `completedWakeOccurrences` + persist via `SmartWakePendingWakeStore`. This survives process relaunch so a recovered session doesn't re-arm the same disarmed wake. `nextWakeTime()` skips it. The record naturally prunes after 2 hours.
2. Call `sessionController.stopProactiveWorkout()` explicitly (per PLAN-bugfixes Step 12, this is a true teardown path).
3. `cancelAlarmSession(clearPersistedWake: true)` — handles the extended runtime session teardown and clears the persisted pending wake record.
4. Send a `disarmWake` message to the phone (see Step D3) so the phone removes its `LT_<shortID>_fallback` scene and suppresses recreation. Persist an unacked disarm record for this occurrence (see Step D5) so `phoneDisarmPending` becomes true.
5. Set `armingState = .noUpcomingWake`
6. Log the disarm.

**Phone-side disarm is best-effort.** If the phone is unreachable, the `disarmWake` message falls back to `transferUserInfo` which may arrive late — potentially after wake time, at which point the fallback scene has already fired. The watch UI surfaces this via a pending state (see Step D4) so the user knows the phone hasn't confirmed yet.

---

## Step D3: Add `disarmWake` Message Type and Phone-Side Handling

### Watch Side

#### SmartWakeMessage.swift (both copies)
- Add `WCMessageKey.disarmWake = "disarmWake"`
- Add `SmartWakeDisarmPayload: Codable` with `scheduleID: UUID` and `wakeUpTime: Date`

#### WatchSessionManager.swift
- Add `sendDisarmWake(scheduleID:wakeUpTime:)` using `sendMessage` (fallback `transferUserInfo`)

### Phone Side

#### WatchConnectivityService.swift
- Add `disarmWake` case in `handleMessage`

#### SmartWakeCoordinator.swift
- Wire to `handleDisarmWake(payload:)` which:
  1. **Validates occurrence freshness**: If `payload.wakeUpTime` is in the past (already expired), reject — send `disarmWakeAck` with `success: false, scenePending: false, reason: "stale occurrence"` immediately, then return. This prevents a delayed `transferUserInfo` delivery of a March 19 disarm from affecting March 20's scene. The rejection ack is important: without it, the watch's unacked disarm record would linger until the 2h prune. No occurrence-match check beyond freshness — `ScheduleEngine.nextOccurrence(for:)` (line 776) is purely calendar-based and does not skip disarmed occurrences, so it would reject valid overlapping disarms.
  2. If valid: persist the disarmed occurrence in `ScheduleEngine` (see Step D3c). If a sync is currently in flight (`isSyncing == true`), skip the immediate scene removal and defer the ack to the post-sync cleanup (see Step D3-sync). Otherwise, attempt `ScheduleEngine.removeSmartWakeFallbackScene(scheduleID:)`.
  3. **Branch on scene removal outcome**:
     - **Sync in flight** (`isSyncing == true`): Do NOT attempt immediate removal or send an ack yet. Defer to Step D3-sync.
     - **Scene removed successfully** (or no matching scene found — already gone): Send `disarmWakeAck` with `success: true, scenePending: false`.
     - **Scene removal failed** (HomeKit not ready, `removeActionSet` throws): Send `disarmWakeAck` with `success: false, scenePending: true, reason`. The disarmed occurrence is still persisted — `createScenesForSchedule()` will NOT recreate the scene on the next sync.

     **No separate retry tracking is needed for the non-racing case.** `syncBackgroundScenes()` (line 486) already calls `cleanupOldScenesAndTriggers()` (line 514) which wipes ALL `LT_`-prefixed scenes, then recreates only scenes for non-disarmed occurrences (gated by `isOccurrenceDisarmed()`). Any stale fallback scene is always deleted on the next full sync.

#### D3-sync: Handle disarms that arrive during an in-flight sync

There is a race between `syncBackgroundScenes()` and `handleDisarmWake()`. Both run on `@MainActor`, but `syncBackgroundScenes()` is `async` with multiple `await` suspension points (HomeKit calls at lines 560, 570, 609, etc.). A disarm can execute during any of these suspensions:

**The race scenario:**
1. `syncBackgroundScenes()` starts → `cleanupOldScenesAndTriggers()` deletes all `LT_` scenes
2. `createScenesForSchedule()` enters, passes `isOccurrenceDisarmed()` check (not yet disarmed), reaches `await addActionSet(...)` — suspends
3. `handleDisarmWake()` runs at the suspension point: persists disarmed occurrence, sees no scene, would send `success: true`
4. `createScenesForSchedule()` resumes — creates the scene
5. Watch cleared pending on a false `success: true`, but scene is live

**Fix — defer ack when `isSyncing`:**
- When `isSyncing == true`: persist the disarmed occurrence but do NOT attempt removal or send ack. Record the pending ack in `deferredDisarmAcks: [(scheduleID: UUID, wakeUpTime: Date)]` on `ScheduleEngine`.
- At the end of `syncBackgroundScenes()`, after the sync completes: for each deferred entry, attempt `removeSmartWakeFallbackScene()`, send the ack based on outcome, clear the entry.
- `deferredDisarmAcks` is in-memory only. If the phone restarts mid-sync, `isSyncing` resets and the next sync handles it via `isOccurrenceDisarmed()`. The watch's unacked disarm record survives.

#### D3c: Phone-side disarmed occurrence persistence

`ScheduleEngine` owns the persisted set of disarmed occurrences: `disarmedOccurrences: [(scheduleID: UUID, wakeUpTime: Date)]`, stored in UserDefaults. `ScheduleEngine` is the sole owner because it is the only consumer — `createScenesForSchedule()` must check the set during every sync. Pruned on each `syncBackgroundScenes()` call when `wakeUpTime + 2 hours` has passed.

- Add `ScheduleEngine.addDisarmedOccurrence(scheduleID:wakeUpTime:)` — persists to UserDefaults.
- Add `ScheduleEngine.isOccurrenceDisarmed(scheduleID:wakeUpTime:) -> Bool` — checked by scene creation.
- Add `ScheduleEngine.pruneDisarmedOccurrences()` — called at the top of `syncBackgroundScenes()`.
- Add `ScheduleEngine.removeSmartWakeFallbackScene(scheduleID:)` — finds and removes the `LT_<shortID>_fallback` action set and its timer trigger.

**Phone-side scene sync must honor disarmed occurrences.** `createScenesForSchedule()` (~line 578) currently always creates the fallback scene for smart wake schedules. After this change, before creating the fallback scene, check `isOccurrenceDisarmed(scheduleID: schedule.id, wakeUpTime: wakeUpTime)`. If yes, skip and log.

---

## Step D4: Add Disarm Ack and Watch-Side Pending State

### Phone Side

#### SmartWakeMessage.swift (both copies)
- Add `WCMessageKey.disarmWakeAck = "disarmWakeAck"`
- Add `SmartWakeDisarmAckPayload: Codable` with:
  - `scheduleID: UUID`
  - `wakeUpTime: Date` — occurrence-aware so the watch can match it to the correct unacked record
  - `success: Bool`
  - `scenePending: Bool` — distinguishes "rejected, nothing to worry about" from "accepted but scene still live"
  - `reason: String?`

#### SmartWakeCoordinator.swift
- Sends ack in all non-deferred cases:
  - `success: false, scenePending: false, reason: "stale occurrence"` — freshness rejection
  - `success: true, scenePending: false` — scene removed or already absent
  - `success: false, scenePending: true, reason` — operational HomeKit failure

### Watch Side

#### WatchSessionManager.swift
- Receives ack, matches to unacked disarm record by `(scheduleID, wakeUpTime)`, branches:
  - **`success == true`**: Remove matching record from persisted set. Disarm fully complete.
  - **`success == false, scenePending == false`** (stale rejection): Remove matching record. Phone definitively rejected — nothing pending.
  - **`success == false, scenePending == true`** (operational failure): Record remains. Scene still live. Watch shows pending warning. Clears at 2h prune.
  - **No matching record**: Log and ignore (already pruned).

**Known limitation:** `scenePending` is only truthful at ack time. The next `syncBackgroundScenes()` will clean up the stale scene, but no follow-up ack is sent. The watch pending warning may outlive the actual scene by up to one phone-foreground cycle. This errs conservative (false warning, never false clean) and self-clears at the 2h prune.

---

## Step D5: Persist Unacked Disarm State as an Occurrence-Keyed Set

The unacked disarm state must survive watch process restarts AND support overlapping disarms. After disarming occurrence A, the scheduler advances to B immediately (line 869 skips completed occurrences). The user can disarm B while A's ack is in flight. A singleton record would let A's delayed ack clear B's state.

#### SmartWakePendingWakeStore.swift
- Add `UnackedDisarmRecord: Codable` with `scheduleID: UUID` and `wakeUpTime: Date`.
- Add `saveUnackedDisarm(_ record: UnackedDisarmRecord)` — appends to persisted array under `smartWakeUnackedDisarms`. Deduplicates by `(scheduleID, wakeUpTime)`.
- Add `loadUnackedDisarms() -> [UnackedDisarmRecord]`
- Add `removeUnackedDisarm(scheduleID: UUID, wakeUpTime: Date)` — removes matching record. No-op if not found.
- Add `pruneUnackedDisarms()` — removes records where `wakeUpTime + 2h < now`. Called alongside `pruneCompletedWake()`.
- Add `clearAllUnackedDisarms()` — empties array. Full state reset only.

#### SmartAlarmScheduler.swift
- `phoneDisarmPending` as computed property:
  ```swift
  var phoneDisarmPending: Bool {
      !pendingWakeStore.loadUnackedDisarms().isEmpty
  }
  ```
- `unackedDisarmRecords` computed property for UI access.
- In `disarmUpcomingWake()`: call `saveUnackedDisarm()`.
- On ack with `success == true` or `scenePending == false`: call `removeUnackedDisarm()`.
- On `pruneCompletedWake()`: also call `pruneUnackedDisarms()`.

**Why an array:** Bounded at ~7 entries max. `Codable` array in UserDefaults is simpler than a keyed dictionary. Linear scan is trivially fast.

**Why computed:** UserDefaults reads are fast. Computed properties are always consistent with persisted state. No synchronization bugs.

---

## Step D6: Watch UI

#### WatchRootView.swift

D6a. **Add disarm button** — When `armingState == .armed` (not yet monitoring), show a "Disarm" button that calls `SmartAlarmScheduler.disarmUpcomingWake()`. This is needed because the proactive workout runs overnight and there was previously no watch UI to cancel an armed (but not monitoring) alarm.

D6b. **Phone fallback pending banner** — Shown **independently of `armingState`**, not gated on `.noUpcomingWake`. After disarming, the scheduler advances to the next occurrence, so `armingState` typically moves to `.armed` within seconds. If gated on `.noUpcomingWake`, the warning would flash and vanish.
- When `phoneDisarmPending` is true: show a persistent banner for each `unackedDisarmRecords` entry, e.g., "Phone fallback pending for 7:30 AM".
- Each banner's time comes from `UnackedDisarmRecord.wakeUpTime`, formatted time-only.
- Individual banners disappear as matching acks arrive or `pruneUnackedDisarms()` clears them.

---

## Verification

1. **Build check**: `xcodebuild -target 'Lights Timer Watch App' -sdk watchsimulator26.2 build CODE_SIGNING_ALLOWED=NO` and `xcodebuild -target 'Lights Timer' -sdk iphonesimulator26.2 build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO`
2. **Basic disarm**: Arm alarm → tap Disarm → verify proactive workout stops, `armingState` becomes `.noUpcomingWake`, completed occurrence is persisted, same occurrence is NOT re-armed on next evaluation.
3. **Disarm durability (watch)**: Disarm → force-kill watch app → relaunch → verify the same occurrence is NOT re-armed (completed wake occurrence persisted).
4. **Disarm durability (phone)**: Disarm with phone reachable → bring phone to foreground → verify `syncBackgroundScenes()` does NOT recreate the `LT_<shortID>_fallback` scene for the disarmed occurrence.
5. **Stale disarm rejection**: Arm March 20 wake → deliver stale March 19 disarm → verify phone sends `success: false, scenePending: false, reason: "stale occurrence"` → March 20 scene NOT deleted → watch clears the unacked record.
6. **Disarm ack success**: Disarm with phone reachable → verify `phoneDisarmPending` clears on `success: true` ack → clean UI.
7. **Disarm ack operational failure**: Disarm with phone reachable but HomeKit homes empty → verify `success: false, scenePending: true` → watch keeps pending warning → bring phone to foreground → `syncBackgroundScenes()` cleans scene → pending clears at 2h prune.
8. **Disarm without phone**: Disarm with phone unreachable → verify "(phone fallback pending)" → `phoneDisarmPending` true → phone processes queued `transferUserInfo` → ack clears pending.
9. **Disarm pending survives relaunch**: Disarm with phone unreachable → force-kill watch → relaunch → verify `phoneDisarmPending` still true → phone ack clears it.
10. **Disarm pending auto-prune**: Disarm with phone unreachable → wait for prune (wake time + 2h) → verify record pruned → `phoneDisarmPending` false.
11. **Pending warning survives re-arm**: Disarm today's 7:30 AM wake with phone unreachable → verify scheduler arms tomorrow → verify "(phone fallback pending for 7:30 AM)" still visible alongside armed state.
12. **Overlapping disarms (watch)**: Disarm A → scheduler advances → disarm B → verify both completed occurrences persisted → neither re-arms.
13. **Overlapping disarms (phone)**: Disarm A → phone persists A → disarm B → phone persists B → both block scene creation independently.
14. **Overlapping disarm acks**: Disarm A (phone unreachable) → disarm B → delayed ack for A with `success: true` → verify only A's unacked record removed, B's remains → `phoneDisarmPending` still true.
15. **Disarm during in-flight sync**: Trigger `syncBackgroundScenes()` → send disarm while `isSyncing` → verify disarmed occurrence persisted → no ack sent → sync completes → deferred cleanup runs → ack sent → watch clears pending only after deferred ack.

## Critical Files
- `Lights Timer Watch App/Services/SmartAlarmScheduler.swift` — `disarmUpcomingWake()`, `completedWakeOccurrences` set upgrade, `phoneDisarmPending` computed property (Steps D1, D2, D5)
- `Lights Timer Watch App/Services/SmartWakePendingWakeStore.swift` — Completed occurrences set persistence, unacked disarm persistence (Steps D1e, D5)
- `Lights Timer Watch App/Services/WatchSessionManager.swift` — `sendDisarmWake()`, ack handler (Steps D3, D4)
- `Lights Timer Watch App/Models/SmartWakeMessage.swift` — Disarm message types (Steps D3, D4)
- `Lights Timer/Models/SmartWakeMessage.swift` — Disarm message types, iPhone copy (Steps D3, D4)
- `Lights Timer/Services/WatchConnectivityService.swift` — Disarm handler (Step D3)
- `Lights Timer/Services/SmartWakeCoordinator.swift` — Disarm validation, ack send (Step D3)
- `Lights Timer/Services/ScheduleEngine.swift` — Disarmed occurrence persistence, scene-sync gating, deferred ack cleanup (Steps D3c, D3-sync)
- `Lights Timer Watch App/Views/WatchRootView.swift` — Disarm button, pending banners (Step D6)
- `CLAUDE.md` — Documentation update
