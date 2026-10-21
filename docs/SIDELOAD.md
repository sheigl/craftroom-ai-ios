# Sideload: CI artifact -> the family iPad

One build, three hops: GitHub Actions artifact -> a Mac on your Tailscale
net -> iPad over USB. No $99 developer account: this signs with a **free
Apple ID** (self-signing via Sideloadly or AltStore), which costs a 7-day
certificate lifetime and a 3-app-ID quota.

## 0. iPad prep (once)
- Settings → Privacy & Security → **Developer Mode** → on → reboot.
- Enough free storage: the app bundle is ~4 GB (int8 DiT dominates). Keep
  the iPad plugged into power during install + first launch.

## 1. Get the ipa (on the Mac)
Download the `CraftRoomAI-unsigned-ipa` artifact from the Actions run
(the zip contains `CraftRoomAI-unsigned.ipa.part-aa`, `-ab`, ...), then:

```
mkdir ipa && mv CraftRoomAI-unsigned.ipa.part-* ipa/
cat ipa/CraftRoomAI-unsigned.ipa.part-* > CraftRoomAI-unsigned.ipa
ls -l CraftRoomAI-unsigned.ipa        # expect several GB
```

Sanity: `unzip -l CraftRoomAI-unsigned.ipa | head` lists
`Payload/CraftRoomAI.app/...`.

## 2. Sign + install (Sideloadly)
1. Install Sideloadly on the Mac (works on the macOS 15.8.1 OCLP box —
   CoreDevice/pairing covers iPadOS 17+).
2. Open Sideloadly, drag the ipa in, enter the **Apple ID** used on the iPad,
   Start. Keep the iPad unlocked and USB-attached.
3. On the iPad: Settings → General → VPN & Device Management → trust your
   own developer certificate.
4. Launch. **First launch is slow (10+ min, screen on, app foreground):**
   CoreML compiles the three models on-device (3.7 GB int8 DiT). Every later
   launch loads the cached `.mlmodelc` and is fast.

AltStore self-signing works the same way and additionally refreshes the
signature over Wi-Fi on the same computer, which beats re-running
Sideloadly every 7 days:
github.com/Altstore/AltStore

## 3. The 7-day clock
Free-Apple-ID signatures expire after 7 days; the app refuses to open.
Sideloadly: re-run the same ipa over USB. AltStore: auto-refresh while the
phone is on the same Wi-Fi as the Mac. The expiry is a sideload tax, not an
app defect.

## Troubleshooting
- `0xe8004001` / "ApplicationVerificationInvalid": developer certificate not
  trusted — redo step 2.3.
- Install fails "No code signature": the artifact's parts were not
  reassembled (`cat` order matters: `part-aa` first).
- Instant crash at model load on an M-class device with low free RAM: the
  int8 DiT wants a generous memory budget — MemoryGauge in the stats card
  shows the peak; see docs/PHASE-A.md.
