# AGENTS.md — Lights Timer

## Purpose
This is the complete operator map for both the iOS app and its watchOS companion.
A new agent should be able to trace any feature to its files, understand the execution model, and make changes without exploratory searches.

**When you change architecture, add/remove files, change build settings, or modify domain workflows, update this file in the same change.**

## Repo Identity
- Path: `/Users/petergelgor/Documents/projects/Lights Timer`
- Git repo: yes
- Xcode project: `Lights Timer.xcodeproj` (objectVersion 77, PBXFileSystemSynchronizedRootGroup)
- Targets: `Lights Timer` (iOS), `Lights Timer Watch App` (watchOS)

## Quick Start
- Open in Xcode: `open "Lights Timer.xcodeproj"`
- Build iOS (simulator): `xcodebuild -target 'Lights Timer' -sdk iphonesimulator26.2 build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO`
- Build watch (simulator): `xcodebuild -target 'Lights Timer Watch App' -sdk watchsimulator26.2 build CODE_SIGNING_ALLOWED=NO`
- Both targets together: build the iOS target; it embeds the watch app automatically
- Real-device testing required for HomeKit accessory discovery and HealthKit sensor data

## Stack And Build Settings
- SwiftUI + SwiftData, `@Observable` macro (not ObservableObject)
- iOS 26.2, watchOS 26.2, Swift 5.0, Xcode 26.2
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — every type/method is implicitly `@MainActor` unless marked `nonisolated`
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- Bundle IDs: `com.PeterGelgor.Lights-Timer` (iOS), `com.PeterGelgor.Lights-Timer.watchkitapp` (watch)
- Team: `39JCQY86NE`, automatic code signing
- Project uses `PBXFileSystemSynchronizedRootGroup` — all files under a synced directory are auto-included in that target. No manual source/resource phase management needed.

## File Structure (Authoritative)

### iOS Target: `Lights Timer/`
```
Lights_TimerApp.swift              App entry point, service wiring, environment injection
ContentView.swift                  Root view, scenePhase lifecycle, trigger processing

Models/
  DayOfWeek.swift                  Enum: Sun=1..Sat=7, Codable, letter/shortName
  LightSchedule.swift              @Model: SwiftData entity, all schedule fields + smart wake fields
  WatchScheduleSnapshot.swift      Codable mirror of LightSchedule for WCSession transfer
  SmartWakeMessage.swift           Codable message types + WCMessageKey constants + HapticPattern enum

Views/
  ChunkedLogTextView.swift         Chunked lazy log renderer for large iPhone/watch-imported log files
  ScheduleListView.swift           Schedule list, enable toggle, smart wake badge, debug trigger (swipe right), toolbar entry points for add + settings
  SettingsView.swift               iPhone settings screen with collapsible Phone Logs, Watch Logs, and Smart Wake Debug sections
  ScheduleDetailView.swift         Schedule editor form, smart wake toggle + window stepper + haptic pattern picker
  DayOfWeekSelector.swift          Circular day-of-week picker
  LightPickerView.swift            HomeKit light multi-select
  ColorPreferenceView.swift        Start/end color pickers + gradient preview
  PhoneLogArchiveView.swift        iPhone-side viewer/share UI for runtime + per-launch phone log files
  WatchLogArchiveView.swift        iPhone-side viewer/share UI for imported watch smart-wake log files

Services/
  HomeKitService.swift             @Observable NSObject, HMHomeManagerDelegate, light discovery + characteristic writes + onHomesUpdated retry hook + phone-side HomeKit runtime logging
  LightController.swift            @Observable, multi-light batch writes via HomeKitService + best-effort write summaries + persisted failure logging
  PhoneLogStore.swift              @Observable, persists an always-on iPhone runtime log plus per-launch log files in Application Support, mirrors app-generated phone logs to disk and console, and exposes metadata for in-app viewing/sharing
  ScheduleEngine.swift             @Observable, foreground timer execution + background HMActionSet/HMTimerTrigger scenes + smart wake ownership-commit ramp execution + HomeKit retry debug state + persisted phone logging for ramp/scene decisions
  WatchConnectivityService.swift   @Observable NSObject, WCSessionDelegate (iPhone side), caches latest schedule sync payload, suppresses unchanged app-context resends, retries after activation/watch-state changes, sends light-handoff acks, stages transferred watch log files immediately for import, and logs WCSession state/messages
  SmartWakeCoordinator.swift       @Observable, validates fresh watch triggers against the matching occurrence, keeps bounded handoff dedupe, decides phone vs watch light ownership, and logs trigger/handoff decisions to phone files
  HealthKitAuthorizationService.swift  @Observable, tracks watch health permission status (no direct HealthKit usage on iPhone) and logs watch-status changes to phone files
  WatchLogArchiveService.swift     @Observable, stores watch-transferred smart-wake log files in iPhone Application Support for in-app viewing/sharing and logs import results

Utilities/
  ColorInterpolation.swift         interpolateHSB() with hue wrapping, interpolateBrightness()

Lights_Timer.entitlements          HomeKit only (com.apple.developer.homekit)
Assets.xcassets/                   AppIcon, AccentColor
```

