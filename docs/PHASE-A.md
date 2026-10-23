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

## When it fails: reading the evidence (0.3.0+)

The iPad has no console and a memory kill leaves no crash report, so the app
carries its own record and shows it on screen:

- **Header line** under the title: `v0.3.0 (3) · <hw.machine> · iPadOS <ver> ·
  <RAM> MB RAM · <free> free · footprint <MB>`. Screenshot that first.
- **Memory verdict line** right under it, in red when the numbers cannot work:
  `<hw.machine> · <RAM> MB RAM · app budget <free> MB · weights <size> MB →
  plausible | IMPOSSIBLE (would be a silent kill)`. The weights figure is read
  from the installed payload (`*.mlmodelc/weights/weight.bin`), not assumed.
- **Log panel** at the bottom of the screen — the tail of
  `Documents/phaseA.log`, with **Reload** and **Copy**. Use this when the Files
  folder is unavailable: a screenshot of the tail is the evidence. The file is
  still written (and closed) after every line, so a kill leaves it complete.
  Saved copy: Files → On My iPad → *Craft Room AI* → `phaseA.log`.
- **Errors name the model and the compute-unit set**, e.g.
  `Loading models (All (ANE+GPU))… failed: dit_int8 [All (ANE+GPU)]: <CoreML
  message>`.

### One compute-unit set per launch (0.3.0)

0.2.0 degraded `All → CPU+GPU → CPU only` inside one process. On device that
turned a recoverable plan refusal into a silent kill: each attempt maps the
3.9 GB weight file again and the failed plan's pages are not returned first.
0.3.0 makes **one** attempt, on the set you picked, and never retries by
itself. To test another set, change the picker and tap Generate again (the
engine drops the models when the set changes) — or relaunch if a kill left the
process dirty.

`Load even if the preflight says impossible` is **on** by default: a kill still
leaves the budget-vs-weights line in the log, so attempting is the measurement.
Turn it off to make the preflight stop the run instead (safe mode).

### The -14 class of failure

`failed to build model execution plan using a model architecture file` is a
CoreML plan-build refusal. Two causes matter here:

1. **OS too old for the mlprogram spec.** The shipped DiT is
   `specificationVersion 8` (= iPadOS/iOS **18**), even though the export asked
   for iOS17 — the unquantized probe is spec 8 too, so it is the conversion,
   not the int8 quantization. The test iPad is on iPadOS 26.6.6, so **this
   cause is ruled out** for it.
2. **The device refuses this plan** (ANE or GPU cannot adopt a 4B int8
   transformer). With 0.3.0 this is visible per set: pick `CPU only` and try
   again. If CPU-only loads and runs, the timing row to report is that one, and
   the ANE/GPU arms are a Phase B problem.
3. **The process is killed instead of refused** (app vanishes, no error text).
   That is memory, not planning: iOS kills the process when the weights do not
   fit the per-app budget. The log's `load:` line and the on-screen verdict
   already hold the two numbers; compare them.
