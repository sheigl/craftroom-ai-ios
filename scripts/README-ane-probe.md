# ANE plan probe (CI)

`scripts/ane_plan_probe.swift` + `.github/workflows/ane-plan-probe.yml` answer one
question without an iPad install: **does the Neural Engine accept the device-v2
UNet+ControlNet graph, and do palettized (LUT) weights stay packed?**

Design, output contract and the interpretation table live in the Linux repo at
`sdxl/teacher/device_v2/ci/ANE_PROBE.md`. Runner: `macos-15` (Apple silicon, needs
the macOS 15 `MLComputePlan` API). One job per variant, ~20 min.

## Invoking it

`parts` takes the release-asset URLs of a multi-part zip, comma- or space-separated
(the parts are concatenated in order, exactly like `compile-mlpackage.yml`).
`package_name` may be left empty: the workflow then uses the only `.mlpackage` in
the unzipped tree. `label` is echoed in every `PLAN`/`FORWARD` line.

### 6-bit `split_einsum` variant (release `spike-t3-2026-11-06`)

```sh
gh workflow run ane-plan-probe.yml \
  --repo sheigl/craftroom-ai-ios \
  --ref ci/ane-probe \
  -f label=6bit-split-einsum \
  -f package_name=Unet_ControlNet_canny1200_split_einsum_6bit.mlpackage \
  -f parts=https://github.com/sheigl/craftroom-ai-ios/releases/download/spike-t3-2026-11-06/se-part-00,https://github.com/sheigl/craftroom-ai-ios/releases/download/spike-t3-2026-11-06/se-part-01
```

### 6-bit `sdpa` variant (release `spike-t2-2026-11-06`)

```sh
gh workflow run ane-plan-probe.yml \
  --repo sheigl/craftroom-ai-ios \
  --ref ci/ane-probe \
  -f label=6bit-sdpa \
  -f package_name=Unet_ControlNet_canny1200_6bit.mlpackage \
  -f parts=https://github.com/sheigl/craftroom-ai-ios/releases/download/spike-t2-2026-11-06/part-00,https://github.com/sheigl/craftroom-ai-ios/releases/download/spike-t2-2026-11-06/part-01
```

## Reading the result

```sh
gh run list --repo sheigl/craftroom-ai-ios --workflow ane-plan-probe.yml --limit 5
gh run watch <run-id> --repo sheigl/craftroom-ai-ios
gh run download <run-id> --repo sheigl/craftroom-ai-ios -n ane-plan-probe-6bit-sdpa -D out/
```

Log lines:

- `PLAN label=<l> units=<u> ops=<n> pref_ane=<a> pref_gpu=<g> pref_cpu=<c> unsupported=<x>`
  once per `MLComputeUnits` (`cpuAndNeuralEngine`, `cpuAndGPU`, `all`), followed by
  up to ten `  UNSUPPORTED <op> x<count>` lines.
- `FORWARD label=<l> units=ane ok=<true|false> ms=<t> footprint_mb=<m>` — one real
  `.cpuAndNeuralEngine` prediction on the io-contract shapes.
  `footprint_mb` separates packed from de-palettized weights by order of magnitude
  (~2.9 GB packed / ~7.3 GB fp16 / ~15.3 GB fp32).
- `SUMMARY` block last.

The job stays green as long as the probe binary runs and prints at least one `PLAN`
line — a refused or killed forward is the measurement, not a CI failure.

## Local build (optional)

```sh
mkdir -p build
xcrun swiftc -O -parse-as-library scripts/ane_plan_probe.swift -o build/ane_plan_probe
./build/ane_plan_probe path/to/Model.mlmodelc --label local
```
