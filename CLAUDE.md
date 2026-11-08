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
- Build iOS (simulator): `xcodebuild -scheme 'Lights Timer' -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
- Build watch (simulator): `xcodebuild -scheme 'Lights Timer Watch App' -destination 'generic/platform=watchOS Simulator' build CODE_SIGNING_ALLOWED=NO`
- Both app targets together: build the iOS scheme with a destination (avoid overriding `-sdk`, which can force embedded watch code onto the iOS platform); it embeds the watch app automatically
- Widget target: building `Lights Timer Watch App` also builds and embeds `Lights Timer Widgets`
- Real-device testing required for HomeKit accessory discovery and HealthKit sensor data

## Local Reference Artifact
- `Sleep Cycle.ipa` at the repository root is a local research copy of Sleep Cycle 6.26.430 (build 28530, `com.lexwarelabs.goodmorning`), downloaded through Apple Configurator on November 7, 2026. It includes the watchOS companion and App Store license metadata. It is excluded through `.git/info/exclude` and is not part of any Xcode target. The iPhone executable retains App Store encryption; the package is not source code.
- `plans/sleep-cycle-watch/README.md` documents the recovered **actual watch** smart-wake algorithm. Both watch slices were decrypted through a temporary development-signed helper on the licensed iPhone; `VerifyDecryptedMachO.py` / `decryption-proof.json` verify every protected page against the original pre-encryption hash tables. `MOTION.md`, `ALARM.md`, and `RUNTIME.md` specify raw input, detector, event bins, calibration, phases, scheduling and haptics. `WatchAlgorithmReference.py` is an independent executable reference; `Watch*Probe.py`, `WatchProbeSupport.py`, `PROBES.md`, and `watch-proof.json` document 6,654 original-instruction comparisons. `watch-arm64_32-parity.json` records the separate static architecture audit. Vendor binaries, license metadata, helper build and raw decompiler output stay in locally ignored `.research-cache/sleep-cycle-deep/`; the helper was removed from the iPhone. These research files are outside app targets. The independent production Swift port and its separate validation are documented in `plans/sleep-cycle-watch/IMPLEMENTATION.md`.
- `SDK-NOTES.md`, `SDKProbe.py`, and `sdk-proof.json` under the same research directory retain the separate phone SDK investigation; that algorithm is not the watch algorithm. `BaselineProbe.swift` reproduces the existing recorder/live motion representation mismatch, which is corrected by the production raw-XYZ integration. `evidence.json` preserves package metadata and the investigation's current result.
- `plans/sleep-cycle-watch/simulator-proof.json` records actual watchOS 26.2 Simulator install/launch tests and LLDB memory inspection. Installation succeeded, encrypted launch failed, and a disposable copy with its encryption flag cleared mapped unchanged ciphertext; it was not decrypted. The simulator/debugger passed an independent control. Raw bundles/logs remain ignored in `.research-cache/sleep-cycle-simulator/`; the dedicated `Sleep Cycle Research` simulator is retained but shut down.

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
- Deployment targets iOS/watchOS 26.2 in current project; Swift 5 language mode; validated with Xcode 27.0 (27A266a) and SDKs 27.0. Check `xcodebuild -version -showsdks` before builds.
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
  LightSchedule.swift              @Model: SwiftData entity, schedule fields + one-day override state + smart wake fields
  WatchScheduleSnapshot.swift      Codable mirror of LightSchedule for WCSession transfer
  SmartWakeMessage.swift           Codable message types + WCMessageKey constants + HapticPattern enum + SmartWakePowerMode / SmartWakeSyncPayload + SmartWakeCalibrationProfile + enriched trigger/occurrence payloads

Views/
  ChunkedLogTextView.swift         Chunked lazy log renderer for large iPhone/watch-imported log files
  ScheduleListView.swift           Schedule list, enable toggle, one-day override status/action, smart wake badge, debug trigger (swipe right), toolbar entry points for add + settings
  SettingsView.swift               iPhone settings with movement-algorithm explanation, occurrence archive status, and collapsible Phone Logs / Watch Logs / Smart Wake Debug sections
  ScheduleDetailView.swift         Schedule editor form, smart wake toggle + window stepper + haptic pattern picker
  OneDayOverrideView.swift         Next-occurrence-only wake-time override editor with cancel/replace controls
  DayOfWeekSelector.swift          Circular day-of-week picker
  LightPickerView.swift            HomeKit light multi-select
  ColorPreferenceView.swift        Start/end color pickers + gradient preview
  PhoneLogArchiveView.swift        iPhone-side viewer/share UI for runtime + per-launch phone log files
  WatchLogArchiveView.swift        iPhone-side viewer/share UI for imported watch smart-wake log files

Services/
  HomeKitService.swift             @Observable NSObject, HMHomeManagerDelegate, light discovery + characteristic writes + onHomesUpdated retry hook + phone-side HomeKit runtime logging
  LightController.swift            @Observable, multi-light batch writes via HomeKitService + best-effort write summaries + persisted failure logging
  PhoneLogStore.swift              @Observable, persists an always-on iPhone runtime log plus per-launch log files in Application Support, mirrors app-generated phone logs to disk and console, and exposes metadata for in-app viewing/sharing
  ScheduleEngine.swift             @Observable, foreground timer execution + background HMActionSet/HomeKit trigger scenes + one-day replacement triggers/foreground restoration + smart wake ownership-commit ramp execution + HomeKit retry debug state + persisted phone logging for ramp/scene decisions
  WatchConnectivityService.swift   @Observable NSObject, WCSessionDelegate (iPhone side), caches the latest SmartWakeSyncPayload app-context payload (schedules + power mode + calibration profile), suppresses unchanged resends, retries after activation/watch-state changes, sends light-handoff acks, receives watch occurrence summaries, stages transferred watch log files immediately for import, and logs WCSession state/messages
  SmartWakeCoordinator.swift       @Observable, validates fresh watch triggers against the matching occurrence, keeps bounded handoff dedupe, decides phone vs watch light ownership, syncs schedules with inert legacy wire defaults, and logs trigger/handoff decisions to phone files
  SmartWakeOccurrenceArchiveService.swift  @Observable, imports and retains watch occurrence diagnostics in the existing archive location; no phone HealthKit threshold tuning
  HealthKitAuthorizationService.swift  @Observable, tracks watch health permission status (no direct HealthKit usage on iPhone) and logs watch-status changes to phone files
  WatchLogArchiveService.swift     @Observable, stores watch-transferred smart-wake log files in iPhone Application Support for in-app viewing/sharing and logs import results

Utilities/
  ColorInterpolation.swift         interpolateHSB() with hue wrapping, interpolateBrightness()

Lights_Timer.entitlements          HomeKit (phone HealthKit calibration entitlement removed)
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
  WatchRootView.swift              Status + scheduler arming truth, movement-algorithm summary, schedule list, diagnostics (including auto-launch status, passive-HR status, motion/recorder authorization and freshness, heuristic snapshot telemetry, occurrence-summary status, and the debug-only no-builder workout validation controls), overnight ambient UI during monitoring, optional telemetry authorization, and log export shortcuts
  WatchLogArchiveView.swift        Watch-side viewer/share UI for the always-on runtime log, manual runtime-log archive/clear action, and saved smart-wake logs

Services/
  WatchAppServices.swift           @MainActor singleton that owns the shared watch service graph for SwiftUI, the extension delegate, passive-HR observer-query configuration, watch permission-status publishing, occurrence-summary forwarding, and widget snapshot refreshes
  WatchExtensionDelegate.swift     WKExtensionDelegate recovery hook; synchronously hands recovered `WKExtendedRuntimeSession`s to the shared scheduler
  WatchSessionManager.swift        @Observable NSObject, WCSessionDelegate (watch side), receives SmartWakeSyncPayload updates + phone handoff acks, normalizes legacy power/profile fields to inert defaults in shared app-group storage, dedupes activation/runtime app-context delivery, tracks whether initial schedule context has hydrated, sends triggers + permission status + occurrence summaries, and transfers immutable log snapshots to iPhone
  SmartWakeSessionController.swift @Observable NSObject, movement smart-wake executor: arms bounded recorder, initializes history before raw XYZ live acquisition at requested 40 Hz, arms exact-wake watchdog before any await, uses a bounded FIFO live stream and separate recorder actor, preserves immediate selected haptics/phone handoff/watch fallback, persists completion before emitting a trigger; HR remains optional telemetry
  SmartAlarmScheduler.swift        @Observable NSObject, `WKExtendedRuntimeSession` manager that persists the owned upcoming wake (including `armedAt`) plus inactive-app foreground-rearm placeholders, prepares overnight recorder capture while foregrounded, preserves `armedAt` into the monitoring transition so recorder backfill keeps the overnight baseline, recovers sessions after process relaunch, refreshes auto-launch status, tracks scene-phase-backed true foreground state, and starts the motion-first monitoring window when the alarm session begins
  SmartWakePendingWakeStore.swift  UserDefaults wrapper for the persisted pending wake record (including whether a real extended runtime session was scheduled and when it was armed) plus auto-launch authorization flags/state
  WakeHeuristicEngine.swift        Actor adapter for the recovered movement core, per-occurrence history calibration, duplicate input rejection, optional HR telemetry, and movement-specific summary diagnostics
  RecoveredMovementCore.swift      Deterministic nonisolated Swift detector, 60-second recorder binner, event-rate calibration, armed filter and alarm state machine; no platform calls or delivery policy
  SmartWakeRecorderPipeline.swift  Off-main streaming raw recorder acquisition in <=3600-second queries, schema-v2 atomic checkpoints with in-flight query/binner state, duplicate cursor, bounded history and delayed-tail retry
  SmartWakeExecutionPolicy.swift   Testable runtime/exact-wake/handoff policy plus bounded persisted occurrence-completion ledger
  SmartWakeLogStore.swift          @Observable, persists an always-on watch runtime log plus per-session smart-wake log files in Application Support, can rotate the runtime log into `smartwake-runtime-<timestamp>.log`, lazily refreshes log metadata, tracks export status, and stores a runtime diagnostics flag available in non-debug builds
  SmartWakeWidgetStateStore.swift  Builds a compact Smart Wake status snapshot, writes it into the shared app-group defaults, retains inert legacy compatibility defaults, and reloads WidgetKit timelines after scheduler/session changes

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
| oneDayOverrideOriginalWakeDate | Date? | Normal next occurrence replaced by a one-day change |
| oneDayOverrideWakeDate | Date? | Replacement wake time on that occurrence's calendar day |
| usesSmartWake | Bool | Smart Wake enabled for this schedule |
| smartWakeWindowMinutes | Int | Smart wake window (default 25) |
| hapticPatternRaw | String | Haptic pattern for watch alarm ("gentle"/"pulse"/"heartbeat"/"alarm"/"critical") |
| lastSmartWakeTriggerAt | Date? | Last smart wake fire time |
| createdAt | Date | Creation timestamp |

Computed/helpers: `activeDays: Set<DayOfWeek>`, `wakeUpTimeString`, `activeDaysSummary`, `activeOneDayOverride`, `nextBaseOccurrence(after:)`, `skipColorWrites: Bool` (true when either color is adaptive)

### WatchScheduleSnapshot (Codable, Equatable)
Lightweight mirror of LightSchedule for WCSession transfer. Contains: id, name, wakeUpHour/Minute, activeDaysRaw, oneDayOverrideOriginalWakeDate, oneDayOverrideWakeDate, leadTimeMinutes, usesSmartWake, smartWakeWindowMinutes, targetBrightness, startColorHue/Sat/Bri, endColorHue/Sat/Bri, skipColorWrites, lightIdentifiers, lightNames, hapticPatternRaw. iPhone copy has `init(from: LightSchedule)` extension.

### SmartWakeTriggerPayload (Codable)
Watch→iPhone trigger: triggerID, scheduleID, triggerDate, confidence, heartRateAtTrigger?, motionLevel?, motionScore, hrFreshnessSeconds, motionFreshnessSeconds, sensorProvenance, lightsHandledOnWatch? (`lightsHandledOnWatch` remains test-mode only)

### SmartWakeCalibrationProfile (Codable, Equatable)
Legacy decode-only iPhone→watch profile, always normalized to defaults and never used by the movement decision: version, updatedAt, nightsConsidered, sleepHeartRateBaselineBPM, threshold offsets for the early/final window, HR weight scaling, stillness multiplier, minimum/strong motion thresholds, and optional next-day wrist temperature / respiratory rate / oxygen saturation / HRV baselines.

### SmartWakeLightHandoffPayload (Codable)
iPhone→Watch ack: triggerID, scheduleID, phoneWillHandleLights, reason?

### SmartWakeSessionState (Codable)
Watch→iPhone state: `.idle`, `.monitoring`, `.triggered`, `.failed` + scheduleID? + message?

### SmartWakeOccurrenceSummary (Codable)
Watch-local per-occurrence summary that the watch also forwards to the iPhone diagnostic archive: scheduleID, wakeWindowStart/wakeUpTime, trigger date/mode/confidence, motion score + freshness metadata, `SmartWakeScoreTraceSummary` peaks/latest values, `SmartWakeSampleGapSummary`, fallback reason, createdAt, optional algorithmIdentifier and movementTraceSummary.

## Architecture: Service Graph And Data Flow

### App Initialization (`Lights_TimerApp.init`)
``` 
ModelContainer (created manually, shared with SmartWakeCoordinator)
PhoneLogStore ───────────────────→ ContentView / ScheduleListView / PhoneLogArchiveView
      ↓