### watchOS Target: `Lights Timer Watch App/`
```
LightsTimerWatchApp.swift          @main App entry, schedule evaluation, monitoring lifecycle

Models/
  WatchScheduleSnapshot.swift      Codable mirror (duplicated from iOS — no shared target)
  SmartWakeMessage.swift           Codable message types (duplicated from iOS)

Views/
  ChunkedLogTextView.swift         Chunked lazy log renderer for large on-watch log files
  WatchRootView.swift              Status, schedule list, diagnostics, permission prompt, and log export shortcuts
  WatchLogArchiveView.swift        Watch-side viewer/share UI for the always-on runtime log plus saved smart-wake session logs

Services/
  WatchSessionManager.swift        @Observable NSObject, WCSessionDelegate (watch side), receives schedules + phone handoff acks, dedupes activation/runtime app-context delivery, sends triggers, and transfers immutable log snapshots to iPhone
  SmartWakeSessionController.swift @Observable NSObject, live HR monitoring + best-effort historical seeding, deferred watch-local HomeKit fallback modes, handoff tracking, and detailed smart-wake file logging
  SmartAlarmScheduler.swift        @Observable NSObject, WKExtendedRuntimeSession manager, proactive workout session evaluator, schedules overnight wake monitoring with `start(at:)`, evaluates proactive workout start on foreground entry, and prepares per-session log files once the next wake is known
  WakeHeuristicEngine.swift        @Observable, frozen pre-window HR baseline, confidence scoring, trigger decision, and detailed baseline/evaluation diagnostics for the log file
  SmartWakeLogStore.swift          @Observable, persists an always-on watch runtime log plus per-session smart-wake log files in Application Support, keeps recent log metadata, and tracks export status

Lights_Timer_Watch.entitlements    HealthKit + HomeKit
Lights-Timer-Watch-App-Info.plist  Watch Info.plist, NSHomeKitUsageDescription, WKBackgroundModes
Assets.xcassets/                   AppIcon, AccentColor
```

## Data Model

### LightSchedule (@Model — SwiftData)
| Field | Type | Purpose |
|-------|------|---------|
| id | UUID | Primary key |
| name | String | Display name |
| wakeUpHour, wakeUpMinute | Int | Wake time (24h) |
| activeDaysRaw | [Int] | Weekday raw values (Sun=1..Sat=7) |
| leadTimeMinutes | Int | How long before wake to start ramp |
| targetBrightness | Int | Final brightness 0-100 |
| startColorHue/Sat/Bri | Double | Ramp start color (HSB 0-1) |
| endColorHue/Sat/Bri | Double | Ramp end color (HSB 0-1) |
| startColorIsAdaptive | Bool | Use Adaptive Lighting instead of start color (default false) |
| endColorIsAdaptive | Bool | Use Adaptive Lighting instead of end color (default false) |
| isEnabled | Bool | Active toggle |
| lightIdentifiers | [String] | HomeKit accessory UUID strings |
| lightNames | [String] | Display names (parallel array) |
| usesSmartWake | Bool | Smart Wake enabled for this schedule |
| smartWakeWindowMinutes | Int | Smart wake window (default 30) |
| hapticPatternRaw | String | Haptic pattern for watch alarm ("gentle"/"pulse"/"heartbeat"/"alarm") |
| lastSmartWakeTriggerAt | Date? | Last smart wake fire time |
| createdAt | Date | Creation timestamp |

Computed: `activeDays: Set<DayOfWeek>`, `wakeUpTimeString`, `activeDaysSummary`, `skipColorWrites: Bool` (true when either color is adaptive)

