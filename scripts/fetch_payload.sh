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

try_fetch() { # url dest — 0 on success, 1 on HTTP failure (e.g. 404); never exits
  if [[ -f "$2" ]]; then return 0; fi
  echo "fetch $1"
  local tmp="$2.tmp"
  local auth=()
  if [[ -n "${HF_TOKEN:-}" && "$CHANNEL" == "hf" ]]; then
    auth=(-H "Authorization: Bearer $HF_TOKEN")
  elif [[ -n "${GITHUB_TOKEN:-}" && "$CHANNEL" == "release" ]]; then
    # private release assets need auth; Actions provides GITHUB_TOKEN
    auth=(-H "Authorization: token $GITHUB_TOKEN")
  fi
  if curl -fsSL --retry 3 "${auth[@]}" -o "$tmp" "$1"; then
    mv "$tmp" "$2"
    return 0
  else
    rm -f "$tmp"
    return 1
  fi
}

while IFS=$'\t' read -r kind name; do
  [[ -z "$kind" || "$kind" == \#* ]] && continue
  kind="$(echo "$kind" | tr -d '[:space:]')"
  name="$(echo "$name" | tr -d '[:space:]')"
  case "$kind" in
    model)
      base="$CACHE/$TAG/models/$name.zip"
      if [[ "$CHANNEL" == "release" ]]; then
        baseurl="https:$(printf '\x2f\x2f')github.com/$REPO/releases/download/$TAG"
      else
        baseurl="https:$(printf '\x2f\x2f')huggingface.co/$REPO/resolve/$TAG"
      fi
      if [[ ! -f "$base" ]]; then
        # whole zip first (small models + hf are single-file); large models
        # are split into <2GB parts on upload and rejoined with `cat` here
        if ! try_fetch "$baseurl/$name.zip" "$base"; then
          rm -f "$base"
          got=0
          for i in 00 01 02 03 04 05 06 07 08 09; do
            part="$CACHE/$TAG/models/$name.zip.part.$i"
            if try_fetch "$baseurl/$name.zip.part.$i" "$part"; then
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
