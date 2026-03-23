# AGENTS.md — Lights Timer

## Purpose
This is the complete operator map for both the iOS app and its watchOS companion.
A new agent should be able to trace any feature to its files, understand the execution model, and make changes without exploratory searches.

**When you change architecture, add/remove files, change build settings, or modify domain workflows, update this file in the same change.**

## Repo Identity
- Path: `/Users/petergelgor/Documents/projects/Lights Timer`
- Git repo: yes
- Xcode project: `Lights Timer.xcodeproj` (objectVersion 77, PBXFileSystemSynchronizedRootGroup)
- Targets: `Lights Timer` (iOS), `Lights Timer Watch App` (watchOS), `Lights Timer Widgets` (watchOS WidgetKit extension)

## Quick Start
- Open in Xcode: `open "Lights Timer.xcodeproj"`
- Build iOS (simulator): `xcodebuild -target 'Lights Timer' -sdk iphonesimulator26.2 build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO`
- Build watch (simulator): `xcodebuild -target 'Lights Timer Watch App' -sdk watchsimulator26.2 build CODE_SIGNING_ALLOWED=NO`
- Both app targets together: build the iOS target; it embeds the watch app automatically
- Widget target: building `Lights Timer Watch App` also builds and embeds `Lights Timer Widgets`
- Real-device testing required for HomeKit accessory discovery and HealthKit sensor data

## Development Tools And Practices

### LSP (Language Server Protocol)
**Always use LSP for code navigation instead of grep/glob when searching for symbols.** LSP provides accurate cross-file symbol resolution and is the primary tool for:
- Finding where symbols are defined (`goToDefinition`)
- Finding all usages of a symbol (`findReferences`)
- Getting type information and documentation (`hover`)
- Listing all symbols in a file (`documentSymbol`)
- Searching for symbols across the workspace (`workspaceSymbol`)
- Understanding call chains (`incomingCalls`, `outgoingCalls`)

**If LSP is starting up** (e.g., showing "server is starting"), **wait for it to complete initialization** before attempting to search. Do NOT fall back to grep/glob during startup — let the LSP server finish indexing. Once active, LSP provides much more accurate results than text-based searches and understands the Swift type system.

**Preference order:**
1. LSP operations (accurate, type-aware)
2. Glob for file patterns (fast, simple)
3. Grep for content patterns (last resort, text-based)

## Stack And Build Settings
- SwiftUI + SwiftData, `@Observable` macro (not ObservableObject)
- iOS 26.2, watchOS 26.2, Swift 5.0, Xcode 26.2
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — every type/method is implicitly `@MainActor` unless marked `nonisolated`
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- Bundle IDs: `com.PeterGelgor.Lights-Timer` (iOS), `com.PeterGelgor.Lights-Timer.watchkitapp` (watch), `com.PeterGelgor.Lights-Timer.watchkitapp.widgets` (widget extension)
- Shared app group: `group.com.PeterGelgor.Lights-Timer.smartwake` (watch app + widget)
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
  SmartWakeMessage.swift           Codable message types + WCMessageKey constants + HapticPattern enum + SmartWakePowerMode / SmartWakeSyncPayload

Views/
  ChunkedLogTextView.swift         Chunked lazy log renderer for large iPhone/watch-imported log files
  ScheduleListView.swift           Schedule list, enable toggle, smart wake badge, debug trigger (swipe right), toolbar entry points for add + settings
  SettingsView.swift               iPhone settings screen with Smart Wake power-mode selection plus collapsible Phone Logs, Watch Logs, and Smart Wake Debug sections
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
  WatchConnectivityService.swift   @Observable NSObject, WCSessionDelegate (iPhone side), caches the latest SmartWakeSyncPayload app-context payload, suppresses unchanged resends, retries after activation/watch-state changes, sends light-handoff acks, stages transferred watch log files immediately for import, and logs WCSession state/messages
  SmartWakeCoordinator.swift       @Observable, validates fresh watch triggers against the matching occurrence, keeps bounded handoff dedupe, decides phone vs watch light ownership, syncs schedules + SmartWakePowerMode to watch, and logs trigger/handoff decisions to phone files
  HealthKitAuthorizationService.swift  @Observable, tracks watch health permission status (no direct HealthKit usage on iPhone) and logs watch-status changes to phone files
  SmartWakeSettingsStore.swift     @Observable, persists the Smart Wake power mode (`balanced` vs `highReliability`) in UserDefaults and triggers re-syncs to the watch
  WatchLogArchiveService.swift     @Observable, stores watch-transferred smart-wake log files in iPhone Application Support for in-app viewing/sharing and logs import results

