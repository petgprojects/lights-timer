# TODO

## Completed Research

- [x] Inspect Sleep Cycle 6.26.430's watch architecture, distinguish verified metadata from inferred behavior, and compare it with Lights Timer. Findings, evidence, and a reproducible baseline diagnostic: `plans/sleep-cycle-watch/README.md`.

## SDK / Device Research

- [x] Test debugger and instrumentation access to the connected Sleep Cycle App Store installation; iOS denied attachment.
- [x] Find and verify an unencrypted official SDK 1.5.2 with the same build UUID and 838 matching external symbol addresses as the IPA component.
- [x] Trace the accessible SDK alarm/motion instructions and document which findings do or do not establish watch behavior. `SDKProbe.py` executes three original ARM64 arithmetic helpers in an emulator; 116 checks pass. See `plans/sleep-cycle-watch/README.md` and `sdk-proof.json`.
- [x] Recover the exact `SCWatchExtension` smart-wake algorithm. Both watch slices are decrypted and page-hash verified; motion, calibration, alarm phases, runtime and haptics are reconstructed in `plans/sleep-cycle-watch/`. Original-instruction probes validate the reconstruction.

## Simulator Research

- [x] Boot a dedicated watchOS 26.2 simulator and install the extracted Sleep Cycle watch app.
- [x] Attempt app launch and direct extension launch; fix the installed stub's missing execute permission and test a separately retagged, ad-hoc-signed ARM64 extension copy.
- [x] Verify simulator/debugger access with a small native control and inspect loader diagnostics. LLDB read the expected control marker. The encrypted extension failed to spawn; clearing its encryption flag on a disposable copy allowed a suspended process, but all 2,211,840 protected bytes read from memory still matched the original ciphertext. Normal execution ended in SIGBUS.
- [x] Record commands, errors, and the memory comparison in `plans/sleep-cycle-watch/simulator-proof.json`, update the report/evidence, stop test processes, and shut down the dedicated simulator. No decrypted watch code recovered by this simulator route; the later device-helper route succeeded.

## Continued Exact-Algorithm Investigation

- [x] Audit all readable watch metadata and search the IPA for duplicate analyzer code: 38 Mach-O files, 43 slices; identified exact analyzer function addresses and encrypted duplicates in watch widgets/phone GMFoundation.
- [x] Search public vendor distributions and primary sources. No watch-specific plaintext found; Android SDK bytecode supplied an independent check of the separate SDK algorithm.
- [x] Recover actual watch ARM64 plaintext through a development-signed helper on the licensed iPhone; verify the method against the exact public SDK's protected region.
- [x] Recover and verify both watch architectures, including ARM64_32: all 540 protected pages per architecture match both original SHA-1 and SHA-256 pre-encryption hash tables. Phone GMFoundation and SDK controls also verify. Evidence: `plans/sleep-cycle-watch/decryption-proof.json`.
- [x] Fully trace the actual watch motion pipeline, alarm decision, calibration, and runtime scheduling. Exact specifications: `MOTION.md`, `ALARM.md`, and `RUNTIME.md`; ARM64_32 static parity also checked.
- [x] Validate the reconstructed watch algorithm against original instructions with replay/emulation and cross-check its phone counterpart. 6,654 comparisons pass; runnable probes and independent reference are under `plans/sleep-cycle-watch/`.
- [x] Consolidate reproducible evidence, document coverage limits, verify report links/source hashes and original IPA integrity, remove the temporary iPhone helper, and update this task list. Research complete; production integration and overnight validation remain separate follow-up work.

## Implementation Handoff

- [x] Prepare a self-contained new-session prompt for implementing the recovered watch algorithm, including source documents, integration constraints, parity tests, lifecycle validation, and completion criteria.

## Production Movement Integration

- [x] Inspect repository instructions, existing changes, watch specifications, and installed Xcode/SDKs.
- [x] Implement deterministic Swift detector, recorder aggregation, calibration, and alarm state machine.
- [x] Compare the production Swift core with identical timestamped Python reference inputs. Final port parity: 13,870 comparisons across 764 cases pass; proof in `tests/SmartWakeParity/port-proof.json`.
- [x] Integrate raw 40 Hz live motion, delivered-cadence history, recovery, exact-wake safeguards, and light handoff. Includes runtime-start lifecycle event, delayed-tail checkpoints and persisted completion dedupe.
- [x] Retire HR/phone HealthKit threshold tuning and update active-algorithm UI and diagnostics. Optional watch HR telemetry remains; phone summaries archive without tuning.
- [x] Build all targets, validate integration behavior, and document device-only checks. iOS/watch/widget simulator builds and Release watchOS arm64/arm64_32 build passed; fresh paired simulator install/launch passed. New application checks: 58 policy/actor/recovery + 54 recorder + 12 schema + 19 handoff. Evidence: `tests/SmartWakeParity/`.

## Tonight Test Readiness

- [x] Audit runtime/session logging, diagnostics and user export paths.
- [x] Include movement calibration and full occurrence summaries in shareable logs; verify the updated build. iOS/watch simulator and Release watchOS builds pass; 124 integration/recorder/schema checks pass.
- [x] Supply tonight setup and tomorrow export checklist in `plans/sleep-cycle-watch/TONIGHT-TEST.md`.

## Physical-Device Validation (not established by replay or simulator builds)

- [ ] Run overnight raw accelerometer/recorder capture on the physical watch; confirm delivered cadence, lag/order, authorization behavior, >12h capture renewal, processing duration and battery use.
- [ ] Exercise real watchOS termination/relaunch, synchronous recovered-session attachment, deadline/startup/expiration gaps, foreground rearm and persisted completion deduplication.
- [ ] Verify selected haptics, phone ownership acknowledgement, missing/negative/delayed acknowledgement, deferred watch HomeKit fallback, independent exact-time HomeKit scene, one-day override and widget state on paired devices.
- [ ] Review wake experience across several nights; replay parity does not establish clinical sleep-stage accuracy.

## Deferred Feature
- **Watch-side Disarm**: plans/PLAN-disarm.md — adds a "Disarm" button on the watch to cancel an armed Smart Wake and coordinate fallback scene removal with the phone. Prerequisite: upgrade `completedWakeOccurrence` from singleton to array (Step D1). Not needed while phone-side toggle-off works as the cancellation path.

## Resolved by Production Integration

- [x] Recorder/live gravity representation mismatch: both feed raw XYZ into separate recovered analyzers.
- [x] Exact-wake startup gap: synchronous deadline context and timer/watchdog installation before the first await; queued startup cannot restart a completed/triggered occurrence.
- [x] `completedWakeOccurrence` relaunch gap: bounded persistent completion ledger is written before emitting a trigger; recovered completed occurrences are excluded.
- [x] Stale controller context after non-completion teardown is cleared while the scheduler retains occurrence ownership. Dispatch tokens prevent queued startup after invalidation.
- [x] Overdue recovered running session: an uncompleted occurrence now enforces exact wake instead of remaining an inert backstop.
- [x] Premature runtime reschedule: inactive app persists a foreground-rearm placeholder rather than calling `start(at:)`.

See `plans/sleep-cycle-watch/IMPLEMENTATION.md` and `tests/SmartWakeParity/README.md` for production policy, evidence and limitations.
