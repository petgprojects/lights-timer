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
  SmartWakeMessage.swift           Codable message types + WCMessageKey constants + HapticPattern enum + SmartWakePowerMode / SmartWakeSyncPayload + SmartWakeCalibrationProfile + enriched trigger/occurrence payloads

Views/
  ChunkedLogTextView.swift         Chunked lazy log renderer for large iPhone/watch-imported log files
  ScheduleListView.swift           Schedule list, enable toggle, smart wake badge, debug trigger (swipe right), toolbar entry points for add + settings
  SettingsView.swift               iPhone settings screen with Smart Wake power-mode selection, calibration Health access/status, and collapsible Phone Logs / Watch Logs / Smart Wake Debug sections
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
  WatchConnectivityService.swift   @Observable NSObject, WCSessionDelegate (iPhone side), caches the latest SmartWakeSyncPayload app-context payload (schedules + power mode + calibration profile), suppresses unchanged resends, retries after activation/watch-state changes, sends light-handoff acks, receives watch occurrence summaries, stages transferred watch log files immediately for import, and logs WCSession state/messages
  SmartWakeCoordinator.swift       @Observable, validates fresh watch triggers against the matching occurrence, keeps bounded handoff dedupe, decides phone vs watch light ownership, syncs schedules + SmartWakePowerMode + SmartWakeCalibrationProfile to watch, and logs trigger/handoff decisions to phone files
  SmartWakeCalibrationService.swift  @Observable, requests iPhone HealthKit read access for post-hoc Smart Wake calibration, stores imported watch occurrence summaries, computes a bounded EMA calibration profile from sleep/vitals labels plus overnight heart-rate baseline, dampens per-night tuning when optional overnight vitals deviate from the user baseline, persists it in Application Support, and notifies the coordinator when the profile changes
  HealthKitAuthorizationService.swift  @Observable, tracks watch health permission status (no direct HealthKit usage on iPhone) and logs watch-status changes to phone files
  SmartWakeSettingsStore.swift     @Observable, persists the Smart Wake power mode (`balanced` vs `highReliability`) in UserDefaults and triggers re-syncs to the watch
  WatchLogArchiveService.swift     @Observable, stores watch-transferred smart-wake log files in iPhone Application Support for in-app viewing/sharing and logs import results

Utilities/
  ColorInterpolation.swift         interpolateHSB() with hue wrapping, interpolateBrightness()

Lights_Timer.entitlements          HomeKit + HealthKit (post-hoc Smart Wake calibration reads)
Assets.xcassets/                   AppIcon, AccentColor
```

### watchOS Target: `Lights Timer Watch App/`
```
LightsTimerWatchApp.swift          @main App entry, injects `WatchAppServices.shared`, refreshes auto-launch status, drives `SmartAlarmScheduler.onAppForeground()` / `onAppBackground()` from SwiftUI scene phase, and installs the watch extension delegate adaptor

Models/
  WatchScheduleSnapshot.swift      Codable mirror (duplicated from iOS — no shared target)
  SmartWakeMessage.swift           Codable message types + SmartWakePowerMode / SmartWakeSyncPayload + SmartWakeCalibrationProfile + enriched trigger/occurrence payloads (duplicated from iOS)

Views/
  ChunkedLogTextView.swift         Chunked lazy log renderer for large on-watch log files
  WatchRootView.swift              Status + scheduler arming truth, power-mode summary, schedule list, diagnostics (including auto-launch status, passive-HR status, motion/recorder authorization and freshness, heuristic snapshot telemetry, occurrence-summary status, and the debug-only no-builder workout validation controls), overnight ambient UI during monitoring, permission prompt, and log export shortcuts
  WatchLogArchiveView.swift        Watch-side viewer/share UI for the always-on runtime log plus saved smart-wake session logs