Utilities/
  ColorInterpolation.swift         interpolateHSB() with hue wrapping, interpolateBrightness()

Lights_Timer.entitlements          HomeKit only (com.apple.developer.homekit)
Assets.xcassets/                   AppIcon, AccentColor
```

### watchOS Target: `Lights Timer Watch App/`
```
LightsTimerWatchApp.swift          @main App entry, injects `WatchAppServices.shared`, refreshes auto-launch status, drives `SmartAlarmScheduler.onAppForeground()` / `onAppBackground()` from SwiftUI scene phase, and installs the watch extension delegate adaptor

Models/
  WatchScheduleSnapshot.swift      Codable mirror (duplicated from iOS — no shared target)
  SmartWakeMessage.swift           Codable message types + SmartWakePowerMode / SmartWakeSyncPayload (duplicated from iOS)

Views/
  ChunkedLogTextView.swift         Chunked lazy log renderer for large on-watch log files
  WatchRootView.swift              Status + scheduler arming truth, power-mode summary, schedule list, diagnostics (including auto-launch status, passive-HR background status, workout-session ownership state, last-HR telemetry, and the debug-only no-builder workout validation controls), overnight ambient UI during proactive workout/monitoring, permission prompt, and log export shortcuts
  WatchLogArchiveView.swift        Watch-side viewer/share UI for the always-on runtime log plus saved smart-wake session logs

Services/
  WatchAppServices.swift           @MainActor singleton that owns the shared watch service graph for SwiftUI, the extension delegate, passive-HR observer-query configuration, and widget snapshot refreshes
  WatchExtensionDelegate.swift     WKExtensionDelegate recovery hook; synchronously hands recovered `WKExtendedRuntimeSession`s to the shared scheduler
  WatchSessionManager.swift        @Observable NSObject, WCSessionDelegate (watch side), receives SmartWakeSyncPayload updates + phone handoff acks, persists the latest power mode into the shared app-group defaults, dedupes activation/runtime app-context delivery, tracks whether initial schedule context has hydrated, sends triggers, and transfers immutable log snapshots to iPhone
  SmartWakeSessionController.swift @Observable NSObject, Balanced-mode passive `HKObserverQuery` + background delivery, High Reliability proactive no-builder workout ownership, wake-window monitoring-session reuse/fallback, HR-access probing, bounded/deduplicated HR ingestion, deferred watch-local HomeKit fallback modes, diagnostics-gated smart-wake file logging, and the debug-only no-builder workout-session validation spike
  SmartAlarmScheduler.swift        @Observable NSObject, WKExtendedRuntimeSession manager, persists the owned upcoming wake plus inactive-app foreground-rearm placeholders, recovers sessions after process relaunch, refreshes auto-launch status, tracks scene-phase-backed true foreground state, keeps the inactive-app guard recovery-aware, and only starts the overnight proactive workout in `highReliability` mode
  SmartWakePendingWakeStore.swift  UserDefaults wrapper for the persisted pending wake record (including whether a real extended runtime session was scheduled) plus auto-launch authorization flags/state
  WakeHeuristicEngine.swift        @Observable, frozen pre-window HR baseline, confidence scoring, trigger decision, and verbose baseline/evaluation diagnostics only when runtime diagnostics are enabled
  SmartWakeLogStore.swift          @Observable, persists an always-on watch runtime log plus per-session smart-wake log files in Application Support, lazily refreshes log metadata, tracks export status, and stores a runtime diagnostics flag available in non-debug builds
  SmartWakeWidgetStateStore.swift  Builds a compact Smart Wake status snapshot, writes it into the shared app-group defaults, and reloads WidgetKit timelines after scheduler/session changes

