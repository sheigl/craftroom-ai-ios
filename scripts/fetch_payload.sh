#!/usr/bin/env bash
# Fetch the Craft Room AI app payload into Resources/{models,bins} for the
# xcodegen build. Runs on the CI runner (cache-miss path) and can be run
# locally the same way.
#
# Env:
#   PAYLOAD_CHANNEL  release (default) | hf
#   PAYLOAD_REPO     owner/name (GitHub release) or namespace/repo (HF)
#   PAYLOAD_TAG      release tag (default payload-v1; 'main' for hf)
#   PAYLOAD_CACHE    cache dir (default .payload-cache) — download happens
#                    here once per tag, Resources/ is populated from it, so
#                    actions/cache can key on the tag.
#   GITHUB_TOKEN     required for the release channel (private repo assets);
#                    Actions provides it built in.
#   HF_TOKEN         optional; only needed for a private HF repo.
#
# Release-channel note (2026-10-21): the web URL
# https://<host>/owner/repo/releases/download/<tag>/<asset> returns 404 for
# PRIVATE repos even with a valid PAT, so assets are downloaded through the
# REST asset endpoint instead: GET /repos/{repo}/releases/tags/{tag} to
# resolve the asset id, then GET /repos/{repo}/releases/assets/{id} with
# Accept: application/octet-stream (302 -> signed storage URL). This is the
# same path `gh release download` uses.
set -euo pipefail
cd "$(dirname "$0")/.."

CHANNEL="${PAYLOAD_CHANNEL:-release}"
REPO="${PAYLOAD_REPO:?set PAYLOAD_REPO=owner/name}"
TAG="${PAYLOAD_TAG:-payload-v1}"
CACHE="${PAYLOAD_CACHE:-.payload-cache}"
MANIFEST="scripts/payload_manifest.txt"

mkdir -p "$CACHE/$TAG/models" "$CACHE/$TAG/bins" Resources/models Resources/bins

api() { # api-path — GET api.github.com/<path> with the token
  curl -fsSL --retry 3 \
    -H "Authorization: token ${GITHUB_TOKEN:?set GITHUB_TOKEN for the release channel}" \
    "https://api.github.com/$1"
}

try_fetch() { # url dest — 0 on success, 1 on HTTP failure (e.g. 404); never exits (hf channel)
  if [[ -f "$2" ]]; then return 0; fi
  echo "fetch $1"
  local tmp="$2.tmp"
  local auth=()
  if [[ -n "${HF_TOKEN:-}" && "$CHANNEL" == "hf" ]]; then
    auth=(-H "Authorization: Bearer $HF_TOKEN")
  fi
  if curl -fsSL --retry 3 "${auth[@]}" -o "$tmp" "$1"; then
    mv "$tmp" "$2"
    return 0
  else
    rm -f "$tmp"
    return 1
  fi
}

fetch_asset() { # name dest — 0 on success, 1 on failure; channel-aware
  local name="$1" dest="$2"
  if [[ -f "$dest" ]]; then return 0; fi
  if [[ "$CHANNEL" == "release" ]]; then
    local json="$CACHE/$TAG/.release.json"
    local id
    if [[ ! -f "$json" ]]; then
      api "repos/$REPO/releases/tags/$TAG" > "$json"
    fi
    id=$(python3 - "$json" "$name" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for a in data.get("assets", []):
    if a["name"] == sys.argv[2]:
        print(a["id"])
        break
PY
)
    [[ -n "$id" ]] || return 1
    echo "fetch release asset $name (id $id)"
    local tmp="$dest.tmp"
    if curl -fsSL --retry 3 -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/octet-stream" \
        -o "$tmp" "https://api.github.com/repos/$REPO/releases/assets/$id"; then
      mv "$tmp" "$dest"
      return 0
    fi
    rm -f "$tmp"
    return 1
  fi
  try_fetch "https://huggingface.co/$REPO/resolve/$TAG/$name" "$dest"
}

while IFS=$'\t' read -r kind name; do
  [[ -z "$kind" || "$kind" == \#* ]] && continue
  kind="$(echo "$kind" | tr -d '[:space:]')"
  name="$(echo "$name" | tr -d '[:space:]')"
  case "$kind" in
    model)
      base="$CACHE/$TAG/models/$name.zip"
      if [[ ! -f "$base" ]]; then
        # whole zip first (small models + hf are single-file); large models
        # are split into <2GB parts on upload and rejoined with `cat` here
        if ! fetch_asset "$name.zip" "$base"; then
          rm -f "$base"
          got=0
          for i in 00 01 02 03 04 05 06 07 08 09; do
            part="$CACHE/$TAG/models/$name.zip.part.$i"
            if fetch_asset "$name.zip.part.$i" "$part"; then
              got=1
            else
              rm -f "$part"
              break
            fi
          done
          [[ $got -eq 1 ]] || { echo "no zip and no parts for $name" >&2; exit 1; }
          cat "$CACHE/$TAG/models/$name.zip.part."* > "$base"
          rm -f "$CACHE/$TAG/models/$name.zip.part."*
        fi
      fi
      target="Resources/models/$name"
      if [[ ! -d "$target" ]]; then
        unzip -q "$base" -d Resources/models
        [[ -d "$target" ]] || { echo "zip did not contain $name/ at top level" >&2; exit 1; }
      fi
      ;;
    bin)
      dest="$CACHE/$TAG/bins/$name"
      fetch_asset "$name" "$dest"
      cp -f "$dest" "Resources/bins/$name"
      ;;
    *) echo "manifest: unknown kind '$kind'" >&2; exit 1 ;;
  esac
done < "$MANIFEST"

echo "payload ready:"
du -sh Resources/models/*.mlpackage 2>/dev/null | cat
ls -l Resources/bins
