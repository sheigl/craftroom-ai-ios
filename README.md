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
scripts/payload_manifest.txt      the payload file list (single source of truth)
scripts/upload_payload.py         one-time staging + upload (runs where the payload lives)
scripts/fetch_payload.sh          CI (or local) fetch into Resources/{models,bins}
.github/workflows/build.yml       unsigned .ipa build + artifact
docs/SIDELOAD.md                  install path: CI artifact -> family iPad
docs/PHASE-A.md                   what to measure on the iPad + verdict rule
```

The ~3.9 GB payload (int8 DiT, fp16 VAE encoder/decoder, baked embeds/
sigmas/ids/BN bins) **never rides git** and never rides an actions/cache
key: it is fetched from the payload channel on cache-miss.

## One-time payload staging (runs on the box that holds the files)

Pick a channel and run from the dir holding `app_payload/` (e.g.
`ios_assets/`):

```
python3 scripts/upload_payload.py --channel release \
    --repo OWNER/CraftRoomAIPayload --tag payload-v1 \
    --dir app_payload
```

- `--channel release` — public GitHub Release on github.com/OWNER/…; each
  `.mlpackage` is zipped (stored, not deflated); bins verbatim. Per-asset
  limit is 5 GB; `dit_int8` (~3.7 GB) fits.
- `--channel hf` — repo on huggingface.co (private fine; CI then needs `HF_TOKEN`):
  ```
  python3 scripts/upload_payload.py --channel hf \
      --repo OWNER/craftroom-ai-payload --tag main --dir app_payload
  ```

`txt_embeds_neg_fp32.bin` (guidance > 1) is part of the manifest — re-upload
the tag (bump to payload-v2) whenever embeds are re-baked.

## Repo setup (once)

1. Create the **public** harness repo, push this tree.
2. Repo Settings → Secrets and variables → Actions → **Variables**:
   `PAYLOAD_REPO = OWNER/craftroom-ai-payload` (the channel repo).
   Add secret `HF_TOKEN` only for a private HF channel.
3. Make sure the payload tag exists (step "One-time payload staging").

## Build

Actions → "build-unsigned-ipa" → Run workflow (channel + tag).
First run (no cache) downloads ~4 GB, builds unsigned for the arm64 device
SDK, and uploads `CraftRoomAI-unsigned-ipa` split into <2 GB parts
(retention 1 day). Later runs hit `actions/cache` and take ~10 min.

Cost notes (Free plan): macOS runners are billed at 10x; ~30 min x 10 = 300
of the 2,000 monthly free units on the first run, ~100 on cached runs.
Artifact free storage is 500 MB with 1-day retention — fine for one ipa.
Runner pinning: the workflow starts at `macos-latest`; pin it to a concrete
`macos-NN` image as soon as one is known good.

## Install + run

- Install path (Sideloadly/AltStore, free Apple ID, 7-day re-sign):
  **docs/SIDELOAD.md**
- What to measure and the Phase A verdict rule: **docs/PHASE-A.md**
