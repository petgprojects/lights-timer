# Reproducing the watch verification

`watch-proof.json` combines **6,654 passing comparison checks** produced by executing the decrypted watch ARM64 instructions in Unicorn and comparing their behavior with independent Python reconstructions. `WatchAlgorithmReference.py` contains the reusable movement detector, recorder event binner, historical calibration, armed filter, alarm phases and wake decisions. It is research code outside the app targets.

No vendor executable bytes are included in the probe files. Supply the locally decrypted files whose provenance was established by `VerifyDecryptedMachO.py` and `decryption-proof.json`. The probes accept either the universal watch executable or its thin ARM64 slice; they select ARM64 in memory. Their instruction addresses are specific to Sleep Cycle **6.26.430 / build 28530**.

```sh
python3 -m venv /tmp/sleepcycle-watch-probes
/tmp/sleepcycle-watch-probes/bin/python -m pip install unicorn==2.1.4
PYTHONDONTWRITEBYTECODE=1 /tmp/sleepcycle-watch-probes/bin/python plans/sleep-cycle-watch/RunWatchProbes.py \
  --watch-binary .research-cache/sleep-cycle-deep/local-decryption/decrypted/SCWatchExtension \
  --phone-binary .research-cache/sleep-cycle-deep/local-decryption/decrypted/GMFoundation
```

The command reruns all six probes, writes the individual JSON reports and rebuilds `watch-proof.json`. Use `--output /absolute/path/watch-proof.json` to put all results in a different directory. Each individual probe accepts `--watch-binary` and `--output`; `WatchMovementProbe.py` also requires `--phone-binary`. `--merge-existing` on the runner assembles existing reports without executing the tests.

| Probe | Comparison checks | Original instructions covered |
|---|---:|---|
| `WatchMovementProbe.py` | 6,434 | Watch FastMovementAnalyzer constructor/update/301-sample mean helper, plus the iPhone GMFoundation counterpart. Eight constructor inputs and 3,209 samples; one constructor/rest-step case uses the actual watch default D. |
| `WatchAlarmParameterProbe.py` | 23 | Window-to-rate parameter selection, including every boundary and both sides. |
| `WatchAlarmRuleProbe.py` | 36 | Normal/sensitive rule core; strict 0.02, 0.1, 10-second and 120-second boundaries; nil/negative elapsed history. |
| `WatchArmedFilterProbe.py` | 72 | Complete armed filter; inclusive intensity thresholds, strict 10-second regrouping, inactive inputs and the `(1,1)` bypass sentinel. |
| `WatchHistoryCalibrationProbe.py` | 33 | 24 historical-rate cases and nine complete recursive searches. The search executes the original rate function, with 41 evaluations per search. |
| `WatchAlarmLifecycleProbe.py` | 56 | Complete alarm check and runtime-expiration predicate; dispatcher phase transitions, fired suppression and notification guards; original armed filter and alarm core called from the dispatcher. |

The movement count is eight constructor inputs × two comparisons plus 3,209 samples × two comparisons: watch/phone parity and watch/reference behavior. A sample comparison checks its output and retained state together; fields are not counted separately. The other totals count one comparison per case. Comparisons of another model against these same saved outputs are not counted again. Floating-point results use a `1e-10` tolerance for movement outputs and `1e-12` for constructor arithmetic; integer/Boolean states and the other tested outputs use exact equality.

The suite checks algorithm behavior with synthetic inputs. Date values, Swift metadata/copies/refcounts/exclusivity, notification objects, logging and fire callbacks are supplied by documented shims. `exp` and `vDSP_meanvD` use Python equivalents. The runtime predicate's strict **expiration − now < 300 seconds** and the alarm's strict **movement date > alarm time** execute their original branches, including equality and missing-object cases.

The dispatcher probe substitutes the phase-change callback after checking the original transition decisions; calibration inputs are preselected there. The rate/search probe supplies effective session end. The effective-end accessor, calibration entry guards, historical mode selection, constant D getter, and recorder binning are included in the reference from static tracing and clearly distinguished from executed coverage. This suite does not launch the whole app or validate sensors, haptics, audio, scheduling, watchOS recovery, or overnight/clinical accuracy. ARM64_32 parity is documented separately in `MOTION.md` and the decryption evidence.