### WatchScheduleSnapshot (Codable, Equatable)
Lightweight mirror of LightSchedule for WCSession transfer. Contains: id, name, wakeUpHour/Minute, activeDaysRaw, leadTimeMinutes, usesSmartWake, smartWakeWindowMinutes, targetBrightness, startColorHue/Sat/Bri, endColorHue/Sat/Bri, skipColorWrites, lightIdentifiers, lightNames, hapticPatternRaw. iPhone copy has `init(from: LightSchedule)` extension.

### SmartWakeTriggerPayload (Codable)
Watch→iPhone trigger: triggerID, scheduleID, triggerDate, confidence, heartRateAtTrigger?, motionLevel?, lightsHandledOnWatch? (`lightsHandledOnWatch` is now test-mode only)

### SmartWakeLightHandoffPayload (Codable)
iPhone→Watch ack: triggerID, scheduleID, phoneWillHandleLights, reason?

### SmartWakeSessionState (Codable)
Watch→iPhone state: `.idle`, `.monitoring`, `.triggered`, `.failed` + scheduleID? + message?

## Architecture: Service Graph And Data Flow

### App Initialization (`Lights_TimerApp.init`)
```
ModelContainer (created manually, shared with SmartWakeCoordinator)
PhoneLogStore ───────────────────→ ContentView / ScheduleListView / PhoneLogArchiveView
      ↓
HomeKitService → LightController → ScheduleEngine
                                        ↓
WatchConnectivityService ──────→ SmartWakeCoordinator(modelContainer:)
                                        ↓
HealthKitAuthorizationService
WatchLogArchiveService            (all injected as @Environment)
```
- `PhoneLogStore` is created first so iPhone runtime + per-launch file logging starts during app init, before the rest of the phone service graph begins emitting logs.
- `HomeKitService.onHomesUpdated` is wired here to call `ScheduleEngine.retryPendingBackgroundSync(modelContext:)` with a fresh `ModelContext` when HomeKit homes load after app init/background wake.
- `WatchConnectivityService.onWatchLogFileReceived` is wired here to `WatchLogArchiveService.importTransferredLog(from:metadata:)`, so transferred watch logs appear on the phone automatically.

### Lifecycle Entry (`ContentView.onChange(scenePhase: .active)`)
1. `scheduleEngine.onAppActive(modelContext:)` — checks active schedules + syncs background scenes
2. `smartWakeCoordinator.syncSchedulesToWatch(modelContext:)` — sends smart-wake schedules to watch
3. `smartWakeCoordinator.resetDailyState()` — purges stale per-day trigger tracking
4. Update health auth status from watch connectivity state

### Schedule Save (`ScheduleDetailView.save` → `ScheduleListView.syncEngine`)
1. SwiftData model insert/update
2. `scheduleEngine.onAppActive(modelContext:)` — re-syncs background scenes
3. `smartWakeCoordinator.syncSchedulesToWatch(modelContext:)` — pushes to watch

## Domain Workflows

### Normal Wake (usesSmartWake == false)
1. **Background**: `syncBackgroundScenes` creates `HMActionSet` scenes + `HMTimerTrigger` per minute step, named `LT_<shortID>_<step>`. Fires on HomeKit hub regardless of app state.
2. **Foreground**: `checkForActiveSchedules` detects in-progress window, starts 15-second `Timer.publish` for smooth direct writes via `LightController.applyToMultipleLights`. Smart wake schedules are **skipped** — they only trigger via the watch.
3. Progress calculated as `elapsed / total`, brightness and color interpolated linearly.
4. **Adaptive Lighting mode**: When `skipColorWrites` is true (either start or end color set to Adaptive), all hue/saturation writes are skipped in both foreground execution and background scenes. Only brightness + power are written, so HomeKit Adaptive Lighting on the bulb is not overridden. `LightController.applyToMultipleLights` accepts a `skipColor` parameter. The `ColorPreferenceView` shows per-color Adaptive toggles; when toggled, the color picker is hidden and the gradient preview shows a warm-to-cool approximation.

