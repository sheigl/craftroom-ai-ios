#!/usr/bin/env python3
"""Stage + upload the Craft Room AI app payload to the download channel.

Runs on the machine that HOLDS the payload (desktop2), once, after every
payload re-bake. The payload never rides git; CI fetches it with
scripts/fetch_payload.sh. The manifest (scripts/payload_manifest.txt) is the
single source of truth for the file list.

Channels
  release — GitHub Release on the harness repo (public). Each .mlpackage is
            zipped (stored, not deflated — the weights are near-incompressible);
            bins upload verbatim. Needs the `gh` CLI authenticated with a token
            that can push releases. GitHub per-asset limit is 5 GB; the largest
            asset (dit_int8, ~3.7 GB) fits.
  hf      — Hugging Face repo (private works). Needs the `hf` CLI
            (huggingface_hub). No size stress.

Usage (from the payload root, i.e. the dir holding app_payload/):
  python3 scripts/upload_payload.py --channel release \
      --repo OWNER/CraftRoomAIPayload --tag payload-v1 \
      --dir ios_assets/app_payload
  python3 scripts/upload_payload.py --channel hf \
      --repo OWNER/craftroom-ai-payload --tag main \
      --dir ios_assets/app_payload
"""
import argparse
import glob
import os
import shlex
import shutil
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "payload_manifest.txt")
# GitHub release assets cap at 2 GB (2147483648 B); 1.9 GiB parts stay under it.
SPLIT_THRESHOLD = 1900 * 1024 * 1024


def load_manifest():
    items = []
    with open(MANIFEST) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            kind, name = line.split("\t")
            items.append((kind.strip(), name.strip()))
    return items


def run(cmd):
    print("+", shlex.join(cmd), flush=True)
    subprocess.check_call(cmd)


def zip_mlpackage(src_dir, name, staging):
    """Zip a .mlpackage directory preserving its top-level folder name,
    stored (no compression): the CoreML weight blobs are ~incompressible."""
    src = os.path.join(src_dir, name)
    if not os.path.isdir(src):
        sys.exit(f"missing model directory: {src}")
    out = os.path.join(staging, name + ".zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED, allowZip64=True) as zf:
        for root, _dirs, files in os.walk(src):
            for f in files:
                full = os.path.join(root, f)
                rel = os.path.relpath(full, src_dir)
                zf.write(full, rel)
    size = os.path.getsize(out) / 2**30
    print(f"zipped {name}.zip: {size:.2f} GiB", flush=True)
    if os.path.getsize(out) > SPLIT_THRESHOLD:
        # GitHub release assets cap at 2 GB; split into <2GB parts that
        # scripts/fetch_payload.sh rejoins with `cat` before unzipping.
        subprocess.run(["split", "-b", "1900m", "-d", out, out + ".part."],
                       check=True)
        os.remove(out)
        parts = sorted(glob.glob(out + ".part.*"))
        print(f"split {name}.zip into {len(parts)} parts (<2GB each)", flush=True)
        return parts
    return [out]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--channel", required=True, choices=["release", "hf"])
    ap.add_argument("--repo", required=True, help="owner/name")
    ap.add_argument("--tag", required=True, help="release tag (or 'main' for hf)")
    ap.add_argument("--dir", required=True, help="payload root (holds manifest files)")
    args = ap.parse_args()

    items = load_manifest()
    staging = os.path.join(args.dir, "_upload")
    os.makedirs(staging, exist_ok=True)

    uploads = []
    for kind, name in items:
        if kind == "model":
            uploads.extend(zip_mlpackage(args.dir, name, staging))
        else:
            src = os.path.join(args.dir, name)
            if not os.path.isfile(src):
                sys.exit(f"missing bin: {src}")
            dst = os.path.join(staging, name)
            if os.path.abspath(src) != os.path.abspath(dst):
                shutil.copy2(src, dst)
            uploads.append(dst)

    total = sum(os.path.getsize(p) for p in uploads) / 2**30
    print(f"staged {len(uploads)} assets, {total:.2f} GiB total")

    if args.channel == "release":
        run(["gh", "release", "create", args.tag,
             "--repo", args.repo,
             "--title", f"app payload {args.tag}",
             "--notes", "Craft Room AI Phase A payload (models + bins)"]
            + uploads)
    else:
        run(["hf", "upload", "--repo-type", "model", args.repo,
             staging, "--", "--include", "*"])
    print("done. CI fetches with scripts/fetch_payload.sh (PAYLOAD_REPO/PAYLOAD_TAG).")


if __name__ == "__main__":
    main()