HomeKitService → LightController → ScheduleEngine
                                        ↓
WatchConnectivityService ──────→ SmartWakeCoordinator(modelContainer:)
      │                                 │
      ├── occurrence summaries ───────→ SmartWakeOccurrenceArchiveService
      └── watch log files ────────────→ WatchLogArchiveService
HealthKitAuthorizationService          (all injected as @Environment)
```
- `PhoneLogStore` is created first so iPhone runtime + per-launch file logging starts during app init, before the rest of the phone service graph begins emitting logs.
- `HomeKitService.onHomesUpdated` is wired here to call `ScheduleEngine.retryPendingBackgroundSync(modelContext:)` with a fresh `ModelContext` when HomeKit homes load after app init/background wake.
- `WatchConnectivityService.onWatchLogFileReceived` is wired here to `WatchLogArchiveService.importTransferredLog(from:metadata:)`, so transferred watch logs appear on the phone automatically.
- `WatchConnectivityService.onOccurrenceSummaryReceived` imports diagnostic summaries into `SmartWakeOccurrenceArchiveService`. The old profile file remains untouched but is never read. Phone HealthKit no longer influences Smart Wake.

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
2. `smartWakeCoordinator.syncSchedulesToWatch(modelContext:)` — sends smart-wake schedules with compatibility-default power/profile fields
3. `smartWakeCoordinator.resetDailyState()` — purges stale per-day trigger tracking
4. Update health auth status from watch connectivity state

### Schedule Save (`ScheduleDetailView.save` → `ScheduleListView.syncEngine`)
1. SwiftData model insert/update
2. `scheduleEngine.onAppActive(modelContext:)` — re-syncs background scenes
3. `smartWakeCoordinator.syncSchedulesToWatch(modelContext:)` — pushes schedules to watch (legacy tuning fields are inert defaults)

## Domain Workflows

### One-Day Wake-Time Change
1. Swipe right on a schedule and choose **Change Next**. `OneDayOverrideView` fixes the change to that schedule's next normal occurrence and lets the user choose a replacement time on the same day.
2. The model stores both the original normal occurrence and the replacement time. The schedule row shows the effective next time, and reopening the sheet can edit or cancel it.
3. For a normal wake, `ScheduleEngine` removes the affected weekday from the shared recurring `HMEventTrigger` and adds a one-time `HMTimerTrigger` for each replacement ramp step. HomeKit does not provide a delayed-start form of its native weekday `HMEventTrigger`, so no synthetic `_resume` trigger is created.
4. For Smart Wake, both dates travel in `WatchScheduleSnapshot`; the watch scheduler and phone trigger validator replace the original occurrence with the changed time. The phone's one-time fallback scene is created at the changed time.
5. The override becomes ineffective after both the original and changed times pass (plus a five-minute delivery grace period). On the next iPhone foreground activation, `ScheduleEngine.onAppActive` clears the stale fields and rebuilds all background scenes through the normal `HMEventTrigger` path, restoring the affected weekday as a visible native repeat. The editor explicitly tells the user to reopen Lights Timer once after the changed wake.

### Normal Wake (usesSmartWake == false)
1. **Background**: `syncBackgroundScenes` creates one `HMActionSet` scene and one `HMEventTrigger` per minute step, both named `LT_<shortID>_<step>`. Each trigger matches Home's native time-automation representation: an `HMCalendarEvent` containing only local hour/minute, all selected actual firing weekdays in `recurrences`, and `executeOnce = false`. This produces one visible Home automation per ramp step with the selected Repeat days. An active one-day change excludes its affected weekday and adds only the dated replacement triggers described above; the normal recurrence is restored on the next post-expiry app sync. Trigger setup is transactional; failures remove partial triggers and orphaned scenes.
2. **Foreground**: `checkForActiveSchedules` detects in-progress window, starts 15-second `Timer.publish` for smooth direct writes via `LightController.applyToMultipleLights`. Smart wake schedules are **skipped** — they only trigger via the watch.
3. Progress calculated as `elapsed / total`, brightness and color interpolated linearly.
4. **Adaptive Lighting mode**: When `skipColorWrites` is true (either start or end color set to Adaptive), all hue/saturation writes are skipped in both foreground execution and background scenes. Only brightness + power are written, so HomeKit Adaptive Lighting on the bulb is not overridden. `LightController.applyToMultipleLights` accepts a `skipColor` parameter. The `ColorPreferenceView` shows per-color Adaptive toggles; when toggled, the color picker is hidden and the gradient preview shows a warm-to-cool approximation.

### Smart Wake (usesSmartWake == true)
1. Smart Wake retains the independent exact-time `LT_<shortID>_fallback` HomeKit scene, with no normal per-minute ramp scenes. Schedule snapshots preserve one-day overrides.
2. `SmartAlarmScheduler` preserves true SwiftUI foreground checks, persisted occurrence ownership/`armedAt`, the 35-hour arming horizon, and synchronous extension-delegate recovery. `SmartWakeExecutionPolicy.sessionStart` retains `max(windowStart - 120s, wakeUpTime - 1500s)` so long windows have at most 25 minutes of runtime coverage. This is application policy, separate from algorithm parity.
3. Foreground arming requests raw accelerometer recording for `min(timeUntilWake, 12h)` on a utility queue. Monitoring installs the exact-wake timer and detached watchdog before its first await, then loads history from persisted `armedAt` through `min(now - 30s, wake)` before starting live movement notifications. Recorder reads consume every delivered raw XYZ/startDate sample without resampling in <=3600-second queries on a separate actor. An atomic schema-v2 checkpoint preserves analyzer, pending bin, in-flight query, event history and accepted timestamp cursor; unavailable/empty tails remain retryable. See IMPLEMENTATION.md for cursor and relaunch policy.
4. Live acquisition requests 40 Hz raw `CMAccelerometerData.acceleration` including gravity. Sensor uptime is converted with a fixed boot-date offset. One FIFO consumer bounds pending delivery at 800 samples; duplicates, out-of-order and nonfinite delivery are excluded before the core. Separate live/history analyzer states eliminate the former gravity/magnitude mismatch. Live state starts fresh on relaunch; history resumes from checkpoint or replays from `armedAt` if incompatible/corrupt.
5. `RecoveredMovementCore` implements exact D `0.09000000000000001`, constructor-derived delayed threshold, previous/100-sample-anchor displacement, non-overlapping 301-sample means, delayed intensity overwrite, quiet rearming, last-intensity 60-second bins with no final flush, historical event-rate calibration and complete alarm phases/filter/decision/latch. History calibration occurs once when movement notifications enter armed. Zero-duration history retains reference 9.5 events/hour. The actual monitoring-start lifecycle event establishes elapsed duration even on quiet nights; no recovered movement then means rate 0. Full duration <2h cannot receive extra filtering. HR/phone profiles never influence these decisions.
6. The pure core retains strict `sampleTime > alarm` and runtime reserve `<300s` ordering. Lights Timer intentionally supplies no reserve override: a shortened OS runtime must not move the effective alarm deadline. Exact-time policy independently fires at wall-clock `now >= wake`, including startup and inactive samples; willExpire/invalidation still perform immediate checks. A lost runtime before wake cannot guarantee watch haptics; the HomeKit scene remains independent. User-selected haptics are retained rather than the vendor alert pattern.
7. Triggering records occurrence completion persistently before immediate haptics, arms the 8-second deferred watch light fallback, sends a deduplicated trigger, and saves a movement-tagged occurrence summary. Phone validates occurrence/freshness, commits light ownership and acknowledges. Only a matching trigger **and schedule** with positive ack cancels the deferred fallback; declines start it immediately. Completion ledger prevents relaunch-before-cleanup duplicate firing; pending ownership schema/`armedAt` remain backward compatible.
8. Optional watch HR telemetry and diagnostics-only workout experiments remain available. Phone power/calibration controls and HealthKit tuning are removed. Old wire fields decode for version compatibility but are normalized to inert defaults; old occurrence archives remain readable and explicitly lack the new algorithm identity. Watch/phone summaries include `algorithmIdentifier = recovered-watch-movement-v1` and `movementTraceSummary` (phase, rate, thresholds, sensitivity, event count). Legacy composite fields are no longer probabilities or inputs.
9. Widgets, logs, override scheduling, independent HomeKit fallback, custom haptic ramp and existing post-trigger execution ownership remain in the service graph.

### Movement calibration and occurrence archive
- Calibration is exclusively the recovered per-night watch event-rate rule; no sleep-stage, HR or next-day phone tuning.
- `SmartWakeOccurrenceArchiveService` preserves `Application Support/SmartWakeCalibration/Occurrences`, importing both old and new summary schemas and retaining 30 files. Old `profile.json` is not loaded or deleted.
- `SmartWakeRecorderPipeline` stores only bounded detector state and sparse events, not raw overnight recordings. `SmartWakeMovementHistory-v2.json` is keyed by schedule/wake/armedAt. New occurrence or incompatible schema replays history; the completion ledger uses `smartWakeCompletedOccurrences-v1` (32 entries, two-day retention).

### Persistent Smart Wake Logs
- `SmartWakeLogStore` writes to Application Support: `smartwake-runtime.log` (always-on) + one per-session log per wake occurrence. Manual clears rotate the live runtime log into `smartwake-runtime-<timestamp>.log` before immediately starting a fresh `smartwake-runtime.log`. ISO-8601 timestamps are mirrored to Xcode console.
- Retains up to 14 archived watch logs (session logs plus cleared runtime snapshots). Phase transitions log movement calibration unconditionally; Verbose Diagnostics adds approximately one movement snapshot per second. Every saved occurrence is also embedded as compact `OCCURRENCE_JSON` in shareable runtime/session logs (algorithm identity, thresholds, rates, sensor gaps and recorder lag). Raw XYZ and battery samples are not exported. First-night procedure: `plans/sleep-cycle-watch/TONIGHT-TEST.md`.
- `WatchRootView` exposes log viewing, sharing, runtime-log clearing, and iPhone transfer. `WatchSessionManager.transferLogFile` snapshots to a staging directory before `WCSession.transferFile`.
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
- Occurrence summaries are imported by `SmartWakeOccurrenceArchiveService` on iPhone and also persisted locally on watch for later diagnostics/replay.
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
- Normal repeated schedules use `HMEventTrigger` + `HMCalendarEvent`, one per ramp step. Calendar-event components must contain only hour/minute (no calendar or time-zone metadata), recurrence components contain actual firing weekdays, and `executeOnce` is explicitly disabled. This mirrors automations created by the Home app and preserves pre-midnight day rollover.
- `HMActionSet()` has no public init — use `home.addActionSet(withName:)`.
- Async HomeKit wrappers use `withCheckedThrowingContinuation` over callback APIs.
- iPhone direct `HMCharacteristic.writeValue` calls can fail from background wakeups (`HMErrorDomain Code=80`). Smart wake therefore prefers watch-local HomeKit writes when the watch can handle the selected accessories.
- Watch-local HomeKit lookup uses synced accessory UUIDs first, then `lightNames` as a fallback when watch-visible accessory IDs differ from the phone.
- Normal ramps still stage brightness/color before `powerOn = true` and keep step 0 powered off to avoid a start-of-ramp flash.
- Smart-wake phone ownership and early watch fallback both start from the first visible/non-zero step; exact wake-time watch fallback writes the final state directly instead of replaying the all-off step.

### Entitlements And Background Modes
- iOS: `com.apple.developer.homekit`
- watchOS: `com.apple.developer.healthkit` + `com.apple.developer.homekit`
- watchOS Info.plist lives in `Lights-Timer-Watch-App-Info.plist` and includes `NSHomeKitUsageDescription` + `NSMotionUsageDescription`
- watchOS background modes (`WKBackgroundModes`): `workout-processing` + `alarm` — `alarm` backs the production smart-wake session, while `workout-processing` remains available for diagnostics-gated no-builder workout experiments
- Info.plist permission strings are set via build settings: watch `INFOPLIST_KEY_NSHealthShareUsageDescription`, `INFOPLIST_KEY_NSHealthUpdateUsageDescription`, and `INFOPLIST_KEY_NSMotionUsageDescription`

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
- WCSession real-time messaging between iPhone and Watch
- Diagnostics-only no-builder `HKWorkoutSession` validation

### Build Verification Commands
```bash
# Verify targets exist
xcodebuild -list -project 'Lights Timer.xcodeproj'