### Smart Wake (usesSmartWake == true)
1. **No gradual ramp**: Smart wake schedules do NOT create per-minute background scenes or trigger foreground timers. Only a single fallback scene (`LT_<shortID>_fallback`) is created at the exact wake time, snapping lights to full brightness if the watch never triggers.
2. iPhone sends `WatchScheduleSnapshot` array (including colors, `skipColorWrites`, `lightIdentifiers`, `lightNames`, and `hapticPatternRaw`) to watch via `WCSession.updateApplicationContext`. `WatchConnectivityService` caches the latest encoded payload, suppresses identical resends, and retries delivery only after WCSession activation/watch-state changes.
3. **Three-tier execution model** (proactive workout > extended runtime alarm > HomeKit fallback scene):
   - **Tier 1 — Proactive workout session**: When the watch app is in the foreground and a smart wake schedule is within 12 hours, `SmartAlarmScheduler.evaluateProactiveWorkout()` starts `HKWorkoutSession` immediately. The `workout-processing` background mode keeps the app alive indefinitely. A deferred `Timer` starts actual HR monitoring at `windowStart - 1h`. This is the happy path when the user opens the watch app before bed.
   - **Tier 2 — Extended runtime session**: `SmartAlarmScheduler` schedules `WKExtendedRuntimeSession.start(at:)` for `wakeTime - min(windowMinutes, 30) min`. This ensures the ~30-minute execution window always covers wake time, guaranteeing force-fire + haptics. If the proactive workout already started monitoring, this session becomes a no-op safety net.
   - **Tier 3 — HomeKit fallback scene**: The single `LT_<shortID>_fallback` scene at wake time snaps lights on if neither phone nor watch can own the wake.
4. `SmartAlarmScheduler` receives schedules (via `WatchSessionManager.onSchedulesUpdated`), evaluates the next relevant schedule, creates/reuses a persistent per-session watch log file for that wake, records the next wake window for UI, evaluates proactive workout start, and schedules the extended runtime session as a safety net.
5. When monitoring starts, `SmartWakeSessionController` reuses the proactive workout session if already running, or tries to start a new one. If the workout session fails (e.g., app is in background), it switches to **degraded monitoring mode** (`isDegradedMode = true`): passive HR query + wake check timer remain active so force-fire + haptics work at wake time. This is strictly better than the previous behavior of total failure.
6. Seed failures are logged but do not fail monitoring.
7. `WakeHeuristicEngine` uses a frozen pre-window baseline:
   - Preferred baseline window: `windowStart - 60m` through `windowStart - 5m`
   - Statistic: median BPM
   - Baseline is only ready after at least 8 samples spanning at least 15 minutes
   - The baseline freezes at wake-window entry; if it never becomes ready, early triggering stays disabled and exact wake-time force-fire remains the backstop
   - HR rise above baseline: 70% weight (normalized by 5 BPM threshold)
   - Short-term HRV (stddev of last 6 samples): 30% weight (normalized by 5 BPM)
   - Trigger threshold: confidence >= 0.6
   - Cooldown: 5 minutes between attempts
8. When `shouldTrigger(inWakeWindow: true)` passes:
   - Watch starts wrist haptics immediately.
   - Watch sends `SmartWakeTriggerPayload` via `WCSession.sendMessage` (fallback: `transferUserInfo`) with a unique `triggerID` and the actual latest BPM in `heartRateAtTrigger`.
   - Watch arms a deferred local HomeKit fallback for 8 seconds later instead of starting lights immediately.
   - Phone rejects stale triggers older than 2 hours and triggers more than 2 minutes in the future before occurrence matching.
   - Phone validates against the wake occurrence whose window contains `triggerDate`, not just the next future occurrence.
   - Phone attempts `ScheduleEngine.startSmartWakeExecution(for:)`, which waits briefly for HomeKit readiness, computes a smart-wake ramp plan, and performs a synchronous first-visible-step ownership-commit write.
   - Phone replies with `SmartWakeLightHandoffPayload` only after that initial write reaches at least one selected light (`phoneWillHandleLights = true`) or immediately declines (`false`, with a reason).
   - Watch cancels its deferred local fallback only on a positive ack for the same `triggerID`; otherwise it starts watch-local fallback on timeout or immediate negative ack.
9. `SmartWakeSessionController.finishMonitoringAfterTrigger()` tears down workout/query/timer state and returns the controller to `.idle` after reporting `.triggered`, but it does not stop haptics or the deferred/local light fallback path.
10. Early watch fallback starts at the same first visible/non-zero step the phone uses and never sends the all-off step. Exact wake-time fallback writes the final target light state immediately after a timeout or negative ack instead of running a dim-from-zero ramp.
11. The watch log file captures scheduler decisions, historical/live HR samples, every baseline recomputation, every wake evaluation verdict, every trigger/handoff event, and every watch-local HomeKit write summary (including per-light failures when writes fail).
12. If no smart trigger arrives by wake time, watch force-fires at confidence 1.0. The single fallback scene at wake time remains the tertiary safety net if neither phone nor watch can own the wake.