Services/
  WatchAppServices.swift           @MainActor singleton that owns the shared watch service graph for SwiftUI, the extension delegate, passive-HR observer-query configuration, watch permission-status publishing, occurrence-summary forwarding, and widget snapshot refreshes
  WatchExtensionDelegate.swift     WKExtensionDelegate recovery hook; synchronously hands recovered `WKExtendedRuntimeSession`s to the shared scheduler
  WatchSessionManager.swift        @Observable NSObject, WCSessionDelegate (watch side), receives SmartWakeSyncPayload updates + phone handoff acks, persists the latest power mode and calibration profile into the shared app-group defaults, dedupes activation/runtime app-context delivery, tracks whether initial schedule context has hydrated, sends triggers + permission status + occurrence summaries, and transfers immutable log snapshots to iPhone
  SmartWakeSessionController.swift @Observable NSObject, motion-first smart wake executor that arms `CMSensorRecorder`, starts 10 Hz `CMMotionManager` device-motion updates plus the anchored HR query when the alarm session begins, refreshes recorder backfill off-main every 60 seconds, retries recorder preparation for the same wake if earlier arming failed, evaluates the heuristic on motion/HR events, manages deferred watch-local HomeKit fallback, persists occurrence summaries, and keeps the debug-only no-builder workout validation spike diagnostics-gated
  SmartAlarmScheduler.swift        @Observable NSObject, `WKExtendedRuntimeSession` manager that persists the owned upcoming wake (including `armedAt`) plus inactive-app foreground-rearm placeholders, prepares overnight recorder capture while foregrounded, preserves `armedAt` into the monitoring transition so recorder backfill keeps the overnight baseline, recovers sessions after process relaunch, refreshes auto-launch status, tracks scene-phase-backed true foreground state, and starts the motion-first monitoring window when the alarm session begins
  SmartWakePendingWakeStore.swift  UserDefaults wrapper for the persisted pending wake record (including whether a real extended runtime session was scheduled and when it was armed) plus auto-launch authorization flags/state
  WakeHeuristicEngine.swift        Actor-backed multi-signal wake engine with 1-second motion bins, 5s/30s/60s/180s rolling windows, recorder-derived sleep-motion baseline, time-aware HR windows, composite confidence scoring, and occurrence-summary trace generation
  SmartWakeLogStore.swift          @Observable, persists an always-on watch runtime log plus per-session smart-wake log files in Application Support, lazily refreshes log metadata, tracks export status, and stores a runtime diagnostics flag available in non-debug builds
  SmartWakeWidgetStateStore.swift  Builds a compact Smart Wake status snapshot, writes it into the shared app-group defaults, persists the latest calibration profile for the watch service graph, and reloads WidgetKit timelines after scheduler/session changes

Lights_Timer_Watch.entitlements    HealthKit + HealthKit background delivery + HomeKit + shared app group
Lights-Timer-Watch-App-Info.plist  Watch Info.plist, NSHomeKitUsageDescription, NSMotionUsageDescription, `WKBackgroundModes = alarm + workout-processing`
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
Watch→iPhone trigger: triggerID, scheduleID, triggerDate, confidence, heartRateAtTrigger?, motionLevel?, motionScore, hrFreshnessSeconds, motionFreshnessSeconds, sensorProvenance, lightsHandledOnWatch? (`lightsHandledOnWatch` remains test-mode only)

### SmartWakeCalibrationProfile (Codable, Equatable)
Synced iPhone→watch calibration profile: version, updatedAt, nightsConsidered, sleepHeartRateBaselineBPM, threshold offsets for the early/final window, HR weight scaling, stillness multiplier, minimum/strong motion thresholds, and optional next-day wrist temperature / respiratory rate / oxygen saturation / HRV baselines.

### SmartWakeLightHandoffPayload (Codable)
iPhone→Watch ack: triggerID, scheduleID, phoneWillHandleLights, reason?

### SmartWakeSessionState (Codable)
Watch→iPhone state: `.idle`, `.monitoring`, `.triggered`, `.failed` + scheduleID? + message?

### SmartWakeOccurrenceSummary (Codable)
Watch-local per-occurrence summary that the watch also forwards to iPhone calibration: scheduleID, wakeWindowStart/wakeUpTime, trigger date/mode/confidence, motion score + freshness metadata, `SmartWakeScoreTraceSummary` peaks/latest values, `SmartWakeSampleGapSummary`, fallback reason, and createdAt.

## Architecture: Service Graph And Data Flow

