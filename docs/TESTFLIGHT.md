# TestFlight — the device loop without a Mac

The unsigned-IPA path in `build.yml` exists so Sideloadly on a Mac can re-sign
and install. That route is now the fallback, not the plan: the build machine is
a MacBookPro10,2 (8 GB RAM, no Xcode, unusable device-support table for
iPadOS 26), so it cannot install or debug on the iPad at all.

TestFlight sidesteps that entirely. The iPad installs from App Store Connect,
so the Xcode ↔ iOS-version pairing never enters the picture.

## What ships

- Bundle: `com.sheigl.CraftRoomAI` ("Craft Room AI")
- Version: from `project.yml` (`MARKETING_VERSION`)
- Build: the workflow's run number (override with `build_number`)
- The header on the device must read `v<version> (<build>)` — that is the
  identity check from the handoff, and it is how you know an old bundle is
  not still installed.

## One-time setup

1. **App Store Connect API key** — Users and Access → Integrations → Team Keys
   → generate with the **Admin** role. Download the `.p8` once.
2. **Repo secrets** — `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (the file,
   `base64 -w0`), `APPLE_TEAM_ID`.
3. **App record** — App Store Connect → Apps → **+** → New App: iOS,
   "Craft Room AI", SKU `craftroomai`, bundle ID `com.sheigl.CraftRoomAI`.
   (UI only: `POST /v1/apps` is refused by the API.)
4. **Tester** — TestFlight → Internal Testing → group → add the Apple ID used
   on the iPad. Install the TestFlight app on the iPad and accept the invite.

## Each build after that

```
gh workflow run testflight.yml          # build number defaults to run number
```

Then:

```
archive → signed → uploaded → "Waiting for processing" (minutes: the ipa is
~50 MB since ITMS-90558 moved the models to a first-launch download) → the
iPad shows the build → tap Update → open the app → "Download models" (~4 GB
over Wi-Fi; the card shows MB progress and Retry resumes per file)
```

There is no cable, no re-sign step, no 7-day profile expiry, and nothing to
reassemble from split artifacts.

## Reading results off the device

The app writes `Documents/phaseA.log` and shows the tail in its Log panel
(Reload / Copy). `UIFileSharingEnabled` is set, so the same file is reachable
from Files → On My iPad → Craft Room AI, and pullable over USB with any AFC
client — no Xcode, no developer pairing:

```bash
~/pdm3/bin/pymobiledevice3 apps pull com.sheigl.CraftRoomAI \
    /Documents/phaseA.log ./phaseA.log
```

That is the whole feedback channel: build in CI, install via TestFlight, pull
one text file back.

## Auto mode (remote ladder cells)

With a developer tunnel on the relay Mac
(`sudo pymobiledevice3 remote start-tunnel`), the harness can be killed and
relaunched with arguments, so measurement runs need zero taps on the iPad:

```bash
pymobiledevice3 developer dvt launch com.sheigl.CraftRoomAI --args \
    --auto --units=cpu_gpu --guidance=1.0 --max-steps=2 --seed=0
```

`--units=all|cpu_gpu|cpu_only`, guidance/seed as shown, `--max-steps` 1–30.
Auto mode uses the bundled synthetic `test_photo.jpg` (timing is
content-independent — the pipeline geometry is fixed), and ends every
successful cell with one machine-readable line in `phaseA.log`:

```
AUTO-RESULT units=CPU+GPU guidance=1.0 steps=2 median_step_ms=266000 median_forward_ms=266000 peak_mem_mb=4564
```