Lights_Timer_Watch.entitlements    HealthKit + HealthKit background delivery + HomeKit + shared app group
Lights-Timer-Watch-App-Info.plist  Watch Info.plist, NSHomeKitUsageDescription, `WKBackgroundModes = alarm + workout-processing`
Assets.xcassets/                   AppIcon, AccentColor
```

### Widget Extension Target: `Lights Timer Widgets/`
```
LightsTimerWidgetsBundle.swift     @main WidgetBundle entry for the watch widget extension
SmartWakeStatusWidget.swift        Smart Stack / complication widget that reads the shared Smart Wake snapshot and renders armed / monitoring / fallback / next-wake states
SmartWakeWidgetShared.swift        Widget-side copy of the shared app-group snapshot schema and defaults reader

Lights_Timer_Widgets.entitlements  Shared app group for reading the watch app's widget snapshot
Lights-Timer-Widgets-Info.plist    Root-level widget Info.plist kept outside the synced folder so it is not auto-copied as a resource
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
| smartWakeWindowMinutes | Int | Smart wake window (default 25) |
| hapticPatternRaw | String | Haptic pattern for watch alarm ("gentle"/"pulse"/"heartbeat"/"alarm"/"critical") |
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

### Watch Initialization (`WatchAppServices.shared`)
```
WatchAppServices.shared
  SmartWakeLogStore
      ↓
  WatchSessionManager ───────────→ SmartAlarmScheduler
      ↓                               ↑
  SmartWakeSessionController ─────────┘

WatchExtensionDelegate.handle(_)
      ↓
WatchAppServices.shared.alarmScheduler.attachRecoveredExtendedRuntimeSession(_)
```
- `WatchAppServices.shared` owns the single watch service graph, so SwiftUI, WCSession background delivery, and recovered alarm sessions all operate on the exact same scheduler instance.
- `LightsTimerWatchApp` injects the shared services into the environment, keeps the existing `.task` / `.onChange` lifecycle hooks, and refreshes Smart Wake auto-launch authorization when the watch scene is active.
- `WatchExtensionDelegate.handle(_:)` must synchronously attach the recovered `WKExtendedRuntimeSession` to `SmartAlarmScheduler` before returning, or watchOS ends the recovered session.
- `SmartAlarmScheduler` persists the full owned upcoming wake (`WatchScheduleSnapshot` + wake metadata) in `UserDefaults`, so recovery never depends on fresh WCSession hydration.

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
2. iPhone sends `SmartWakeSyncPayload` (`[WatchScheduleSnapshot]` + `SmartWakePowerMode`) to watch via `WCSession.updateApplicationContext`. `WatchConnectivityService` caches the latest encoded payload, suppresses identical resends, and retries delivery only after WCSession activation/watch-state changes.
3. **Bounded watch execution model** (extended runtime arming > Balanced passive observer-query delivery or optional High Reliability proactive workout > wake-window monitoring > HomeKit fallback scene):
   - **Phase 1 — Overnight arming**: `SmartAlarmScheduler` computes `sessionStart = max(windowStart - 2m, wakeUpTime - 25m)` and arms `WKExtendedRuntimeSession.start(at:)` there so the smart-alarm session budget covers the wake window and exact-wake fallback. The watch app must be active to arm, and `sessionStart` must be within a ~35-hour scheduling horizon. Successful arming persists a full `SmartWakePendingWakeRecord` in `UserDefaults`, and startup migration rewrites older persisted timing records to the new formula.
   - **Phase 1b — Power-mode split**:
     - `balanced` (default): `WatchAppServices` enables an hourly `HKObserverQuery` + HealthKit background delivery while no wake-window workout is active. Each observer wake fetches only the newest heart-rate sample, updates minimal local state/UI/widget metadata, confirms HR access if possible, and returns immediately with no WCSession traffic or log-file transfer.
     - `highReliability`: when the app is foregrounded and the monitoring start is within a 10-hour lead window, `SmartAlarmScheduler` calls `SmartWakeSessionController.preStartWorkoutSession()` to start a bare `HKWorkoutSession` with `.other` activity type and no `HKLiveWorkoutBuilder`. This primes `workout-processing` background execution and denser overnight HR sampling without saving a workout entry. The watch still shows an app-owned in-progress session indicator while this proactive session is running.
  - **Recovery after relaunch**: If watchOS kills the process overnight and later relaunches it for the alarm session, `WatchExtensionDelegate.handle(_:)` synchronously passes the recovered session to `SmartAlarmScheduler.attachRecoveredExtendedRuntimeSession(_:)`. The scheduler restores the persisted wake record immediately, without waiting for WCSession, and resumes the owned alarm session on the shared service graph. Future recovered `.scheduled` sessions are only trusted when the persisted wake record says a session was actually armed; foreground-rearm placeholders (`isSessionScheduled == false`) invalidate stale recovered sessions instead of treating them as the owned wake, and a late recovered `.scheduled` session is ignored outright if the scheduler already owns a different scheduled/running session in memory. If a recovered session is still scheduled too early, foreground reevaluation cancels and re-arms it, and `extendedRuntimeSessionDidStart` also attempts a best-effort re-schedule.
   - **Phase 2 — Monitoring window**: When the extended runtime session starts, `SmartAlarmScheduler` immediately calls `startMonitoringNow()`. In `highReliability`, `SmartWakeSessionController` reuses the proactive workout if it is still alive; in `balanced`, or if no proactive workout exists, it starts the wake-window workout at that point and enters degraded mode if watchOS refuses the background start. While degraded monitoring is active and wake time has not arrived, the controller now makes up to two delayed in-process workout recovery attempts before giving up and remaining exact-wake-only, and any later true-foreground return immediately attempts another recovery so user- or system-driven relaunches can exploit the foreground context. Monitoring starts an anchored HR query bounded to `wakeUpTime + 5m`, filters future-dated samples, deduplicates seed/live overlap by sample UUID, and seeds history from `windowStart - 2h` only up to `min(now, windowStart)` so historical data never extends into the wake window. The heuristic baseline now comes from historical HealthKit data instead of live pre-window collection, baseline freeze is deferred until the seed completes or a 30-second timeout expires, and early-trigger decisions require a post-monitoring sample delivered through the live query path rather than a seeded historical sample. Heuristic evaluation is sample-driven, with one-shot timers at wake-window start, seed-timeout, and exact wake time replacing the old periodic wake-check timer.
   - **Final backstop — HomeKit fallback scene**: The single `LT_<shortID>_fallback` scene at wake time snaps lights on if neither phone nor watch can own the wake.