### Persistent Smart Wake Logs
1. `SmartWakeLogStore` writes timestamped text logs to the watch app’s Application Support directory:
   - `smartwake-runtime.log` records all app-generated watch logs from launch onward
   - one per-schedule-occurrence session log records the focused overnight wake path
2. Log lines use ISO-8601 timestamps with fractional seconds and local timezone offset so overnight ordering is unambiguous.
3. The same log call writes to disk and mirrors to the Xcode console, so app-generated console output and saved log output stay aligned.
4. The watch keeps recent session-log metadata in memory for UI access and retains up to 14 session log files on disk, plus the runtime log.
5. `WatchRootView` exposes retrieval paths for both the runtime log and the latest session log:
   - open logs directly on the watch
   - share logs from the watch share sheet
   - queue logs for paired-iPhone transfer
6. `WatchSessionManager.transferLogFile` first snapshots the selected watch log into a dedicated transfer-staging directory, then uses `WCSession.transferFile` with metadata naming the original log file. This keeps the live runtime/session logs in Application Support untouched so they can be resent later.
7. `WatchLogArchiveService` stores incoming files on the iPhone and `WatchLogArchiveView` lets the user read/share them later.

### Persistent iPhone Logs
1. `PhoneLogStore` writes timestamped text logs to the iPhone app’s Application Support directory:
   - `iphone-runtime.log` records all app-generated iPhone logs from launch onward
   - one `iphone-launch-<timestamp>.log` file is created per app launch and records that launch’s focused session
2. The same phone log call writes to disk and mirrors to `print`, so app-generated iPhone console output and saved phone-log output stay aligned.
3. `PhoneLogStore` is shared across `HomeKitService`, `LightController`, `ScheduleEngine`, `WatchConnectivityService`, `SmartWakeCoordinator`, `HealthKitAuthorizationService`, `WatchLogArchiveService`, and `ContentView`, so startup, lifecycle, HomeKit readiness, WCSession state, trigger/handoff decisions, and ramp execution all land in the saved phone logs.
4. The phone retains up to 14 launch-log files plus the append-only runtime log.
5. `ScheduleListView` exposes a Phone Logs section, and `PhoneLogArchiveView` lets the user read/share both runtime and per-launch logs directly on the iPhone.

### Duplicate Prevention
- `SmartWakeCoordinator.firedToday: [UUID: Date]` — one trigger per schedule per calendar day.
- `SmartWakeCoordinator.processedHandoffs[triggerID]` — timestamped handoff records; duplicate deliveries resend the same ownership ack instead of reprocessing. Entries are pruned after 24 hours and capped at 256 by oldest-first eviction.
- Trigger freshness gate — triggers older than 2 hours or more than 2 minutes in the future are rejected before occurrence matching.
- `SmartAlarmScheduler.completedWakeOccurrence` — after a wake is triggered, stopped, or fails, the watch marks that specific `(scheduleID, wakeUpTime)` occurrence as completed and candidate selection skips it, so post-cleanup reevaluation advances to the next eligible wake instead of re-arming the same occurrence.
- `ScheduleEngine.isRunning` guard — no second phone-side ramp if one is active.
- Production smart wake no longer uses `lightsHandledOnWatch` to short-circuit the phone path; only explicit watch test mode still sets it.
- Watch haptic timer auto-stops after 60s; `stopHaptics()` cancels early if `stopMonitoring()` is called.
- Watch-local light ramp task is cancelled by `stopMonitoring()` and replaced when a new test/trigger starts.

### Test Mode
- **iPhone "Test Lights"** (swipe right on any schedule row): `ScheduleEngine.startTestExecution(for:)` runs the full light ramp from now to now + leadTimeMinutes. A "Stop" button appears in the running banner.
- **Watch "Test Alarm"** (button per schedule in WatchRootView): plays the 60-second haptic ramp locally, starts the watch-local HomeKit ramp, and sends a `testTrigger` message to the phone. The phone starts a rapid smart-wake-style light ramp only if the watch did not already claim the lights.
- **Haptic preview**: selecting a haptic pattern plays a preview vibration on both platforms (iOS: UIKit feedback generators; watchOS: `WKInterfaceDevice.play()`).

