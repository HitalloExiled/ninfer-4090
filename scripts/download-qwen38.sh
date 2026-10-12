#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
model_dir="${NINFER_MODEL_DIR:-$root/models}"
model="$model_dir/qwen3_8_27b.ninfer"
expected_sha256="${NINFER_QWEN38_SHA256:-81f924d440c27261d820c19a9f8d45794c5aee410f8a68bd358133fa8c0375da}"
# HF revision: main carries the v3 artifact (container v3, unreadable by this
# fork's v1/v2 reader). Pin 18dfc887423f for the last v2 artifact:
#   NINFER_REVISION=18dfc887423f \
#   NINFER_QWEN38_SHA256=eec39564993d6e9c7d5e383382a760f093465c9d163ec9a1bd6b80199514bf3e \
#   ./scripts/download-qwen38.sh
rev="${NINFER_REVISION:-main}"

mkdir -p -- "$model_dir"
printf '%s\n' "Downloading Qwen3.8-27B NInfer model (revision $rev)..."
if ! curl -L -C - --fail --output "$model" \
  "https://huggingface.co/neroued/Qwen3.8-27B-NInfer/resolve/$rev/qwen3_8_27b.ninfer"; then
  printf '%s\n' 'Download failed. Run this script again to resume.' >&2
  exit 1
fi
if [[ "${NINFER_SKIP_SHA:-0}" == "1" ]]; then
  printf '%s\n' 'Skipping SHA256 check (NINFER_SKIP_SHA=1).'
else
  printf '%s\n' 'Verifying SHA256...'
  actual="$(sha256sum -- "$model" | awk '{ print $1 }')"
  if [[ "$actual" != "$expected_sha256" ]]; then
    printf 'SHA256 mismatch for %s\n  expected: %s\n  actual:   %s\n' \
      "$model" "$expected_sha256" "$actual" >&2
    exit 1
  fi
  printf '%s\n' 'SHA256 OK.'
fi
printf 'Model ready: %s\n' "$model"