4. `SmartAlarmScheduler` receives schedules (via `WatchSessionManager.onSchedulesUpdated`), evaluates the next relevant schedule, creates/reuses a persistent per-session watch log file for that wake, records the next wake window for UI, refreshes the watch auto-launch authorization state, and exposes explicit `armingState` values: `.armed` (wake time in the subtitle; session start kept separately), `.monitoringNow`, `.backstopActive` (a recovered post-wake session is still alive and being preserved as the execution backstop), `.needsForegroundToArm`, `.tooEarlyToArm`, `.failed`, or `.noUpcomingWake`. `WatchAppServices` also publishes a compact widget snapshot into the shared app-group defaults so `Lights Timer Widgets` can show armed / monitoring / fallback / next-wake state in Smart Stack and complication surfaces.
5. `SmartAlarmScheduler` treats true foreground as SwiftUI `scenePhase == .active`, not `WKApplication.shared().applicationState`, because watchOS reports `.active` during extended runtime execution. If the app is inactive when new schedules arrive, the scheduler does not call `start(at:)`; instead it persists the next wake as a foreground-rearm placeholder and surfaces `.needsForegroundToArm` until a real foreground pass can arm it. Only recovered/persisted upcoming occurrences that were actually backed by a scheduled extended runtime session stay `.armed`, even before the first WCSession hydration completes; a recovered future `.scheduled` session is ignored when the persisted wake is only a placeholder waiting for foreground re-arm. Materially different upcoming occurrences cancel or clear the stale owned wake immediately, and wakes beyond the arming horizon are intentionally deferred as `.tooEarlyToArm`.
6. If workout session fails to start in background, or later collapses during monitoring, monitoring enters **degraded mode** (`isDegradedMode = true`): passive HR query + one-shot timers still work, force-fire + haptics still fire at wake time, `SmartWakeSessionController` schedules up to two delayed workout recovery retries while time remains before wake, and `SmartAlarmScheduler.onAppForeground()` triggers an immediate foreground retry when the watch app becomes truly active again.
7. `WakeHeuristicEngine` uses a frozen pre-window baseline (median BPM from `windowStart - 120m` to `windowStart - 5m`, needs 5+ samples over 15+ min). HR rise (70% weight) + short-term HRV (30% weight), threshold >= 0.6, 5-min cooldown. See `WakeHeuristicEngine.swift` for details.
8. On trigger: watch starts haptics immediately + arms 8-second deferred local HomeKit fallback. Phone validates trigger freshness and occurrence window, attempts ownership-commit write via `ScheduleEngine.startSmartWakeExecution(for:)`, replies with `SmartWakeLightHandoffPayload`. Watch cancels local fallback only on positive ack.
9. If no trigger by wake time, watch force-fires at confidence 1.0. The fallback scene at wake time is the tertiary safety net.
10. `extendedRuntimeSessionWillExpire` and `didInvalidateWith:` both force an immediate wake check before background execution is lost.

