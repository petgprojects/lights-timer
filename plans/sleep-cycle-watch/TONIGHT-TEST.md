# First overnight test

Use the latest iPhone and watch builds, including the export-logging follow-up.
Simulator validation did not install either app on physical devices.

## Before bed

1. Keep a separate normal alarm as backup for this first physical-device test.
2. Open Lights Timer on iPhone. Confirm one enabled Smart Wake schedule for the
   intended morning, the desired lights and haptic pattern, and a 25-minute
   window. Save any time changes before arming the watch.
3. Open Lights Timer on the watch. Accept requested motion/Home access. Confirm
   **Armed** shows the correct wake time. Under menu → Diagnostics, confirm
   Motion Auth is authorized, Recorder reports that it is armed, and Auto-Launch
   is enabled. An idle live-motion/background-session indicator before the
   monitoring window is expected; raw live acquisition starts near the wake.
4. Enable **Verbose Diagnostics** in that watch Diagnostics screen for this
   first diagnostic night. It adds approximately one movement log line per
   second during monitoring and increases I/O/battery use. Heart-rate access is
   optional; do not start the workout/spike validation controls.
5. Note watch battery percentage and bedtime, and take a photo/screenshot of the
   armed time and recorder/authorization status. Wear the watch overnight;
   keep the phone nearby with its usual connectivity. Leave the apps normally
   (do not force-quit or leave an Xcode debugger attached).

If the watch does not show Armed for the correct time, resolve that before
counting this as a test. Report the visible status/error.

## In the morning

Before clearing logs or reinstalling, note:

- Approximate first haptic time and first visible light time.
- Whether haptics woke you, you were already awake, or the backup alarm woke you.
- Watch battery percentage and anything unusual (watch removed, reboot, lost
  connection, unexpectedly off lights, etc.).

Export:

1. Watch menu → Logs → **Send Runtime Log To iPhone**. Wait for transfer/import.
2. If the session dated for the tested wake is the latest, also use **Send
   Session Log To iPhone**. Opening the app may arm the next occurrence, making
   the latest session belong to tomorrow. A correct older session can be opened
   under Saved Logs and shared directly; the runtime log covers both sessions.
3. iPhone Lights Timer → Settings → Watch Logs → Saved Watch Logs / Imported
   Watch Logs → open the relevant file → share icon. Send `smartwake-runtime.log`
   (or its imported filename) and the correct overnight session log, if available.
4. iPhone Settings → Phone Logs → **Share Runtime Log**. Send
   `iphone-runtime.log` too.

Attach those files to this chat along with the short notes above. If transfer is
unavailable, the watch Logs screen also has direct Share actions.

## What the evidence can establish

The logs record arming/recovery, recorder reads and latest sample timestamps,
movement phase/calibration rate and thresholds, accepted trigger reason versus
exact-time fallback, haptic requests, phone ownership and light-write outcomes.
A compact `OCCURRENCE_JSON` line embeds the full occurrence summary, including
movement diagnostics and sensor-gap/recorder-lag summaries, in ordinary shared
logs. Full raw 40/50 Hz XYZ recordings and battery samples are not exported.

We can assess operational timing and the recorded decision/state. We cannot
replay every overnight raw sample or infer actual sleep stage from these files.
An exact-time wake rather than an early trigger is not automatically a failure.
Subjective wake experience and overnight battery need more than one night.