### Haptic Pattern Sync (Watch → Phone)
- Watch haptic picker changes send `hapticPatternChanged` message via `WatchSessionManager.sendHapticPatternChange`.
- iPhone `WatchConnectivityService` receives it, calls `SmartWakeCoordinator.handleHapticPatternChange` which updates `LightSchedule.hapticPatternRaw` in SwiftData and re-syncs to watch.

### Graceful Degradation
- Watch unavailable → single fallback scene at wake time snaps lights on.
- HealthKit permissions denied → normal scheduled wake.
- Historical HR seed failure → live HR monitoring continues without the seed.
- Workout session fails to start (background context) → degraded monitoring with passive HR query + wake check timer. Force-fire + haptics still work at wake time.
- Workout session ends unexpectedly during monitoring → switches to degraded mode instead of failing. Monitoring stays alive.
- Extended runtime session expires/invalidates → `extendedRuntimeSessionWillExpire` force-starts monitoring if pending.
- Stale/future-skewed triggers, triggers outside the matching occurrence window, disabled schedules, or phone ownership-commit failure → negative handoff ack to the watch so the watch can take over immediately or on its 8-second timeout.
- If HomeKit homes are cold on the phone during background scene sync, `ScheduleEngine.hasPendingHomeKitRetry` is set and app-init wiring retries when `HomeKitService.onHomesUpdated` fires.

## iPhone↔Watch Communication Protocol

### iPhone → Watch
- `WCSession.updateApplicationContext` (latest-state-wins) for `schedulesUpdated` / `[WatchScheduleSnapshot]`; unchanged payloads are suppressed and retries happen after activation/watch-state changes only
- `WCSession.sendMessage` (fallback `transferUserInfo`) for `smartWakeLightHandoff` / `SmartWakeLightHandoffPayload`

### Watch → iPhone
- Channel: `WCSession.sendMessage` (real-time, fallback `transferUserInfo`)
- Message types:
  - `smartWakeTriggered` → `SmartWakeTriggerPayload`
  - `sessionStateChanged` → `SmartWakeSessionState`
  - `permissionStatus` → `SmartWakePermissionStatus`
  - `hapticPatternChanged` → `HapticPatternChangePayload` (scheduleID + new pattern)
  - `testTrigger` → `SmartWakeTriggerPayload` (bypasses validation on phone)
- All use `[WCMessageKey.type: String, WCMessageKey.payload: Data]` envelope
- `triggerID` correlates each trigger with its explicit phone→watch light-handoff ack.
- Watch log files use `WCSession.transferFile` with metadata `{ kind: "smartWakeLog", filename: "<log>.log" }`; the watch sends an immutable snapshot copy, and the iPhone stages the received temporary file before importing it into `WatchLogArchiveService`.

## UI Structure

### ScheduleListView
- Empty state with "Add Schedule" CTA
- Active execution progress banner (when `scheduleEngine.isRunning`)
- Schedule rows: name, time, days summary, light count, smart wake badge (blue `applewatch` icon)
- Enable/disable toggle per row
- Swipe delete
- Swipe right on smart-wake schedules: "Test Wake" debug trigger button
- Toolbar: leading settings gear, trailing add button

### SettingsView
- Collapsible `Phone Logs` disclosure section: latest phone-log capture status, navigation to `PhoneLogArchiveView`, and share shortcuts for the runtime log + latest launch log
- Collapsible `Watch Logs` disclosure section: latest imported watch log status, navigation to `WatchLogArchiveView`, and share shortcut for the newest imported file
- Collapsible `Smart Wake Debug` disclosure section (`#if DEBUG`): last trigger result, last light owner, last background-scene sync status, pending HomeKit retry flag, and watch connection status

### ScheduleDetailView
- Form sections: Name, Wake Up Time (wheel picker), Repeat (day circles), Lights (picker navigation), Lead Time (stepper 5-120 min), **Smart Wake** (toggle + window stepper 10-60 min), Target Brightness (slider), Light Colors (start/end color pickers + gradient)
- Save triggers `scheduleEngine.onAppActive` + dismiss

### WatchRootView (watchOS)
- Status section: session state icon/color/title/subtitle, health access button
- Smart Wake Schedules section: list from `WatchSessionManager.activeSchedules`
- Diagnostics section: heuristic summary, next scheduled wake window, baseline readiness/BPM/sample count, phone handoff status, deferred watch fallback status, phone reachability, error messages, stop button
- Logs section: runtime-log metadata, session-log export shortcuts, watch-side log viewer navigation, and iPhone transfer actions

