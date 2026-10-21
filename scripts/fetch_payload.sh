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
#   HF_TOKEN         optional; only needed for a private HF repo.
set -euo pipefail
cd "$(dirname "$0")/.."

CHANNEL="${PAYLOAD_CHANNEL:-release}"
REPO="${PAYLOAD_REPO:?set PAYLOAD_REPO=owner/name}"
TAG="${PAYLOAD_TAG:-payload-v1}"
CACHE="${PAYLOAD_CACHE:-.payload-cache}"
MANIFEST="scripts/payload_manifest.txt"

mkdir -p "$CACHE/$TAG/models" "$CACHE/$TAG/bins" Resources/models Resources/bins

fetch() { # url dest
  if [[ -f "$2" ]]; then return 0; fi
  echo "fetch $1"
  local tmp="$2.part"
  if [[ -n "${HF_TOKEN:-}" && "$CHANNEL" == "hf" ]]; then
    curl -fsSL --retry 3 -H "Authorization: Bearer $HF_TOKEN" -o "$tmp" "$1"
  elif [[ -n "${GITHUB_TOKEN:-}" && "$CHANNEL" == "release" ]]; then
    # private release assets need auth; Actions provides GITHUB_TOKEN
    curl -fsSL --retry 3 -H "Authorization: token $GITHUB_TOKEN" -o "$tmp" "$1"
  else
    curl -fsSL --retry 3 -o "$tmp" "$1"
  fi
  mv "$tmp" "$2"
}

while IFS=$'\t' read -r kind name; do
  [[ -z "$kind" || "$kind" == \#* ]] && continue
  kind="$(echo "$kind" | tr -d '[:space:]')"
  name="$(echo "$name" | tr -d '[:space:]')"
  case "$kind" in
    model)
      base="$CACHE/$TAG/models/$name.zip"
      if [[ "$CHANNEL" == "release" ]]; then
        url="https:$(printf '\x2f\x2f')github.com/$REPO/releases/download/$TAG/$name.zip"
      else
        url="https:$(printf '\x2f\x2f')huggingface.co/$REPO/resolve/$TAG/$name.zip"
      fi
      fetch "$url" "$base"
      target="Resources/models/$name"
      if [[ ! -d "$target" ]]; then
        unzip -q "$base" -d Resources/models
        [[ -d "$target" ]] || { echo "zip did not contain $name/ at top level" >&2; exit 1; }
      fi
      ;;
    bin)
      dest="$CACHE/$TAG/bins/$name"
      if [[ "$CHANNEL" == "release" ]]; then
        url="https:$(printf '\x2f\x2f')github.com/$REPO/releases/download/$TAG/$name"
      else
        url="https:$(printf '\x2f\x2f')huggingface.co/$REPO/resolve/$TAG/$name"
      fi
      fetch "$url" "$dest"
      cp -f "$dest" "Resources/bins/$name"
      ;;
    *) echo "manifest: unknown kind '$kind'" >&2; exit 1 ;;
  esac
done < "$MANIFEST"

echo "payload ready:"
du -sh Resources/models/*.mlpackage 2>/dev/null | cat
ls -l Resources/bins