### Persistent Smart Wake Logs
- `SmartWakeLogStore` writes to Application Support: `smartwake-runtime.log` (always-on) + one per-session log per wake occurrence. ISO-8601 timestamps, mirrored to Xcode console.
- Retains up to 14 session logs. Runtime diagnostics toggle controls verbose per-sample logs.
- `WatchRootView` exposes log viewing, sharing, and iPhone transfer. `WatchSessionManager.transferLogFile` snapshots to a staging directory before `WCSession.transferFile`.
- `WatchLogArchiveService` stores incoming files on iPhone; `WatchLogArchiveView` for reading/sharing.

### Persistent iPhone Logs
- `PhoneLogStore` writes to Application Support: `iphone-runtime.log` (always-on) + one `iphone-launch-<timestamp>.log` per launch. Mirrored to `print`. Shared across all iPhone services. Retains up to 14 launch logs.
- `PhoneLogArchiveView` for reading/sharing on iPhone.

### Test Mode
- **iPhone "Test Lights"** (swipe right on any schedule row): `ScheduleEngine.startTestExecution(for:)` runs the full light ramp from now to now + leadTimeMinutes. A "Stop" button appears in the running banner.
- **Watch "Test Alarm"** (button per schedule in WatchRootView): plays the 60-second haptic ramp locally, starts the watch-local HomeKit ramp, and sends a `testTrigger` message to the phone. The phone starts a rapid smart-wake-style light ramp only if the watch did not already claim the lights.
- `HapticPattern.alarm` uses dense notification/retry burst pairs, while `HapticPattern.critical` adds an even stronger failure/notification/retry triple-burst cadence and is the most aggressive watch-side wake pattern available through public WatchKit haptics.
- **Haptic preview**: selecting a haptic pattern plays a preview vibration on both platforms (iOS: UIKit feedback generators; watchOS: `WKInterfaceDevice.play()`).
### Haptic Pattern Sync (Watch → Phone)
- Watch haptic picker changes send `hapticPatternChanged` message via `WatchSessionManager.sendHapticPatternChange`.
- iPhone `WatchConnectivityService` receives it, calls `SmartWakeCoordinator.handleHapticPatternChange` which updates `LightSchedule.hapticPatternRaw` in SwiftData and re-syncs to watch.

## iPhone↔Watch Communication Protocol

### iPhone → Watch
- `WCSession.updateApplicationContext` (latest-state-wins) for `schedulesUpdated` / `[WatchScheduleSnapshot]`; unchanged payloads are suppressed and retries happen after activation/watch-state changes only
- `WCSession.sendMessage` (fallback `transferUserInfo`) for `smartWakeLightHandoff` / `SmartWakeLightHandoffPayload`

### Watch → iPhone
- Channel: `WCSession.sendMessage` (real-time, fallback `transferUserInfo`)
- Message types:
  - `smartWakeTriggered` → `SmartWakeTriggerPayload`
  - `sessionStateChanged` → `SmartWakeSessionState`