### App Initialization (`Lights_TimerApp.init`)
``` 
ModelContainer (created manually, shared with SmartWakeCoordinator)
PhoneLogStore ───────────────────→ ContentView / ScheduleListView / PhoneLogArchiveView
      ↓
HomeKitService → LightController → ScheduleEngine
                                        ↓
WatchConnectivityService ──────→ SmartWakeCoordinator(modelContainer:, calibrationService:)
      │                                 │
      ├── occurrence summaries ───────→ SmartWakeCalibrationService
      └── watch log files ────────────→ WatchLogArchiveService
HealthKitAuthorizationService          (all injected as @Environment)
```
- `PhoneLogStore` is created first so iPhone runtime + per-launch file logging starts during app init, before the rest of the phone service graph begins emitting logs.
- `HomeKitService.onHomesUpdated` is wired here to call `ScheduleEngine.retryPendingBackgroundSync(modelContext:)` with a fresh `ModelContext` when HomeKit homes load after app init/background wake.
- `WatchConnectivityService.onWatchLogFileReceived` is wired here to `WatchLogArchiveService.importTransferredLog(from:metadata:)`, so transferred watch logs appear on the phone automatically.
- `WatchConnectivityService.onOccurrenceSummaryReceived` is wired here to `SmartWakeCalibrationService.importOccurrenceSummary(_:)`, and `SmartWakeCalibrationService.onProfileUpdated` triggers `SmartWakeCoordinator.syncSchedulesToWatch(modelContext:)` so new calibration reaches the watch on the normal schedule payload path.

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
2. `smartWakeCalibration.refreshCalibrationIfNeeded()` — opportunistically refreshes the iPhone-side calibration profile from recent occurrence summaries + HealthKit labels
3. `smartWakeCoordinator.syncSchedulesToWatch(modelContext:)` — sends smart-wake schedules + current power mode + latest persisted calibration profile to watch
4. `smartWakeCoordinator.resetDailyState()` — purges stale per-day trigger tracking
5. Update health auth status from watch connectivity state

### Schedule Save (`ScheduleDetailView.save` → `ScheduleListView.syncEngine`)
1. SwiftData model insert/update
2. `scheduleEngine.onAppActive(modelContext:)` — re-syncs background scenes
3. `smartWakeCoordinator.syncSchedulesToWatch(modelContext:)` — pushes schedules + the current calibration profile to watch

## Domain Workflows

### Normal Wake (usesSmartWake == false)
1. **Background**: `syncBackgroundScenes` creates `HMActionSet` scenes + `HMTimerTrigger` per minute step, named `LT_<shortID>_<step>`. Fires on HomeKit hub regardless of app state.
2. **Foreground**: `checkForActiveSchedules` detects in-progress window, starts 15-second `Timer.publish` for smooth direct writes via `LightController.applyToMultipleLights`. Smart wake schedules are **skipped** — they only trigger via the watch.
3. Progress calculated as `elapsed / total`, brightness and color interpolated linearly.
4. **Adaptive Lighting mode**: When `skipColorWrites` is true (either start or end color set to Adaptive), all hue/saturation writes are skipped in both foreground execution and background scenes. Only brightness + power are written, so HomeKit Adaptive Lighting on the bulb is not overridden. `LightController.applyToMultipleLights` accepts a `skipColor` parameter. The `ColorPreferenceView` shows per-color Adaptive toggles; when toggled, the color picker is hidden and the gradient preview shows a warm-to-cool approximation.

