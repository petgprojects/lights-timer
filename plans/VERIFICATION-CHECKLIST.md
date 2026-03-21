# Smart Wake Verification Checklist

Designed for on-device testing with paired iPhone + Apple Watch, running from Xcode with console visible.

**Prerequisites:**
- Both devices connected in Xcode, console visible for each
- A Smart Wake schedule exists (or create one)
- Runtime diagnostics toggle ON in WatchRootView (enables per-sample HR logs)

---

## Session 1: Happy Path (~30 min)

This validates the core overnight flow end-to-end using a short alarm.

### Setup
1. Open the iPhone app. Create/edit a schedule:
   - Wake time: **20 minutes from now**
   - Lead time: **10 minutes**
   - Smart Wake: **ON**
   - Smart Wake window: **10 minutes** (matches lead time)
   - Assign at least one light
2. Open the watch app and wait for the schedule to sync

### Phase 1: Arming + Proactive Workout

**What to watch for on the watch console:**

- [ ] Schedule syncs: look for `Scheduled extended runtime session for '<name>'`
- [ ] Proactive workout starts: `Proactive no-builder workout session started at <time>`
  - If the monitoring start is >10h away, you'll see `Deferring proactive workout start` instead — this is wrong for a 20-min alarm, investigate
- [ ] WatchRootView shows "Smart Wake armed for <time> (HR active)"
- [ ] Diagnostics show "Workout Session (overnight)" with a green checkmark

**What to watch for on the iPhone console:**
- [ ] `heartRateDataActive=true` appears (the watch sent HR status)

### Phase 2: Monitoring Start

When the extended runtime session fires (~10 min before wake):

- [ ] Watch console: `Extended runtime session is now running`
- [ ] Watch console: `Reusing proactive workout session for monitoring`
  - If you see `Proactive workout already running — skipping` that's the idempotency guard (OK)
  - If you see `Switching to degraded monitoring` — the proactive workout died. Note the preceding error.
- [ ] Watch console: `Starting monitoring for '<name>'`
- [ ] Watch console: `Historical seed loaded <N> sample(s)`
- [ ] Watch console: `Baseline frozen at <time>. ready=true baseline=<BPM> samples=<N>`
  - If `ready=false`, not enough historical data. Smart Wake will force-fire at exact wake time.

### Phase 3: HR Collection (verify no 10-second spam)

Wait 30-60 seconds while monitoring is active. Check the watch console:

- [ ] `Heart-rate sample (live) <BPM>` lines appear every few seconds (confirms workout-driven HR)
- [ ] **NO** periodic evaluation spam between samples. Evaluations should ONLY appear:
  - Once at monitoring startup
  - Immediately after each `Heart-rate sample` line
  - Once at `Wake window started` boundary
  - At exact wake time (if no early trigger)
- [ ] If future-dated samples appear: `Filtered <N> future-dated sample(s)` (consolidated, not per-sample)

### Phase 4: Trigger via Exercise

Do pushups or jumping jacks to raise your heart rate ~5+ BPM above your resting baseline.

- [ ] Watch console: confidence scores increasing (visible if diagnostics enabled)
- [ ] Watch console: `Trigger fired id=<uuid> mode=<mode> confidence=<value>`
- [ ] Watch vibrates (haptic pattern starts)
- [ ] Watch console: phone handoff attempt — either:
  - `Phone accepted light ownership` — phone handles lights
  - `Phone declined light ownership` — watch starts local fallback
- [ ] iPhone console: trigger received and ramp started (if phone accepted)
- [ ] Lights begin ramping up

### Phase 5: Post-Trigger Cleanup

After the trigger fires:

- [ ] Watch console: monitoring tears down cleanly
- [ ] Watch arming state transitions (eventually shows next occurrence or "needs foreground to arm")

**If the trigger does NOT fire before wake time:**
- [ ] Watch console at exact wake time: `Reached exact wake time <time> without an early trigger. Forcing trigger.`
- [ ] Force-fire with confidence 1.0 — lights should snap to full brightness

---

## Session 2: Edge Cases (~15 min)

Run these as separate quick tests.

### Test A: Kill and Relaunch Watch App (Recovery)

