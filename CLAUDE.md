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
  ScheduleListView.swift           Schedule list, enable toggle, smart wake badge, debug trigger (swipe right)
  ScheduleDetailView.swift         Schedule editor form, smart wake toggle + window stepper + haptic pattern picker
  DayOfWeekSelector.swift          Circular day-of-week picker
  LightPickerView.swift            HomeKit light multi-select
  ColorPreferenceView.swift        Start/end color pickers + gradient preview

Services/
  HomeKitService.swift             @Observable NSObject, HMHomeManagerDelegate, light discovery + characteristic writes + onHomesUpdated retry hook
  LightController.swift            @Observable, multi-light batch writes via HomeKitService
  ScheduleEngine.swift             @Observable, foreground timer execution + background HMActionSet/HMTimerTrigger scenes + async smart wake ramp launcher + HomeKit retry debug state
  WatchConnectivityService.swift   @Observable NSObject, WCSessionDelegate (iPhone side), caches schedule sync payloads, retries app context delivery, sends light-handoff acks
  SmartWakeCoordinator.swift       @Observable, validates watch triggers against the matching occurrence, deduplicates by triggerID, and decides phone vs watch light ownership
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
  WatchSessionManager.swift        @Observable NSObject, WCSessionDelegate (watch side), receives schedules + phone handoff acks, sends triggers
  SmartWakeSessionController.swift @Observable NSObject, HKWorkoutSession + seeded HR queries, deferred watch-local HomeKit fallback, handoff tracking
  SmartAlarmScheduler.swift        @Observable NSObject, WKExtendedRuntimeSession manager, schedules overnight wake monitoring with `start(at:)`
  WakeHeuristicEngine.swift        @Observable, frozen pre-window HR baseline, confidence scoring, trigger decision

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
HomeKitService → LightController → ScheduleEngine
                                        ↓
WatchConnectivityService ──────→ SmartWakeCoordinator(modelContainer:)
                                        ↓