## Build And Project Notes

### PBXFileSystemSynchronizedRootGroup
Files placed in `Lights Timer/` automatically belong to the iOS target. Files in `Lights Timer Watch App/` automatically belong to the watch target. No need to manually add files to build phases.

### Shared Code Strategy
`WatchScheduleSnapshot.swift`, `SmartWakeMessage.swift`, and `ChunkedLogTextView.swift` are **duplicated** in both target directories. This is intentional — file-sync groups don't support cross-target membership. Keep both copies in sync when changing these types.

### Concurrency Patterns
- **HomeKit delegate callbacks** (`HMHomeManagerDelegate`): `nonisolated` + `MainActor.assumeIsolated` — works because HomeKit calls delegates on main thread.
- **WCSession delegate callbacks**: `nonisolated` + `Task { @MainActor in }` — WCSession fires on a background serial queue, so `assumeIsolated` would crash.
- **HealthKit delegate callbacks** (`HKWorkoutSessionDelegate`, `HKLiveWorkoutBuilderDelegate`, `HKAnchoredObjectQuery`): `nonisolated` + `Task { @MainActor in }`.
- **WatchSessionManager**: includes `#if os(iOS)` guard for `sessionDidBecomeInactive`/`sessionDidDeactivate` (required on iOS, absent on watchOS) to handle cross-compilation when iOS target embeds watch app.
- **SmartAlarmScheduler**: entire file wrapped in `#if os(watchOS)` because `WatchKit` is watchOS-only. References in `LightsTimerWatchApp.swift` also guarded with `#if os(watchOS)`.
- **WKExtendedRuntimeSessionDelegate callbacks**: `nonisolated` + `Task { @MainActor in }` (same pattern as WCSession/HealthKit delegates).
- **WatchHomeKitService** (inside `SmartWakeSessionController.swift`): same `HMHomeManagerDelegate` pattern as iPhone HomeKit service; there is no separate file for this helper.
- **HomeKit retry wiring**: `HomeKitService.onHomesUpdated` is invoked on the main actor and `Lights_TimerApp.init` uses it to retry pending background-scene syncs with a fresh `ModelContext`.

### HomeKit Constraints
- `HMActionSet` scenes spaced 1 minute apart minimum (closer intervals "get weird").
- Scene/trigger names prefixed with `LT_<8-char-UUID>_<step>` for cleanup.
- `HMCharacteristicWriteAction` is generic — pass as `HMAction` to `addAction`.
- `HMTimerTrigger` fireDate takes `Date`, not `DateComponents`.
- `HMActionSet()` has no public init — use `home.addActionSet(withName:)`.
- Async HomeKit wrappers use `withCheckedThrowingContinuation` over callback APIs.
- iPhone direct `HMCharacteristic.writeValue` calls can fail from background wakeups (`HMErrorDomain Code=80`). Smart wake therefore prefers watch-local HomeKit writes when the watch can handle the selected accessories.
- Watch-local HomeKit lookup uses synced accessory UUIDs first, then `lightNames` as a fallback when watch-visible accessory IDs differ from the phone.
- Normal ramps still stage brightness/color before `powerOn = true` and keep step 0 powered off to avoid a start-of-ramp flash.
- Smart-wake phone ownership and early watch fallback both start from the first visible/non-zero step; exact wake-time watch fallback writes the final state directly instead of replaying the all-off step.

### Entitlements And Background Modes
- iOS: `com.apple.developer.homekit` only
- watchOS: `com.apple.developer.healthkit` + `com.apple.developer.homekit`
- watchOS Info.plist lives in `Lights-Timer-Watch-App-Info.plist` and includes `NSHomeKitUsageDescription`
- watchOS background modes (`WKBackgroundModes`): `workout-processing` + `alarm` — enables both `HKWorkoutSession` and `WKExtendedRuntimeSession` (alarm type) to run concurrently in the background
- Info.plist health strings remain set via build settings: `INFOPLIST_KEY_NSHealthShareUsageDescription`, `INFOPLIST_KEY_NSHealthUpdateUsageDescription`

## Testing

