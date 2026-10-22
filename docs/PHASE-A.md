# Phase A: on-device measurement runbook

**Question:** the int8 CoreML DiT at the SHIP recipe — 768 px, 30 steps,
**guidance 3.0 => 60 forwards** — on the family iPad: total seconds and peak
memory? (Guidance 1.0 => 30 forwards is the diagnostic baseline, not the
product.)

Reference points to beat / to measure against:
- desktop2 Arc Pro fp16: ~990 ms per forward -> g3.0 ~ 60 s on the desktop GPU.
- M4-class CoreML estimates for int8: 2.5-8 s/forward is the plausible
  band; 60 forwards at even 1.5 s is 90 s — the budget (10-30 s) is the
  product target, not a Phase A pass/fail. Phase A only needs the REAL number.

## Matrix (run in this order, same photo)
| # | Compute units | Guidance | Forwards | Purpose |
|---|---------------|----------|----------|---------|
| 1 | All (ANE+GPU) | 1.0 | 30 | CoreML placement sanity + baseline |
| 2 | All (ANE+GPU) | 3.0 | 60 | **the ship number** |
| 3 | CPU+GPU       | 3.0 | 60 | ANE involvement cost/benefit |
| 4 | CPU only      | 3.0 | 60 | floor |

- One landscape family photo (center-cropped to 3:2 in-app), seed 0.
- Run 1 is the first launch: model compile runs on-device (10+ min) and is
  NOT part of the loop number; runs 2-4 reuse the cache.
- For each row: run 3 times, screenshot the stats card each time, take the
  MEDIAN. Note thermal state (fanless tablets downclock run 2 after 1).

## What the stats card means
```
units / guidance      what was set
model load           first launch = on-device compile (minutes), cache = seconds
prep / vae encode    photo -> tokens
loop (N fwd)         the 30- or 60-forward number: THIS IS THE GATE'S DATA
  per step avg       loop/N (each step includes BOTH CFG forwards at g>1)
decode               unpatchify + VAE fp16 decode (768x768)
total / peak MB      end-to-end + MemoryGauge footprint high-water
```
Report all six numbers + the photo name + device/capacities.

## Verdict rule (against the SHIP row: All, g3.0, median)
- **<= 30 s**  -> Phase A passes at ship guidance: Phase B = productization
  (UI, palette, export), guidance-distilled no-CFG arm optional.
- **30-90 s**  -> passes on mechanism, fails the budget: Phase B priority #1
  = the no-CFG arm (guidance-distilled klein variant or latent-domain ref
  conditioning) halving 60 -> 30 forwards, + int4 arm.
- **> 90 s**   -> mechanism proven, gap large: add KV-cache-free ref-token
  caching research and revisit the iPad Pro floor for v1.
Also record: peak MB vs the device's memory class, and qualitative line-art
quality (the ladder verdict said g3.0 style; the int8 export must not wash
it out — compare to the g3.0 B65 arm in eval/sheet_ladder.png).

## Known sharp edges
- `timestep` is the flow sigma (t/1000), never the raw 1000-scale (NaN storm).
- Guidance > 1 needs `txt_embeds_neg_fp32.bin` in the payload; the app
  refuses loudly if it is missing.
- First run per model set recompiles — the load line, not the loop line.

## When it fails: reading the evidence (0.2.0+)

The iPad has no console and a memory kill leaves no crash report, so the app
carries its own record:

- **Header line** under the title: `v0.2.0 (2) · <hw.machine> · iPadOS <ver> ·
  <RAM> MB RAM · <free> free · footprint <MB>`. Screenshot that first — it
  answers "which chip, which OS, how much headroom".
- **`Documents/phaseA.log`** — written as the run proceeds: the header summary,
  one line per stage, a line every 5 diffusion steps (milliseconds, footprint,
  free MB), and the exact error. Pull it with Finder → iPad → *Craft Room AI* →
  phaseA.log (UIFileSharingEnabled), or from the Files app on the device. After
  a crash it ends at the last thing that ran, which is the whole point.
- **Errors name the model and the compute-unit set**, e.g.
  `Loading models (All (ANE+GPU))… failed: dit_int8 [All (ANE+GPU)]: <CoreML
  message>`. If a set cannot build a plan, the app now degrades to
  **CPU+GPU** and then **CPU only** automatically, and the stats card's
  `units:` line reports the set that actually ran — compare it to the picker.

### The -14 class of failure

`failed to build model execution plan using a model architecture file` is a
CoreML plan-build refusal. Two causes matter here:

1. **OS too old for the mlprogram spec.** The shipped DiT is
   `specificationVersion 8` (= iPadOS/iOS **18**), even though the export asked
   for iOS17 — the unquantized probe is spec 8 too, so it is the conversion,
   not the int8 quantization. On an iPadOS 17 device this refuses to load; the
   fix is to update the iPad, or re-export the DiT at spec 7 on desktop2 and
   re-upload the payload.
2. **ANE cannot plan this shape/quantization.** Then the CPU+GPU (or CPU only)
   fallback should load and run — if it does, the timing row to report is that
   fallback's, and the ANE arm is a Phase B problem, not a Phase A blocker.