### Smart Wake (usesSmartWake == true)
1. **No gradual ramp**: Smart wake schedules do NOT create per-minute background scenes or trigger foreground timers. Only a single fallback scene (`LT_<shortID>_fallback`) is created at the exact wake time, snapping lights to full brightness if the watch never triggers.
2. iPhone sends `SmartWakeSyncPayload` (`[WatchScheduleSnapshot]` + `SmartWakePowerMode` + `SmartWakeCalibrationProfile`) to watch via `WCSession.updateApplicationContext`. `WatchConnectivityService` caches the latest encoded payload, suppresses identical resends, and retries delivery only after WCSession activation/watch-state changes.
3. **Bounded watch execution model** (extended runtime arming > overnight recorder capture > motion-first monitoring > HomeKit fallback scene):
   - **Phase 1 — Overnight arming**: `SmartAlarmScheduler` computes `sessionStart = max(windowStart - 2m, wakeUpTime - 25m)` and arms `WKExtendedRuntimeSession.start(at:)` there so the smart-alarm session budget covers the wake window and exact-wake fallback. The watch app must be active to arm, and `sessionStart` must be within a ~35-hour scheduling horizon. Successful arming persists a full `SmartWakePendingWakeRecord` (including `armedAt`) in `UserDefaults`, and startup migration rewrites older persisted timing records to the new formula.
   - **Phase 1b — Recorder setup while foregrounded**: when a wake is armed, `SmartAlarmScheduler` calls `SmartWakeSessionController.prepareArmedWake(...)`. If `CMSensorRecorder` is available and authorized, the controller starts `recordAccelerometer(forDuration:)` while the app is still foregrounded. The recorder is opportunistic, capped at 12 hours, and used for overnight baseline + wake-window backfill rather than the final few seconds.
   - **Phase 1c — Idle before session**: `WatchAppServices` keeps the existing lightweight hourly `HKObserverQuery` + HealthKit background delivery alive for permission/status telemetry, but the production `balanced` algorithm no longer depends on starting a workout from the background alarm session. `highReliability` remains reserved for diagnostics/experiments rather than the default trigger path.
   - **Recovery after relaunch**: If watchOS kills the process overnight and later relaunches it for the alarm session, `WatchExtensionDelegate.handle(_:)` synchronously passes the recovered session to `SmartAlarmScheduler.attachRecoveredExtendedRuntimeSession(_:)`. The scheduler restores the persisted wake record immediately, without waiting for WCSession, and resumes the owned alarm session on the shared service graph. Future recovered `.scheduled` sessions are only trusted when the persisted wake record says a session was actually armed; foreground-rearm placeholders (`isSessionScheduled == false`) invalidate stale recovered sessions instead of treating them as the owned wake, and a late recovered `.scheduled` session is ignored outright if the scheduler already owns a different scheduled/running session in memory.
   - **Phase 2 — Monitoring window**: When the extended runtime session starts, `SmartAlarmScheduler` immediately calls `startMonitoringNow()`. `SmartWakeSessionController` starts 10 Hz live `CMMotionManager` device-motion updates and the anchored HR query immediately, loads recorder history off-main from `max(armedAt, windowStart - 2h)` to `now - 3m`, refreshes recorder backfill every 60 seconds while the session is alive, filters future-dated HR samples, deduplicates repeated data, and evaluates the heuristic on motion/HR events plus the exact-wake timer.
   - **Final backstop — HomeKit fallback scene**: The single `LT_<shortID>_fallback` scene at wake time snaps lights on if neither phone nor watch can own the wake.