1. With a schedule armed and proactive workout running, force-quit the watch app (press side button, swipe to close)
2. Relaunch the watch app
3. Check:
   - [ ] If the extended runtime session was recovered: `Attached recovered extended runtime session`
   - [ ] Persisted wake record restores correctly — arming state shows `.armed` (if session was scheduled) or `.needsForegroundToArm` (if it wasn't)
   - [ ] The proactive workout is **gone** (no recovery for HKWorkoutSession). If monitoring hasn't started yet, next foreground visit should restart it: `Proactive no-builder workout session started`

### Test B: Toggle Schedule Off from Phone (Cancellation Cleanup)

1. With a schedule armed and proactive workout running on the watch
2. On the iPhone, toggle the schedule **off**
3. Check watch console:
   - [ ] Schedule sync arrives
   - [ ] Proactive workout is stopped (you should NOT see "Proactive workout already running")
   - [ ] Arming state becomes `.noUpcomingWake`

### Test C: Needs Foreground To Arm

1. Arm a schedule, then background the watch app
2. On the iPhone, edit the schedule wake time (this triggers a re-sync)
3. Watch receives the sync in background. Check watch console:
   - [ ] `App left foreground — scene is inactive/background`
   - [ ] The new wake is NOT armed from background (no `Scheduled extended runtime session`)
   - [ ] Arming state: `.needsForegroundToArm`
4. Open the watch app (bring to foreground):
   - [ ] `App returned to foreground — re-evaluating schedules`
   - [ ] `Scheduled extended runtime session for '<name>'`
   - [ ] Arming state: `.armed`

### Test D: HealthKit Two-Flag Display

Check the diagnostics on both devices:
- [ ] Watch WatchRootView: shows "HR active" in armed subtitle when proactive workout is running
- [ ] iPhone SettingsView Smart Wake Debug: shows "Heart rate data active on Apple Watch" (not "Authorized")

---

## Session 3: Overnight Test

### Before Bed
1. Create/verify a schedule with your actual wake time (e.g., 7:00 AM), lead time 25 min, Smart Wake ON, window 25 min
2. Open the watch app. Confirm:
   - [ ] Armed: `Scheduled extended runtime session for '<name>'`
   - [ ] Proactive workout running: `Proactive no-builder workout session started`
   - [ ] WatchRootView shows "(HR active)"
3. Leave the watch on your wrist. Close the watch app (it can go to background — the workout keeps it alive)

### Morning Check
After waking up, check the watch logs (WatchRootView > Logs, or export from Xcode):

- [ ] **Proactive workout survived overnight**: Look for continuous `Heart-rate sample (live)` entries throughout the night (if diagnostics were on). If you see a gap followed by `Switching to degraded monitoring`, the proactive workout died overnight.
- [ ] **Extended runtime session fired**: `Extended runtime session is now running` at the expected time
- [ ] **Monitoring reused workout**: `Reusing proactive workout session for monitoring`
- [ ] **Historical seed loaded**: `Historical seed loaded <N> sample(s)` — with overnight HR data, expect a large seed
- [ ] **Baseline frozen with real data**: `Baseline frozen at <time>. ready=true baseline=<BPM>` with a reasonable resting BPM
- [ ] **Smart Wake triggered before alarm time**: `Trigger fired` with confidence >= 0.6
  - OR if you sleep through: `Reached exact wake time` force-fire
- [ ] **No 10-second evaluation spam**: Evaluations only on sample arrival, window start, seed timeout, and exact wake time
- [ ] **No future-dated samples**: No `Filtered <N> future-dated` warnings (or if present, they were handled cleanly)
- [ ] **Phone received handoff**: Check iPhone logs for trigger receipt and light ramp start

### What "Degraded But OK" Looks Like
If the proactive workout died overnight, you'll see:
- `Switching to degraded monitoring` — passive HR only (~5 min intervals)
- Fewer `Heart-rate sample` entries
- Baseline may not freeze (not enough data) — `ready=false`
- Force-fire at exact wake time — `Reached exact wake time`
- This is the same behavior as before the bugfixes, just with better logging

---

## Quick Reference: Log Strings to Search

| Event | Search String |
|-------|--------------|
| Proactive start | `Proactive no-builder workout session started` |
| Proactive skip | `Proactive workout already running` |
| Proactive deferred | `Deferring proactive workout start` |
| Proactive reused | `Reusing proactive workout session` |
| Session armed | `Scheduled extended runtime session for` |
| Runtime started | `Extended runtime session is now running` |
| Monitoring start | `Starting monitoring for` |
| Seed loaded | `Historical seed loaded` |
| Seed timeout | `Seed timeout` |
| Baseline frozen | `Baseline frozen at` |
| Wake window | `Wake window started` |
| HR sample | `Heart-rate sample` |
| Future filtered | `future-dated sample` |
| Dedup filtered | `only duplicate samples` |
| Trigger fired | `Trigger fired id=` |
| Force fire | `Forcing trigger` |
| Emergency fire | `Emergency force-fire` |
| Phone accepted | `Phone accepted light ownership` |
| Phone declined | `Phone declined light ownership` |
| Degraded mode | `Degraded monitoring active` |
| Foreground | `App returned to foreground` |
| Background | `App left foreground` |
| Needs foreground | `needsForegroundToArm` |
