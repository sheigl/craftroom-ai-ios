---
license: apache-2.0
base_model:
  - black-forest-labs/FLUX.2-klein-base-4B
pipeline_tag: image-to-image
tags:
  - core-ml
  - coreml
  - int8-quantization
  - image-to-image
  - lora
  - ios
  - on-device
---

# Craft Room AI — compiled CoreML device payload

Pre-compiled **CoreML** (`.mlmodelc`) artifacts of the Craft Room AI
coloring-page pipeline: **FLUX.2-klein-base-4B** merged with a custom
image-to-image **coloring LoRA** (v2.1, rank 16, 1500 steps), quantized and
compiled for on-device inference on Apple silicon (CPU/GPU/ANE via the
`neural_network` MLProgram format).

This repo is the **first-launch download** for the Craft Room AI iOS test
harness. It is not a transformers/diffusers checkpoint set — it is the exact
runtime payload an iPad fetches and runs unmodified.

## Why the payload lives here

Apple's `ITMS-90558` limit caps a thinned app bundle below 4 GB; the int8
DiT alone is 3.88 GB of `weight.bin` (old bundled `.app`: 4,078,949,396 B).
The ipa ships only the harness + small baked bins (~50 MB); the models come
from this repo over HTTPS (public, Range-resumable CDN — no token needed on
device).

## Contents (`device-v1/`)

| Path | Size | What |
|---|---|---|
| `dit_int8.mlmodelc/weights/weight.bin` | 3,698 MiB | DiT, per-channel int8 weights, fp16 activations |
| `vae_decoder.mlmodelc/…` | ~95 MiB | VAE decoder, fp16 (static 48×48 latent input) |
| `vae_encoder_land_1248x832.mlmodelc/…` | ~66 MiB | VAE encoder, fp16, static 1248×832 landscape input |
| `manifest.json` | small | every file: `path`, `size`, `sha256`, `url` |

The app verifies every file against `manifest.json` (size before install,
sha256 once per freshly downloaded file). Re-publishing a payload version
means regenerating the manifest with
`scripts/publish_device_payload.py` in the
[harness repo](https://github.com/sheigl/craftroom-ai-ios) — do not hand-edit.

## Provenance

- Base: `black-forest-labs/FLUX.2-klein-base-4B` (Apache-2.0).
- Adapter: custom coloring LoRA v2.1 (rank 16, 1500 steps), merged into the
  FP16 checkpoint before export (the "Converter v2.1" config approved in the
  project's evaluation rounds).
- Export: diffusers `Flux2KleinPipeline` edit path → Core ML via
  `coretool`/`coremlbuild` compile-on-target on a GitHub Actions
  `macos-latest` runner (iOS 17 target, arm64). `weight.bin` is therefore
  **device-compiled** and only loadable by Core ML, not re-loadable as a
  portable checkpoint.
- The companion bake (txt embeds, BN stats, sigmas, position ids) ships as
  flat little-endian bins inside the ipa, not here.

## License / attribution

Apache-2.0, inherited from FLUX.2-klein-base-4B (Black Forest Labs). The
quantization, compilation and LoRA are the project's contribution under the
same license.