- `permissionStatus` → `SmartWakePermissionStatus` (`heartRateDataActive` + `watchConnected`)
  - `hapticPatternChanged` → `HapticPatternChangePayload` (scheduleID + new pattern)
  - `testTrigger` → `SmartWakeTriggerPayload` (bypasses validation on phone)
- All use `[WCMessageKey.type: String, WCMessageKey.payload: Data]` envelope
- `triggerID` correlates each trigger with its explicit phone→watch light-handoff ack.
- Watch log files use `WCSession.transferFile` with metadata `{ kind: "smartWakeLog", filename: "<log>.log" }`; the watch sends an immutable snapshot copy, and the iPhone stages the received temporary file before importing it into `WatchLogArchiveService`.

## Build And Project Notes

### PBXFileSystemSynchronizedRootGroup
Files placed in `Lights Timer/` automatically belong to the iOS target. Files in `Lights Timer Watch App/` automatically belong to the watch target. Files in `Lights Timer Widgets/` automatically belong to the widget target. No need to manually add files to build phases. Keep target Info.plists that should not become bundle resources at the repo root (`Lights-Timer-Watch-App-Info.plist`, `Lights-Timer-Widgets-Info.plist`), not inside synced folders.

### Shared Code Strategy
`WatchScheduleSnapshot.swift`, `SmartWakeMessage.swift`, and `ChunkedLogTextView.swift` are **duplicated** in both app target directories. This is intentional — file-sync groups don't support cross-target membership. Keep both copies in sync when changing these types. The widget's shared snapshot schema is also intentionally duplicated between `Lights Timer Watch App/Services/SmartWakeWidgetStateStore.swift` and `Lights Timer Widgets/SmartWakeWidgetShared.swift`.

### Concurrency Patterns
- **HomeKit delegate callbacks** (`HMHomeManagerDelegate`): `nonisolated` + `MainActor.assumeIsolated` — works because HomeKit calls delegates on main thread.
- **WCSession delegate callbacks**: `nonisolated` + `Task { @MainActor in }` — WCSession fires on a background serial queue, so `assumeIsolated` would crash.
- **HealthKit delegate callbacks** (`HKWorkoutSessionDelegate`, `HKLiveWorkoutBuilderDelegate`, `HKAnchoredObjectQuery`): `nonisolated` + `Task { @MainActor in }`.
- **WatchAppServices**: `@MainActor` singleton shared by SwiftUI and `WatchExtensionDelegate`, so recovered sessions and foreground UI never drift onto separate watch service instances.
- **WatchSessionManager**: includes `#if os(iOS)` guard for `sessionDidBecomeInactive`/`sessionDidDeactivate` (required on iOS, absent on watchOS) to handle cross-compilation when iOS target embeds watch app.
- **SmartAlarmScheduler**: entire file wrapped in `#if os(watchOS)` because `WatchKit` is watchOS-only. References in `LightsTimerWatchApp.swift` also guarded with `#if os(watchOS)`.
- **WKExtendedRuntimeSessionDelegate callbacks**: `nonisolated` + `Task { @MainActor in }` (same pattern as WCSession/HealthKit delegates).
- **WatchExtensionDelegate**: `handle(_:)` adopts recovered `WKExtendedRuntimeSession`s synchronously on the main actor; delegate attachment cannot be deferred to `Task {}`.
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
- **Heuristic diagnostics**: visible on watch UI (next window, baseline readiness/BPM/sample count, last accepted HR sample age, latest HR/confidence, phone handoff status, deferred fallback status).
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
5. If watch-side service: create in `Lights Timer Watch App/Services/`, construct and wire it in `WatchAppServices.swift`, then inject or observe it from `LightsTimerWatchApp.swift` as needed.

## Known Limitations
- Smart wake heuristic is basic (HR rise + variability) — not true sleep-stage classification.
- Foreground ramp (`Timer.publish`) only ticks while app is in foreground. Background relies on HomeKit timer-triggered scenes.
- Smart Wake can only be newly armed while the watch app is active and the next computed session start is within watchOS’ scheduling horizon. User force-quit and device reboot are outside scope.
- SwiftData model changes (adding/removing fields) may require migration handling for existing user data.
