# CLAUDE.md — Lights Timer

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
  SmartWakeMessage.swift           Codable message types + WCMessageKey constants

Views/
  ScheduleListView.swift           Schedule list, enable toggle, smart wake badge, debug trigger (swipe right)
  ScheduleDetailView.swift         Schedule editor form, smart wake toggle + window stepper
  DayOfWeekSelector.swift          Circular day-of-week picker
  LightPickerView.swift            HomeKit light multi-select
  ColorPreferenceView.swift        Start/end color pickers + gradient preview

Services/
  HomeKitService.swift             @Observable NSObject, HMHomeManagerDelegate, light discovery + characteristic writes
  LightController.swift            @Observable, multi-light batch writes via HomeKitService
  ScheduleEngine.swift             @Observable, foreground timer execution + background HMActionSet/HMTimerTrigger scenes + smart wake ramp
  WatchConnectivityService.swift   @Observable NSObject, WCSessionDelegate (iPhone side), sends schedules, receives triggers
  SmartWakeCoordinator.swift       @Observable, validates watch triggers, deduplicates, starts smart wake ramp
  HealthKitAuthorizationService.swift  @Observable, tracks watch health permission status (no direct HealthKit usage on iPhone)

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
  WatchRootView.swift              Status, schedule list, diagnostics, permission prompt

Services/
  WatchSessionManager.swift        @Observable NSObject, WCSessionDelegate (watch side), receives schedules, sends triggers
  SmartWakeSessionController.swift @Observable NSObject, HKWorkoutSession + HKAnchoredObjectQuery, wake check timer
  WakeHeuristicEngine.swift        @Observable, rolling HR baseline, confidence scoring, trigger decision

Lights_Timer_Watch.entitlements    HealthKit only (com.apple.developer.healthkit)
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
| isEnabled | Bool | Active toggle |
| lightIdentifiers | [String] | HomeKit accessory UUID strings |
| lightNames | [String] | Display names (parallel array) |
| usesSmartWake | Bool | Smart Wake enabled for this schedule |
| smartWakeWindowMinutes | Int | Smart wake window (default 30) |
| lastSmartWakeTriggerAt | Date? | Last smart wake fire time |
| createdAt | Date | Creation timestamp |

Computed: `activeDays: Set<DayOfWeek>`, `wakeUpTimeString`, `activeDaysSummary`

### WatchScheduleSnapshot (Codable, Equatable)
Lightweight mirror of LightSchedule for WCSession transfer. Contains: id, name, wakeUpHour/Minute, activeDaysRaw, leadTimeMinutes, usesSmartWake, smartWakeWindowMinutes, targetBrightness, lightNames. iPhone copy has `init(from: LightSchedule)` extension.

### SmartWakeTriggerPayload (Codable)
Watch→iPhone trigger: scheduleID, triggerDate, confidence, heartRateAtTrigger?, motionLevel?

### SmartWakeSessionState (Codable)
Watch→iPhone state: `.idle`, `.monitoring`, `.triggered`, `.failed` + scheduleID? + message?

## Architecture: Service Graph And Data Flow

### App Initialization (`Lights_TimerApp.init`)
```
HomeKitService → LightController → ScheduleEngine
                                        ↓
WatchConnectivityService ──────→ SmartWakeCoordinator
                                        ↓
HealthKitAuthorizationService    (all injected as @Environment)
```

### Lifecycle Entry (`ContentView.onChange(scenePhase: .active)`)
1. `scheduleEngine.onAppActive(modelContext:)` — checks active schedules + syncs background scenes
2. `smartWakeCoordinator.processPendingTrigger(modelContext:)` — handles any queued watch trigger
3. `smartWakeCoordinator.syncSchedulesToWatch(modelContext:)` — sends smart-wake schedules to watch
4. `smartWakeCoordinator.resetDailyState()` — purges stale per-day trigger tracking
5. Update health auth status from watch connectivity state

