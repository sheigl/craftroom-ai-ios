#!/usr/bin/env python3
"""Publish the COMPILED device payload (.mlmodelc dirs) to the public HF repo
so the app can download the models on first launch.

Why (2026-10-28): ITMS-90558 — Apple rejects any thinned app bundle of
4 GB+; the int8 DiT is 3.88 GB of weight.bin on its own, so the models can
never ride inside the ipa again. The ipa ships the harness + the small bins;
the app reads device_manifest.json (bundled) and mirrors this tree into
Application Support/CraftRoomPayload/ on first launch.

The .mlmodelc directories are produced by xcodebuild on the CI runner — the
authoritative source is a built ipa (signed TestFlight build or the unsigned
artifact). GitHub release assets cap at 2 GB and need a token; the public HF
repo has neither problem (LFS, Range-resumable CDN, no auth on the device).

Layout in the repo:  <prefix>/<name>.mlmodelc/<relpath>
                     <prefix>/manifest.json

Run on the box that holds the ipa:
  python3 scripts/publish_device_payload.py \
      --ipa dist/CraftRoomAI-unsigned.ipa \
      --repo sheigl/craftroom-ai-payload --prefix device-v1 \
      --manifest-out Resources/device/device_manifest.json
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile

MODELS = ["dit_int8.mlmodelc", "vae_decoder.mlmodelc", "vae_encoder_land_1248x832.mlmodelc"]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while chunk := fh.read(1 << 22):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa", required=True, help="built ipa to take the compiled .mlmodelc out of")
    ap.add_argument("--repo", required=True, help="HF namespace/repo (made public if created)")
    ap.add_argument("--prefix", default="device-v1")
    ap.add_argument("--staging", default="/mnt/1TB/craftroom-device-payload")
    ap.add_argument("--manifest-out", default="Resources/device/device_manifest.json")
    a = ap.parse_args()

    os.makedirs(a.staging, exist_ok=True)
    stage = tempfile.mkdtemp(prefix="payload-", dir=a.staging)
    print(f"unzipping mlmodelc from {a.ipa} into {stage}")
    subprocess.run(
        ["unzip", "-q", a.ipa, "Payload/CraftRoomAI.app/*.mlmodelc/*", "-d", stage],
        check=True,
    )
    app = os.path.join(stage, "Payload", "CraftRoomAI.app")
    files = []
    total = 0
    for m in MODELS:
        src = os.path.join(app, m)
        if not os.path.isdir(src):
            sys.exit(f"missing {m} in the ipa")
        for root, _d, fs in os.walk(src):
            for f in fs:
                full = os.path.join(root, f)
                rel = os.path.relpath(full, app)  # keeps "<name>.mlmodelc/..."
                size = os.path.getsize(full)
                print(f"sha  {rel}  ({size/2**20:.1f} MiB)", flush=True)
                files.append({
                    "path": rel,
                    "size": size,
                    "sha256": sha256(full),
                    "url": f"https://huggingface.co/{a.repo}/resolve/main/{a.prefix}/{rel}",
                })
                total += size

    manifest = {
        "version": a.prefix,
        "models": MODELS,
        "files": sorted(files, key=lambda f: f["path"]),
        "totalBytes": total,
    }
    manifest_local = os.path.join(stage, "manifest.json")
    with open(manifest_local, "w") as fh:
        json.dump(manifest, fh, indent=1)

    from huggingface_hub import HfApi
    api = HfApi()
    api.create_repo(repo_id=a.repo, private=False, exist_ok=True)
    for m in MODELS:
        src = os.path.join(app, m)
        print(f"upload {m} ({sum(os.path.getsize(os.path.join(r, f)) for r, _d, fs in os.walk(src) for f in fs)/2**30:.2f} GiB)", flush=True)
        api.upload_folder(
            repo_id=a.repo,
            folder_path=src,
            path_in_repo=f"{a.prefix}/{m}",
            commit_message=f"{a.prefix}: {m}",
        )
    # manifest last: it is what makes a partial tree detectable as incomplete
    api.upload_file(
        repo_id=a.repo,
        path_or_fileobj=manifest_local,
        path_in_repo=f"{a.prefix}/manifest.json",
        commit_message=f"{a.prefix}: manifest",
    )

    os.makedirs(os.path.dirname(a.manifest_out), exist_ok=True)
    with open(a.manifest_out, "w") as fh:
        json.dump(manifest, fh, indent=1)
        fh.write("\n")
    print(f"published {len(files)} files, {total/2**30:.2f} GiB → hf://{a.repo}/{a.prefix}/")
    print(f"manifest → {a.manifest_out}")


if __name__ == "__main__":
    main()
