# TODO

## Deferred Feature
- **Watch-side Disarm**: plans/PLAN-disarm.md — adds a "Disarm" button on the watch to cancel an armed Smart Wake and coordinate fallback scene removal with the phone. Prerequisite: upgrade `completedWakeOccurrence` from singleton to array (Step D1). Not needed while phone-side toggle-off works as the cancellation path.

## Known Issues (Low Priority)

### `forceImmediateWakeCheck()` dead zone during monitoring startup gap
- **File**: `Lights Timer Watch App/Services/SmartWakeSessionController.swift:1093-1111`
- **Problem**: When `isMonitoringStartupInProgress=true`, `isMonitoringActive=false`, and `now < wakeUpTime`, the method does nothing. A heuristic-based early trigger is impossible during this gap. Force-fire at exact wake time still works.
- **Real-world risk**: Very low — only matters if the extended runtime session expires during the few seconds of monitoring startup AND the user is already waking up before wake time.

### `tearDownMonitoringWithoutCompletion()` leaves stale schedule state
- **File**: `Lights Timer Watch App/Services/SmartWakeSessionController.swift:1115-1137`
- **Problem**: Unlike `stopMonitoring()` and `failMonitoring()`, this doesn't clear `currentSchedule`, `currentScheduleID`, `wakeUpTime`, or `windowStartTime`. Intentional (allows re-arm of same occurrence), but a second call to `forceImmediateWakeCheck()` after teardown would pass its guard. The `heuristicEngine.hasTriggered` guard prevents actual double triggers.
- **Real-world risk**: Low — requires two consecutive invalidation callbacks after teardown.

### `completedWakeOccurrence` is not persisted
- **File**: `Lights Timer Watch App/Services/SmartAlarmScheduler.swift:57`
- **Problem**: If the process is killed between `handleWakeTriggered()` (sets in-memory completion) and `cleanUpAfterCompletedWake()` (clears persisted wake record), the same wake could theoretically be re-armed on relaunch.
- **Real-world risk**: Low — narrow window, trigger has already fired, phone has the handoff, and the extended runtime session would also likely be lost.
