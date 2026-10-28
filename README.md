# Craft Room AI — iOS perf harness (Phase A)

SwiftUI harness that answers one question on the family iPad: **does the
FLUX.2-klein-base-4B + coloring-LoRA converter (int8 CoreML) generate a
coloring page inside the 10-30 s budget, within memory, on this hardware?**
It is the Phase A gate for the sellable native port; the product app's repo
is private, this harness is public (model weights are Apache-2.0).

Pipeline reproduced 1:1 from the diffusers `Flux2KleinPipeline` edit path:
VAE-encode the photo (1248x832 -> 104x156x32), patchify + BN-normalize to
4056 reference tokens, 30-step flow loop over 2304 noise tokens in a
6360-token sequence, unpatchify + VAE-decode to 768x768. Guidance 1.0 runs 30
DiT forwards; the ladder verdict ships **guidance 3.0** (2.0 fallback),
which runs the true-CFG pair — baked cond + uncond Qwen3 embeds,
`v = uncond + g*(cond - uncond)` — at **60 forwards**. See
`docs/PHASE-A.md`.

## Layout

```
project.yml                       xcodegen project definition (CI generates)
Sources/CraftRoomAI/*.swift       app: payload loader, CoreML pipeline, UI
Resources/bins/*.bin              small baked tensors (committed, ~31 MB)
Resources/device/device_manifest.json
                                  download list for the models (committed)
scripts/publish_device_payload.py publish compiled .mlmodelc to the public HF repo
scripts/payload_manifest.txt      legacy mlpackage channel (superseded)
.github/workflows/testflight.yml  signed build → TestFlight (the delivery path)
.github/workflows/build.yml       unsigned .ipa build (legacy sideload)
docs/TESTFLIGHT.md                device loop through App Store Connect
docs/PHASE-A.md                   what to measure on the iPad + verdict rule
```

## Payload: downloaded on first launch

Apple's ITMS-90558 cap (thinned app bundle must be under 4 GB) rules out
bundling the int8 DiT (3.88 GB of weight.bin alone; the old .app measured
4,078,949,396 B). The models therefore live as a public, carded model
release on Hugging Face —
[`sheigl/craftroom-ai-payload`](https://huggingface.co/sheigl/craftroom-ai-payload)
(`device-v1/`) — the ipa ships the harness + bins (~50 MB) and the app
mirrors `device_manifest.json` into
`Application Support/CraftRoomPayload/` on first launch — per-file download
with size check, one-time sha256 verification, and per-file resume on Retry.
The manifest is committed so every build carries the exact download list.

To re-publish after a model re-bake (runs on the box that holds a built ipa
of this app — the .mlmodelc are compiled by Xcode on the CI runner):

```
python3 scripts/publish_device_payload.py \
    --ipa dist/CraftRoomAI-unsigned.ipa \
    --repo sheigl/craftroom-ai-payload --prefix device-v2 \
    --manifest-out Resources/device/device_manifest.json \
    --model-card scripts/device_payload_card.md
```

Commit the regenerated manifest, bump the prefix references, push. The
`--prefix` per payload version lets a device keep serving an older build's
expectations. (Superseded legacy scripts: `upload_payload.py` /
`fetch_payload.sh` / `payload_manifest.txt` shipped mlpackages into the
bundle — pre-ITMS-90558.)

## Build (TestFlight — the delivery path)

One-time App Store Connect setup (API key, secrets, app record, tester):
**docs/TESTFLIGHT.md**. Then every ship is one command:

```
gh workflow run testflight.yml          # from the harness repo
```

The ipa is ~50 MB, so archive → upload → "processing" takes minutes, and the
iPad downloads the app from the TestFlight app. The first launch then offers
the ~4 GB model download (models total ~3,698 MiB plus metadata).

Cost notes (Free plan): macOS runners are billed at 10x; a ~10 min signed
run is ~100 of the 2,000 monthly free units. Runner pinning: the workflow
starts at `macos-latest`; pin it to a concrete `macos-NN` image as soon as
one is known good.

## Install + run

- Install path (Sideloadly/AltStore, free Apple ID, 7-day re-sign):
  **docs/SIDELOAD.md**
- What to measure and the Phase A verdict rule: **docs/PHASE-A.md**