### Schedule Save (`ScheduleDetailView.save` → `ScheduleListView.syncEngine`)
1. SwiftData model insert/update
2. `scheduleEngine.onAppActive(modelContext:)` — re-syncs background scenes
3. `smartWakeCoordinator.syncSchedulesToWatch(modelContext:)` — pushes to watch

## Domain Workflows

### Normal Wake (usesSmartWake == false)
1. **Background**: `syncBackgroundScenes` creates `HMActionSet` scenes + `HMTimerTrigger` per minute step, named `LT_<shortID>_<step>`. Fires on HomeKit hub regardless of app state.
2. **Foreground**: `checkForActiveSchedules` detects in-progress window, starts 15-second `Timer.publish` for smooth direct writes via `LightController.applyToMultipleLights`.
3. Progress calculated as `elapsed / total`, brightness and color interpolated linearly.

### Smart Wake (usesSmartWake == true)
1. iPhone sends `WatchScheduleSnapshot` array to watch via `WCSession.updateApplicationContext`.
2. Watch evaluates next relevant schedule, starts `HKWorkoutSession` + `HKAnchoredObjectQuery` up to 1 hour before wake window.
3. `WakeHeuristicEngine` builds rolling HR baseline (samples >5min old), scores confidence:
   - HR rise above baseline: 70% weight (normalized by 5 BPM threshold)
   - Short-term HRV (stddev of last 6 samples): 30% weight (normalized by 5 BPM)
   - Trigger threshold: confidence >= 0.6
   - Cooldown: 5 minutes between attempts
4. When `shouldTrigger(inWakeWindow: true)` passes, watch sends `SmartWakeTriggerPayload` via `WCSession.sendMessage` (fallback: `transferUserInfo`).
5. iPhone `SmartWakeCoordinator` validates: schedule exists, enabled, usesSmartWake, within window, not already fired today, engine not already running.
6. `ScheduleEngine.startSmartWakeExecution(for:triggerTime:)` cleans up background scenes for that schedule, then starts foreground ramp from `triggerTime` to `wakeUpTime` (compressed proportionally).
7. If no smart trigger arrives by wake time, watch force-fires at confidence 1.0. Normal scheduled background scenes also serve as fallback.

### Duplicate Prevention
- `SmartWakeCoordinator.firedToday: [UUID: Date]` — one trigger per schedule per calendar day.
- `ScheduleEngine.isRunning` guard — no second ramp if one is active.
- `startSmartWakeExecution` cleans up that schedule's background scenes to prevent brightness conflicts.

### Graceful Degradation
- Watch unavailable → normal scheduled wake runs via background scenes.
- HealthKit permissions denied → normal scheduled wake.
- Watch session dies → normal scheduled wake.
- Smart wake trigger after scheduled wake time → ignored.
- Smart wake trigger before window → ignored.

## iPhone↔Watch Communication Protocol

### iPhone → Watch
- Channel: `WCSession.updateApplicationContext` (latest-state-wins)
- Payload key: `WCMessageKey.schedulesUpdated`
- Data: JSON-encoded `[WatchScheduleSnapshot]`

### Watch → iPhone
- Channel: `WCSession.sendMessage` (real-time, fallback `transferUserInfo`)
- Message types:
  - `smartWakeTriggered` → `SmartWakeTriggerPayload`
  - `sessionStateChanged` → `SmartWakeSessionState`
  - `permissionStatus` → `SmartWakePermissionStatus`
- All use `[WCMessageKey.type: String, WCMessageKey.payload: Data]` envelope

## UI Structure

### ScheduleListView
- Empty state with "Add Schedule" CTA
- Active execution progress banner (when `scheduleEngine.isRunning`)
- Schedule rows: name, time, days summary, light count, smart wake badge (blue `applewatch` icon)
- Enable/disable toggle per row
- Swipe delete
- Swipe right on smart-wake schedules: "Test Wake" debug trigger button
- `#if DEBUG` section: last trigger result text + watch connection status