### Debug/Dev Shortcuts
- **Simulate smart wake trigger**: swipe right on any smart-wake-enabled schedule row → "Test Wake" button. Injects a simulated `SmartWakeTriggerPayload` with confidence 0.85.
- **Watch connectivity status**: visible in `#if DEBUG` section of ScheduleListView.
- **Heuristic diagnostics**: visible on watch UI (next window, baseline readiness/BPM/sample count, latest HR/confidence, phone handoff status, deferred fallback status).
- **Log retrieval**: after a run, open `ScheduleListView` → Phone Logs for local iPhone logs, `ScheduleListView` → Watch Logs for imported watch logs, or `WatchRootView` → Logs on the watch.

### What Requires Physical Devices
- HomeKit accessory discovery and light control
- HealthKit heart rate data collection
- WCSession real-time messaging between iPhone and Watch
- HKWorkoutSession background execution

### Build Verification Commands
```bash
# Verify targets exist
xcodebuild -list -project 'Lights Timer.xcodeproj'

# Build both (iOS embeds watch)
xcodebuild -target 'Lights Timer' -sdk iphonesimulator26.2 build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO

# Build watch standalone
xcodebuild -target 'Lights Timer Watch App' -sdk watchsimulator26.2 build CODE_SIGNING_ALLOWED=NO
```

## Change Playbooks

### Add a new field to LightSchedule
1. Add the stored property to `LightSchedule.swift`.
2. Add init parameter with default value.
3. If needed on watch: add to `WatchScheduleSnapshot` in **both** `Lights Timer/Models/` and `Lights Timer Watch App/Models/`, update `init(from:)` on the iPhone copy.
4. Update `ScheduleDetailView` (add UI control, populate in `populateFromSchedule`, persist in `save`).
5. Build both targets to verify.

### Add a new watch→iPhone message type
1. Add key constant to `WCMessageKey` in **both** copies of `SmartWakeMessage.swift`.
2. Add Codable payload struct in **both** copies.
3. Add send method in `WatchSessionManager.swift`.
4. Add receive handler in `WatchConnectivityService.handleMessage`.
5. Wire consumer in `SmartWakeCoordinator` or another app-side service.

### Modify the wake heuristic
1. Edit `WakeHeuristicEngine.swift` (watch target only).
2. Adjust thresholds: `hrRiseThreshold` (BPM delta), `confidenceThreshold` (0-1), `cooldownInterval` (seconds).
3. Adjust weights in `updateConfidence`: HR rise (currently 0.7), HRV (currently 0.3).
4. Test on physical watch — simulator cannot produce real heart rate data.

### Add a new service to the app
1. Create file in `Lights Timer/Services/`.
2. Add `@State` property and init in `Lights_TimerApp.swift`.
3. Add `.environment(service)` to ContentView.
4. Add `@Environment(ServiceType.self)` in consuming views.
5. If watch-side service: create in `Lights Timer Watch App/Services/`, wire in `LightsTimerWatchApp.swift`.

## Known Limitations
- Smart wake heuristic is basic (HR rise + variability) — not true sleep-stage classification.
- Foreground ramp (`Timer.publish`) only ticks while app is in foreground. Background relies on HomeKit timer-triggered scenes.
- Phone-side smart wake only acks after an initial ownership write, but later ramp steps still depend on background execution time; if the phone loses execution after claiming the lights, the already-written state plus the exact wake-time scene remain the backstops.
- If the watch cannot resolve the chosen lights by UUID, it falls back to `lightNames`; if both fail, the phone may already have declined ownership and the exact wake-time fallback scene becomes the safety net.
- Phone log files mirror app-generated logs, not arbitrary iOS system/framework lines that Xcode may surface outside this app’s code.
- Automatic watch→phone log transfer only happens when the watch explicitly queues files (for example after a completed/failed watch-owned wake path or when the user taps a send action in the Logs section); if you want the most complete picture, export the runtime log.
- Watch `HKWorkoutSession` (proactive, started in foreground) + `WKExtendedRuntimeSession` (safety net, fires at `wakeTime - 30min`) consume battery. Proactive workout keeps the app alive indefinitely via `workout-processing` background mode; HR monitoring starts up to 1 hour before wake window.
- The proactive workout session requires the user to open the watch app before bed. If the user doesn't, the extended runtime session at `wakeTime - 30min` provides degraded monitoring (force-fire + haptics guaranteed, but no early HR-based trigger). `WatchSessionManager.onSchedulesUpdated` and cached iPhone schedule sync retries reduce this risk, but they do not eliminate watchOS scheduling limits.
- SwiftData model changes (adding/removing fields) may require migration handling for existing user data.