# Build both (iOS embeds watch)
xcodebuild -scheme 'Lights Timer' -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO

# Build watch standalone
xcodebuild -scheme 'Lights Timer Watch App' -destination 'generic/platform=watchOS Simulator' build CODE_SIGNING_ALLOWED=NO
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

### Modify the wake algorithm
1. Read `plans/sleep-cycle-watch/IMPLEMENTATION.md` and the watch MOTION/ALARM specifications. The phone SDK specification is unrelated.
2. Change `RecoveredMovementCore.swift` only with explicit intended behavior changes; run `python3 tests/SmartWakeParity/run.py` against the independent Python reference.
3. Keep delivery, runtime and ownership policy in the adapters; run `run_integration.py` and `run_phone_handoff.py` in the same test directory.
4. Keep both message model copies synchronized and decode legacy summaries/default wire fields.
5. Build iPhone/watch/widget and validate sensor/runtime/HomeKit behavior on physical devices.

### Add a new service to the app
1. Create file in `Lights Timer/Services/`.
2. Add `@State` property and init in `Lights_TimerApp.swift`.
3. Add `.environment(service)` to ContentView.
4. Add `@Environment(ServiceType.self)` in consuming views.
5. If watch-side service: create in `Lights Timer Watch App/Services/`, construct and wire it in `WatchAppServices.swift`, then inject or observe it from `LightsTimerWatchApp.swift` as needed.

## Known Limitations
- Live motion delivery during smart-alarm extended runtime sessions and `CMSensorRecorder` retrieval timing still need real-device validation; recorder backfill can lag by up to ~3 minutes.
- Movement rules are proxies for favorable wake moments; they do not classify clinical sleep stages. HR is telemetry only.
- Zero-duration history means reference ordinary mode (9.5 events/hour); elapsed quiet history uses the recorded lifecycle endpoint. Sparse history and missed live delivery can change early-wake opportunities. Hardware overnight/battery accuracy is not established by replay parity.
- Foreground ramp (`Timer.publish`) only ticks while app is in foreground. Background relies on HomeKit-triggered scenes.
- Smart Wake can only be newly armed while the watch app is active and the next computed session start is within watchOS’ scheduling horizon. User force-quit and device reboot are outside scope.
- SwiftData model changes (adding/removing fields) may require migration handling for existing user data.