### ScheduleDetailView
- Form sections: Name, Wake Up Time (wheel picker), Repeat (day circles), Lights (picker navigation), Lead Time (stepper 5-120 min), **Smart Wake** (toggle + window stepper 10-60 min), Target Brightness (slider), Light Colors (start/end color pickers + gradient)
- Save triggers `scheduleEngine.onAppActive` + dismiss

### WatchRootView (watchOS)
- Status section: session state icon/color/title/subtitle, health access button
- Smart Wake Schedules section: list from `WatchSessionManager.activeSchedules`
- Diagnostics section: heuristic summary (when monitoring), phone reachability, error messages, stop button

## Build And Project Notes

### PBXFileSystemSynchronizedRootGroup
Files placed in `Lights Timer/` automatically belong to the iOS target. Files in `Lights Timer Watch App/` automatically belong to the watch target. No need to manually add files to build phases.

### Shared Code Strategy
`WatchScheduleSnapshot.swift` and `SmartWakeMessage.swift` are **duplicated** in both target directories. This is intentional — file-sync groups don't support cross-target membership. Keep both copies in sync when changing these types.

### Concurrency Patterns
- **HomeKit delegate callbacks** (`HMHomeManagerDelegate`): `nonisolated` + `MainActor.assumeIsolated` — works because HomeKit calls delegates on main thread.
- **WCSession delegate callbacks**: `nonisolated` + `Task { @MainActor in }` — WCSession fires on a background serial queue, so `assumeIsolated` would crash.
- **HealthKit delegate callbacks** (`HKWorkoutSessionDelegate`, `HKLiveWorkoutBuilderDelegate`, `HKAnchoredObjectQuery`): `nonisolated` + `Task { @MainActor in }`.
- **WatchSessionManager**: includes `#if os(iOS)` guard for `sessionDidBecomeInactive`/`sessionDidDeactivate` (required on iOS, absent on watchOS) to handle cross-compilation when iOS target embeds watch app.

### HomeKit Constraints
- `HMActionSet` scenes spaced 1 minute apart minimum (closer intervals "get weird").
- Scene/trigger names prefixed with `LT_<8-char-UUID>_<step>` for cleanup.
- `HMCharacteristicWriteAction` is generic — pass as `HMAction` to `addAction`.
- `HMTimerTrigger` fireDate takes `Date`, not `DateComponents`.
- `HMActionSet()` has no public init — use `home.addActionSet(withName:)`.
- Async HomeKit wrappers use `withCheckedThrowingContinuation` over callback APIs.

### Entitlements
- iOS: `com.apple.developer.homekit` only
- watchOS: `com.apple.developer.healthkit` only (NOT `healthkit.access` — that requires Apple approval for Health Records)
- Info.plist health strings set via build settings: `INFOPLIST_KEY_NSHealthShareUsageDescription`, `INFOPLIST_KEY_NSHealthUpdateUsageDescription`

## Testing

### Debug/Dev Shortcuts
- **Simulate smart wake trigger**: swipe right on any smart-wake-enabled schedule row → "Test Wake" button. Injects a simulated `SmartWakeTriggerPayload` with confidence 0.85.
- **Watch connectivity status**: visible in `#if DEBUG` section of ScheduleListView.
- **Heuristic diagnostics**: visible on watch UI when monitoring (sample count, baseline HR, latest HR, confidence %).

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
5. Wire consumer in `SmartWakeCoordinator` or `ContentView`.

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
- Smart wake trigger delivery requires iPhone app to be reachable via WCSession. If phone is unreachable, trigger is queued via `transferUserInfo` but may arrive late — background scenes serve as fallback.
- Watch workout session consumes battery — monitoring starts up to 1 hour before wake window.
- SwiftData model changes (adding/removing fields) may require migration handling for existing user data.