4. `SmartAlarmScheduler` receives schedules (via `WatchSessionManager.onSchedulesUpdated`), evaluates the next relevant schedule, creates/reuses a persistent per-session watch log file for that wake, records the next wake window for UI, refreshes the watch auto-launch authorization state, and exposes explicit `armingState` values: `.armed` (wake time in the subtitle; session start kept separately), `.monitoringNow`, `.backstopActive` (a recovered post-wake session is still alive and being preserved as the execution backstop), `.needsForegroundToArm`, `.tooEarlyToArm`, `.failed`, or `.noUpcomingWake`. `WatchAppServices` also publishes a compact widget snapshot into the shared app-group defaults so `Lights Timer Widgets` can show armed / monitoring / fallback / next-wake state in Smart Stack and complication surfaces.
5. `SmartAlarmScheduler` treats true foreground as SwiftUI `scenePhase == .active`, not `WKApplication.shared().applicationState`, because watchOS reports `.active` during extended runtime execution. If the app is inactive when new schedules arrive, the scheduler does not call `start(at:)`; instead it persists the next wake as a foreground-rearm placeholder and surfaces `.needsForegroundToArm` until a real foreground pass can arm it. Only recovered/persisted upcoming occurrences that were actually backed by a scheduled extended runtime session stay `.armed`, even before the first WCSession hydration completes; a recovered future `.scheduled` session is ignored when the persisted wake is only a placeholder waiting for foreground re-arm. Materially different upcoming occurrences cancel or clear the stale owned wake immediately, and wakes beyond the arming horizon are intentionally deferred as `.tooEarlyToArm`.
6. Missing sensors degrade gracefully. Recorder data can lag by up to ~3 minutes, live motion can go stale, and HR cadence is irregular when no workout is active. The engine uses **dual-mode weighting** so that whichever signal is strongest drives the decision: when HR is available, it becomes the primary signal; when HR is unavailable, motion carries the full weight. Strong HR arousal (≥0.6) relaxes the minimum motion gate to 0.10 so that a clear HR wake signal isn't blocked by low motion.
7. `WakeHeuristicEngine` keeps 1-second motion bins plus 5s/30s/60s/180s rolling windows and time-aware HR windows. It computes `motionEnergy60s`, `motionBurst30s`, `rotationVariance60s`, `postureShift300s`, `stillnessBreakScore`, `hrDelta`, `hrSlope180s`, `hrFreshnessPenalty`, and `motionFreshnessPenalty`. **Dual-mode confidence**: HR-available mode weights are motion arousal `0.25`, stillness break `0.10`, HR arousal `0.55`, proximity prior `0.10` (base threshold `0.58`); motion-only mode weights are motion arousal `0.65`, stillness break `0.25`, proximity prior `0.10` (base threshold `0.68`). When HR is available, the engine uses the better of both mode confidences so strong motion can still trigger even with a small HR delta. A **runtime HR baseline** is computed from HR samples in the first 5 minutes of the wake window, falling back to the calibration profile's `sleepHeartRateBaselineBPM`. The first 5 minutes of the wake window use a higher threshold, the final 10 minutes relax it slightly, and the final 3 minutes can trigger on strong motion-only evidence when HR is stale.
8. On trigger: watch starts haptics immediately + arms 8-second deferred local HomeKit fallback. It sends an enriched `SmartWakeTriggerPayload` (including motion score, freshness, and sensor provenance), persists a `SmartWakeOccurrenceSummary` with score traces / sample gaps / fallback reason, and forwards that summary to the iPhone for post-hoc calibration. Phone validates trigger freshness and occurrence window, attempts ownership-commit write via `ScheduleEngine.startSmartWakeExecution(for:)`, replies with `SmartWakeLightHandoffPayload`, and watch cancels local fallback only on positive ack.
9. If no trigger by wake time, watch force-fires at exact wake. The fallback scene at wake time remains the tertiary safety net.
10. `extendedRuntimeSessionWillExpire` and `didInvalidateWith:` both force an immediate wake check before background execution is lost.

### Smart Wake Calibration (iPhone post-hoc)
- `SmartWakeCalibrationService` stores watch occurrence summaries in `Application Support/SmartWakeCalibration/Occurrences` and keeps a persisted `profile.json`.
- The next morning, when iPhone HealthKit read access is available, it reads `SleepAnalysis`, sleeping wrist temperature, respiratory rate, oxygen saturation, and HRV SDNN for up to the most recent 14 occurrence summaries.
- Sleep stages are used only as labels for adaptation: deep-sleep early fires raise the motion threshold, exact-wake fallbacks that still look awake/REM lower it slightly, and repeated large HR gaps reduce the HR contribution. All changes are bounded and applied through EMA.
- Updated profiles are synced back to watch via the normal `SmartWakeSyncPayload` path. If summaries or iPhone Health permissions are missing, Smart Wake keeps using the default calibration profile.

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
- `WCSession.updateApplicationContext` (latest-state-wins) for `schedulesUpdated` / `SmartWakeSyncPayload` (`[WatchScheduleSnapshot]` + `SmartWakePowerMode` + `SmartWakeCalibrationProfile`); unchanged payloads are suppressed and retries happen after activation/watch-state changes only
- `WCSession.sendMessage` (fallback `transferUserInfo`) for `smartWakeLightHandoff` / `SmartWakeLightHandoffPayload`

### Watch → iPhone
- Channel: `WCSession.sendMessage` (real-time, fallback `transferUserInfo`)
- Message types:
  - `smartWakeTriggered` → `SmartWakeTriggerPayload`
  - `sessionStateChanged` → `SmartWakeSessionState`
  - `permissionStatus` → `SmartWakePermissionStatus` (`heartRateDataActive` + `watchConnected` + motion/recorder availability + motion/recorder authorization)
  - `smartWakeOccurrenceSummary` → `SmartWakeOccurrenceSummary`
  - `hapticPatternChanged` → `HapticPatternChangePayload` (scheduleID + new pattern)
  - `testTrigger` → `SmartWakeTriggerPayload` (bypasses validation on phone)
