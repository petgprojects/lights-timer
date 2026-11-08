# Plaintext recovery and provenance

Both architecture slices of the supplied Sleep Cycle watch executable were successfully decrypted on November 7, 2026. The original `Sleep Cycle.ipa` was preserved.

| Item | SHA-256 |
| --- | --- |
| Original IPA | `b5aa775f46e6ca42cfa50fb89a954a443dcdd5156032b45680215cd0498c4143` |
| Recovered universal `SCWatchExtension` | `3e657e7c1e619a3bae7d13f3627b0fe0b4d204d4c45ef4f16aef673051c33e5d` |
| ARM64 protected plaintext region | `821c255fc8eddde5eac03b4ecebfe84ed8f7977f047b5715a1dc15803b6a09e3` |
| ARM64_32 protected plaintext region | `1816ce58424adbe90d87b805fbbfaeba3a096afb3d637edd081bc7b3bf489d80` |

## Successful route

The earlier LLDB attachment and watchOS Simulator attempts failed to provide plaintext. The successful method used the open-source [FairPlayed helper](https://github.com/morzelowski/FairPlayed), audited locally at commit `bad7df138839b5e0ac8b9f20cc4689140b8436fb`, with a small Mach-O parser change to support the watch's ARM64_32 slice.

1. Extract the watch extension and two control frameworks from the user's licensed IPA into a minimal local helper payload. Supply each component's package license metadata according to the original IPA's replication manifest. License records remain private and locally ignored.
2. Build and development-sign the helper for the user's connected iPhone. Only the helper is developer-signed; no production source or existing Sleep Cycle installation is replaced.
3. Run its local export path. It maps each encrypted range read-only, uses the device's `mremap_encrypted` mapping operation, and reads the resulting mapped pages with `vm_read_overwrite` into a local output copy.
4. Extend its parser from only 64-bit Mach-O headers to both 28-byte and 32-byte headers, and accept CPU_TYPE_ARM64_32 as well as CPU_TYPE_ARM64 when selecting universal-file slices. The algorithm bytes themselves are not patched.
5. Copy the resulting archives from the helper's document container to the local research cache. Exported archives omit `SC_Info` records.
6. Verify the results independently, then uninstall `com.PeterGelgor.SleepCycleResearch`. Uninstallation succeeded. The user's actual Sleep Cycle installation remains in place.

The device was an iPhone 14 Pro running iOS 27.0, with Developer Mode enabled. No jailbreak, jailbreak exploit, root credential extraction, or debugger access to the release Sleep Cycle process was used. Success here is an observed property of this device/package combination, not a guarantee for every OS or application.

The helper reported all pages readable for both watch slices, the phone `GMFoundation`, and `SleepCycleSDK`, and exited successfully. Helper logs alone are not accepted as proof of valid plaintext; the independent checks below establish that.

## Independent checks

[VerifyDecryptedMachO.py](VerifyDecryptedMachO.py) compares recovered protected pages with the **original IPA's embedded pre-encryption CodeDirectory hash tables**. It supports both thin and universal Mach-O files, including 32-bit headers. It never reads or emits decryption keys or license records.

| Component | Protected 4 KB pages | Original tables checked | Result |
| --- | ---: | --- | --- |
| Watch ARM64 | 540 | SHA-1 and SHA-256 | Every page matches |
| Watch ARM64_32 | 540 | SHA-1 and SHA-256 | Every page matches |
| Phone GMFoundation ARM64 | 580 | SHA-1 and SHA-256 | Every page matches |
| Phone SleepCycleSDK ARM64 | 332 | SHA-1 and SHA-256 | Every page matches |

Two additional controls strengthen the result:

- The SDK's entire 1,359,872-byte protected region matches the known official SDK plaintext byte-for-byte.
- Changing one protected byte in an in-memory test copy makes both original hash tables reject the corresponding page. No damaged binary is substituted for the recovered artifact.

This verifies page integrity against the original package's pre-encryption tables. It is not an independent validation of Apple's CMS certificate chain. The complete machine-readable results and controls are in [decryption-proof.json](decryption-proof.json).

## Reproduce the page check

From the repository root:

```sh
python3 plans/sleep-cycle-watch/VerifyDecryptedMachO.py \
  'Sleep Cycle.ipa' \
  'Payload/GoodMorning.app/Watch/SCWatch.app/PlugIns/SCWatchExtension.appex/SCWatchExtension' \
  '.research-cache/sleep-cycle-deep/local-decryption/decrypted/SCWatchExtension'
```

The recovered binaries, helper source/build, and raw logs remain in the locally ignored `.research-cache/sleep-cycle-deep/local-decryption/`. The per-component decrypted files are under `decrypted/`. No vendor executable bytes, package license metadata, or device credentials are included in the report or Python models. [PROBES.md](PROBES.md) explains how the separate original-instruction checks consume these local binaries.