HealthKitAuthorizationService    (all injected as @Environment)
```
- `HomeKitService.onHomesUpdated` is wired here to call `ScheduleEngine.retryPendingBackgroundSync(modelContext:)` with a fresh `ModelContext` when HomeKit homes load after app init/background wake.

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
2. **Foreground**: `checkForActiveSchedules` detects in-progress window, starts 15-second `Timer.publish` for smooth direct writes via `LightController.applyToMultipleLights`. Smart wake schedules are **skipped** — they only trigger via the watch.
3. Progress calculated as `elapsed / total`, brightness and color interpolated linearly.
4. **Adaptive Lighting mode**: When `skipColorWrites` is true (either start or end color set to Adaptive), all hue/saturation writes are skipped in both foreground execution and background scenes. Only brightness + power are written, so HomeKit Adaptive Lighting on the bulb is not overridden. `LightController.applyToMultipleLights` accepts a `skipColor` parameter. The `ColorPreferenceView` shows per-color Adaptive toggles; when toggled, the color picker is hidden and the gradient preview shows a warm-to-cool approximation.

### Smart Wake (usesSmartWake == true)
1. **No gradual ramp**: Smart wake schedules do NOT create per-minute background scenes or trigger foreground timers. Only a single fallback scene (`LT_<shortID>_fallback`) is created at the exact wake time, snapping lights to full brightness if the watch never triggers.
2. iPhone sends `WatchScheduleSnapshot` array (including colors, `skipColorWrites`, `lightIdentifiers`, `lightNames`, and `hapticPatternRaw`) to watch via `WCSession.updateApplicationContext`. `WatchConnectivityService` caches the latest payload and retries delivery after WCSession activation/watch-state changes.
3. `SmartAlarmScheduler` receives schedules (via `WatchSessionManager.onSchedulesUpdated`), evaluates the next relevant schedule, records the next wake window for debug UI, and uses `WKExtendedRuntimeSession.start(at:)` for overnight scheduling whenever the wake window has not started yet.
4. When monitoring starts, `SmartWakeSessionController` seeds `WakeHeuristicEngine` with a one-shot historical heart-rate query from `wakeUpTime - 2h` through `now`, then starts `HKWorkoutSession` + `HKAnchoredObjectQuery` for live samples.
5. `WakeHeuristicEngine` uses a frozen pre-window baseline:
   - Preferred baseline window: `windowStart - 60m` through `windowStart - 5m`
   - Statistic: median BPM
   - Baseline is only ready after at least 8 samples spanning at least 15 minutes
   - The baseline freezes at wake-window entry; if it never becomes ready, early triggering stays disabled and exact wake-time force-fire remains the backstop
   - HR rise above baseline: 70% weight (normalized by 5 BPM threshold)
   - Short-term HRV (stddev of last 6 samples): 30% weight (normalized by 5 BPM)
   - Trigger threshold: confidence >= 0.6
   - Cooldown: 5 minutes between attempts
6. When `shouldTrigger(inWakeWindow: true)` passes:
   - Watch starts wrist haptics immediately.
   - Watch sends `SmartWakeTriggerPayload` via `WCSession.sendMessage` (fallback: `transferUserInfo`) with a unique `triggerID` and the actual latest BPM in `heartRateAtTrigger`.
   - Watch arms a deferred local HomeKit ramp for 8 seconds later instead of starting lights immediately.
   - Phone validates against the wake occurrence whose window contains `triggerDate`, not just the next future occurrence.
   - Phone attempts `ScheduleEngine.startSmartWakeExecution(for:)` without blocking trigger validation on HomeKit discovery.
   - Phone replies with `SmartWakeLightHandoffPayload` once it either commits to the phone ramp (`phoneWillHandleLights = true`) or declines (`false`, with a reason).
   - Watch cancels its deferred local ramp only on a positive ack for the same `triggerID`; otherwise it starts the watch-local HomeKit ramp on timeout or immediate negative ack.
7. `SmartWakeSessionController.finishMonitoringAfterTrigger()` tears down workout/query/timer state and returns the controller to `.idle` after reporting `.triggered`, but it does not stop haptics or the deferred/local light fallback path.
8. `ScheduleEngine.startSmartWakeExecution(for:)` waits briefly for HomeKit readiness, launches the phone ramp asynchronously, and only removes the fallback scene after a foreground-capable phone ramp completes.
9. If no smart trigger arrives by wake time, watch force-fires at confidence 1.0. The single fallback scene at wake time remains the tertiary safety net if neither phone nor watch can own the early light ramp.

### Duplicate Prevention
- `SmartWakeCoordinator.firedToday: [UUID: Date]` — one trigger per schedule per calendar day.
- `SmartWakeCoordinator.processedHandoffs[triggerID]` — duplicate deliveries of the same trigger resend the same ownership ack instead of reprocessing.
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
- Watch session dies → normal scheduled wake.
- Extended runtime session expires/invalidates → `extendedRuntimeSessionWillExpire` force-starts monitoring if pending.
- Trigger outside the matching occurrence window, disabled schedules, or phone ramp startup failure → negative handoff ack to the watch so the watch can take over immediately or on its 8-second timeout.
- If HomeKit homes are cold on the phone during background scene sync, `ScheduleEngine.hasPendingHomeKitRetry` is set and app-init wiring retries when `HomeKitService.onHomesUpdated` fires.

## iPhone↔Watch Communication Protocol

### iPhone → Watch
- `WCSession.updateApplicationContext` (latest-state-wins) for `schedulesUpdated` / `[WatchScheduleSnapshot]`
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

## UI Structure

### ScheduleListView
- Empty state with "Add Schedule" CTA
- Active execution progress banner (when `scheduleEngine.isRunning`)
- Schedule rows: name, time, days summary, light count, smart wake badge (blue `applewatch` icon)
- Enable/disable toggle per row
- Swipe delete
- Swipe right on smart-wake schedules: "Test Wake" debug trigger button
- `#if DEBUG` section: last trigger result, last light owner, last background-scene sync status, pending HomeKit retry flag, and watch connection status

### ScheduleDetailView
- Form sections: Name, Wake Up Time (wheel picker), Repeat (day circles), Lights (picker navigation), Lead Time (stepper 5-120 min), **Smart Wake** (toggle + window stepper 10-60 min), Target Brightness (slider), Light Colors (start/end color pickers + gradient)
- Save triggers `scheduleEngine.onAppActive` + dismiss

### WatchRootView (watchOS)
- Status section: session state icon/color/title/subtitle, health access button
- Smart Wake Schedules section: list from `WatchSessionManager.activeSchedules`
- Diagnostics section: heuristic summary, next scheduled wake window, baseline readiness/BPM/sample count, phone handoff status, deferred watch fallback status, phone reachability, error messages, stop button

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
- Both iPhone and watch controllers now stage brightness/color before `powerOn = true` and keep step 0 powered off to avoid a start-of-ramp flash.

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
- Phone-side smart wake remains the primary light owner, but background iPhone HomeKit writes can still fail if HomeKit never becomes ready quickly enough; in that case the watch-local fallback or exact wake-time scene must carry the wake.
- If the watch cannot resolve the chosen lights by UUID, it falls back to `lightNames`; if both fail, the phone may already have declined ownership and the exact wake-time fallback scene becomes the safety net.
- Watch `WKExtendedRuntimeSession` (alarm type) + `HKWorkoutSession` consume battery — extended session starts up to 2 hours before wake, HR monitoring starts up to 1 hour before wake window.
- The extended runtime session still must be scheduled while the watch app is awake or receiving WCSession delivery. `WatchSessionManager.onSchedulesUpdated` and cached iPhone schedule sync retries reduce this risk, but they do not eliminate watchOS scheduling limits.
- SwiftData model changes (adding/removing fields) may require migration handling for existing user data.
