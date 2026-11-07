# ANE plan probe (CI)

`scripts/ane_plan_probe.swift` + `.github/workflows/ane-plan-probe.yml` report Core ML's
compute placement for a compiled device-v2 package, plus one real `.cpuAndNeuralEngine`
forward on the io-contract shapes.

Design, output contract and the interpretation table live in the Linux repo at
`sdxl/teacher/device_v2/ci/ANE_PROBE.md` — read its **Result (2026-11-07)** section first:
GitHub's `macos-15` runner is an `Apple M1 (Virtual)` VM with no Neural Engine
(`MLModel.availableComputeDevices = gpu,cpu`), so `pref_ane` is structurally 0 there. The
workflow is a package / LUT-placement / regression probe, **not** an ANE verdict.

Runner: `macos-15`. One job per variant; ~20 min (6-bit) to ~50 min (split_einsum, whose
`MLComputePlan.load` alone takes ~15 min per compute-units setting).

## Inputs

- `parts` — release-asset URLs of a multi-part zip, comma- or space-separated. Parts are
  concatenated in order, exactly like `compile-mlpackage.yml`.
- `package_name` — the `.mlpackage` folder inside the zip. Empty = the only `.mlpackage`.
- `label` — echoed in every `PLAN`/`FORWARD` line and in the artifact name.

## Bootstrap push (works before this file is on `main`)

GitHub only dispatches a workflow that already exists on the default branch, so on this branch
the variant travels in a push commit message (`ane-probe label=… package=… parts=…`).
Pushes without that marker — e.g. ordinary code commits — are skipped.

```sh
# 6-bit split_einsum (release spike-t3-2026-11-06)
git commit --allow-empty -m "ane-probe label=6bit-split-einsum package=Unet_ControlNet_canny1200_split_einsum_6bit.mlpackage parts=https://github.com/sheigl/craftroom-ai-ios/releases/download/spike-t3-2026-11-06/se-part-00,https://github.com/sheigl/craftroom-ai-ios/releases/download/spike-t3-2026-11-06/se-part-01"
git push origin ci/ane-probe
```

```sh
# 6-bit sdpa (release spike-t2-2026-11-06)
git commit --allow-empty -m "ane-probe label=6bit-sdpa package=Unet_ControlNet_canny1200_6bit.mlpackage parts=https://github.com/sheigl/craftroom-ai-ios/releases/download/spike-t2-2026-11-06/part-00,https://github.com/sheigl/craftroom-ai-ios/releases/download/spike-t2-2026-11-06/part-01"
git push origin ci/ane-probe
```

## `workflow_dispatch` (once this file is on the default branch)

```sh
gh workflow run ane-plan-probe.yml --repo sheigl/craftroom-ai-ios \
  -f label=6bit-sdpa \
  -f package_name=Unet_ControlNet_canny1200_6bit.mlpackage \
  -f parts=https://github.com/sheigl/craftroom-ai-ios/releases/download/spike-t2-2026-11-06/part-00,https://github.com/sheigl/craftroom-ai-ios/releases/download/spike-t2-2026-11-06/part-01
```

```sh
gh workflow run ane-plan-probe.yml --repo sheigl/craftroom-ai-ios \
  -f label=fp16 \
  -f package_name=Unet_ControlNet_canny1200.mlpackage \
  -f parts=https://github.com/sheigl/craftroom-ai-ios/releases/download/payload-fp16-2026-11-07/fp16-part-00,https://github.com/sheigl/craftroom-ai-ios/releases/download/payload-fp16-2026-11-07/fp16-part-01,https://github.com/sheigl/craftroom-ai-ios/releases/download/payload-fp16-2026-11-07/fp16-part-02,https://github.com/sheigl/craftroom-ai-ios/releases/download/payload-fp16-2026-11-07/fp16-part-03,https://github.com/sheigl/craftroom-ai-ios/releases/download/payload-fp16-2026-11-07/fp16-part-04
```

(`fp16` is 7.6 GB: 5×1,572,864,000 + 1,350,431,604 B, in-zip folder
`Unet_ControlNet_canny1200.mlpackage`.)

## Reading the result

```sh
gh run list --repo sheigl/craftroom-ai-ios --workflow ane-plan-probe.yml --limit 5
gh run watch <run-id> --repo sheigl/craftroom-ai-ios
gh run download <run-id> --repo sheigl/craftroom-ai-ios -n ane-plan-probe-6bit-sdpa -D out/
```

Log lines:

- `PLAN label=<l> units=<u> ops=<n> pref_ane=<a> pref_gpu=<g> pref_cpu=<c> unsupported=<x>`
  once per `MLComputeUnits` (`cpuAndNeuralEngine`, `cpuAndGPU`, `all`), followed by up to ten
  `  UNSUPPORTED <op> x<count>` (compute ops with no device) and, for the ANE config, ten
  `  NOT_ANE <op>@<device> x<count>` lines.
- `INFO available_compute_devices=…` — the devices the plan was computed against; a
  `WARN no_ane_device_on_host` line means the ANE half of the question cannot be answered here.
- `INFO plan_detail … weight_ops=<n> lut_placement=…` — weight-materializing ops (`const`,
  1,194 `ios16.constexpr_lut_to_dense` for the 6-bit packages) are reported separately and
  never counted as unsupported; `lut_placement=none` means the palette is expanded outside the
  plan.
- `FORWARD label=<l> units=ane ok=<true|false> ms=<t> footprint_mb=<m>` — one real prediction;
  `footprint_mb` is `task_vm_info.phys_footprint`, so mmap'd weights do not count (a forward can
  read ~44 MB for a 2.9 GB model — that is the runtime keeping the file mapped, not a packed
  verdict).
- `SUMMARY` block last.

The job stays green as long as the probe binary runs and prints at least one `PLAN` line — a
refused or killed forward is the measurement, not a CI failure.

## Local build (optional)

```sh
mkdir -p build
xcrun swiftc -O -parse-as-library scripts/ane_plan_probe.swift -o build/ane_plan_probe
./build/ane_plan_probe path/to/Model.mlmodelc --label local
```