- All use `[WCMessageKey.type: String, WCMessageKey.payload: Data]` envelope
- `triggerID` correlates each trigger with its explicit phone→watch light-handoff ack.
- Occurrence summaries are imported by `SmartWakeCalibrationService` on iPhone and also persisted locally on watch for later diagnostics/replay.
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
- iOS: `com.apple.developer.homekit` + `com.apple.developer.healthkit` (read-only next-morning calibration)
- watchOS: `com.apple.developer.healthkit` + `com.apple.developer.homekit`
- watchOS Info.plist lives in `Lights-Timer-Watch-App-Info.plist` and includes `NSHomeKitUsageDescription` + `NSMotionUsageDescription`
- watchOS background modes (`WKBackgroundModes`): `workout-processing` + `alarm` — `alarm` backs the production smart-wake session, while `workout-processing` remains available for diagnostics-gated no-builder workout experiments
- Info.plist permission strings are set via build settings: iPhone `INFOPLIST_KEY_NSHealthShareUsageDescription`; watch `INFOPLIST_KEY_NSHealthShareUsageDescription`, `INFOPLIST_KEY_NSHealthUpdateUsageDescription`, and `INFOPLIST_KEY_NSMotionUsageDescription`

## Testing

### Debug/Dev Shortcuts
- **Simulate smart wake trigger**: swipe right on any smart-wake-enabled schedule row → "Test Wake" button. Injects a simulated `SmartWakeTriggerPayload` with confidence 0.85.
- **Watch connectivity status**: visible in `#if DEBUG` section of ScheduleListView.
- **Heuristic diagnostics**: visible on watch UI (next window, motion/recorder authorization and freshness, latest motion backfill status, current heuristic snapshot, latest HR sample age, phone handoff status, deferred fallback status, and last occurrence-summary export state).
- **Log retrieval**: after a run, open `ScheduleListView` → Phone Logs for local iPhone logs, `ScheduleListView` → Watch Logs for imported watch logs, or `WatchRootView` → Logs on the watch.

### What Requires Physical Devices
- HomeKit accessory discovery and light control
- CoreMotion live device motion and `CMSensorRecorder` backfill
- HealthKit heart rate data collection on watch
- iPhone HealthKit sleep-stage / overnight-vitals calibration reads
- WCSession real-time messaging between iPhone and Watch
- Diagnostics-only no-builder `HKWorkoutSession` validation

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
2. If the payload/profile contract changes, update both copies of `SmartWakeMessage.swift` and keep `SmartWakeCalibrationProfile`, `SmartWakeTriggerPayload`, and `SmartWakeOccurrenceSummary` in sync.
3. Adjust motion and HR scoring references, window thresholds, and confidence weights in the actor. Early triggers must continue to require motion evidence.
4. If overnight baseline or freshness behavior changes, update the recorder/live-motion plumbing in `SmartWakeSessionController.swift` as well as the diagnostic copy in `WatchRootView.swift`.
5. Test on physical watch — simulator cannot produce real motion/HR behavior.

### Add a new service to the app
1. Create file in `Lights Timer/Services/`.
2. Add `@State` property and init in `Lights_TimerApp.swift`.
3. Add `.environment(service)` to ContentView.
4. Add `@Environment(ServiceType.self)` in consuming views.
5. If watch-side service: create in `Lights Timer Watch App/Services/`, construct and wire it in `WatchAppServices.swift`, then inject or observe it from `LightsTimerWatchApp.swift` as needed.

## Known Limitations
- Live motion delivery during smart-alarm extended runtime sessions and `CMSensorRecorder` retrieval timing still need real-device validation; recorder backfill can lag by up to ~3 minutes.
- Early smart-wake triggers always require motion evidence. HR-only spikes may reinforce confidence but cannot fire on their own.
- Post-hoc calibration depends on watch occurrence summaries plus iPhone HealthKit permissions; without them, Smart Wake stays on the default calibration profile.
- Foreground ramp (`Timer.publish`) only ticks while app is in foreground. Background relies on HomeKit timer-triggered scenes.
- Smart Wake can only be newly armed while the watch app is active and the next computed session start is within watchOS’ scheduling horizon. User force-quit and device reboot are outside scope.
- SwiftData model changes (adding/removing fields) may require migration handling for existing user data.
