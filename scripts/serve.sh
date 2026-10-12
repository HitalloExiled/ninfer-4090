#!/usr/bin/env bash
# Simplified launcher for ninfer-serve with a pre-flight VRAM check.
#
# Usage:
#   serve.sh [MODEL] [--profile c1|c8|vision|balanced|max] [--port N] [--host H]
#            [--device N] [--context N] [--kv-capacity N|auto]
#            [--concurrency N] [--kv-dtype DTYPE] [--model-id ID]
#            [--estimate] [--dry-run] [--no-vram-check] [--list] [--help]
#            [-- <extra ninfer-serve args...>]
#
# Env overrides: NINFER_SERVER, NINFER_MODEL_DIR, NINFER_DOCKER_IMAGE,
#   NINFER_MIN_FREE_GIB (skip estimate, require this much free VRAM),
#   NINFER_NO_VRAM_CHECK=1 (same as --no-vram-check).
set -euo pipefail
export LC_ALL=C LC_NUMERIC=C

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
model_dir_default="$root/models"

profile="c1"
host="${NINFER_HOST:-127.0.0.1}"
port="${NINFER_PORT:-8080}"
device="${NINFER_DEVICE:-0}"
ctx_override=""
kv_cap_override=""
conc_override=""
kv_dtype_override=""
model_id_override=""
api_key_override=""
default_max_tokens_override=""
estimate_only=0
dry_run=0
vram_check=1
list_only=0
model_arg=""
passthrough=()

if [[ "${NINFER_NO_VRAM_CHECK:-0}" == "1" ]]; then
  vram_check=0
fi

usage() {
  cat <<USAGE
usage: $(basename -- "$0") [MODEL] [options] [-- <extra ninfer-serve args...>]

Simplified ninfer-serve launcher. Checks free VRAM before starting.

Positional:
  MODEL                 .ninfer artifact path (default: \$NINFER_MODEL_DIR/qwen3_8_27b.ninfer)

Options:
  --profile c1|c8|vision|balanced|max  preset (default: c1)
                            c1:       64K ctx, concurrency 1, MTP3 (RTX 4090 24GB safe)
                            c8:       8K ctx, concurrency 8, MTP3
                            vision:   32K ctx, concurrency 1, MTP3 + --vision
                            balanced: 128K ctx, concurrency 1, MTP3, rk8v4 KV
                                      (retrieval-gated 5/5, 2026-10-12)
                            max:      192K ctx, concurrency 1, MTP3, rk4v4-e8 KV
                                      (retrieval-gated 5/5, 2026-10-12)
  --host H              listen address (default: $host)
  --port N              listen port (default: $port)
  --device N            CUDA device ordinal (default: $device)
  --context N           override --max-context
  --kv-capacity N|auto  override --kv-capacity
  --concurrency N       override --max-concurrency (1..8)
  --kv-dtype DTYPE      override --kv-dtype (default: int8)
  --model-id ID         override --model-id (default: qwen3.8-27b)
  --api-key KEY         bearer auth key (default: disabled)
  --default-max-tokens N  override server default output budget
  --estimate            print VRAM estimate and exit (no server start)
  --dry-run             print the ninfer-serve command and exit
  --no-vram-check       skip the nvidia-smi free-VRAM gate
  --list                list *.ninfer artifacts under the model dir and exit
  --help                show this text

Env:
  NINFER_SERVER         ninfer-serve binary (auto-detected if unset)
  NINFER_MODEL_DIR      model directory (default: $model_dir_default)
  NINFER_DOCKER_IMAGE   docker fallback image (default: ninfer-4090:sm89)
  NINFER_MIN_FREE_GIB   require this much free VRAM instead of estimating
  NINFER_NO_VRAM_CHECK=1  skip the VRAM gate

Exit codes: 0 ok, 1 usage/setup error, 2 missing server/model, 3 insufficient VRAM.
USAGE
}

list_models() {
  local dir="${NINFER_MODEL_DIR:-$model_dir_default}"
  if [[ ! -d "$dir" ]]; then
    printf 'Model dir not found: %s\n' "$dir" >&2
    return 1
  fi
  local found=0
  local f
  for f in "$dir"/*.ninfer; do
    [[ -e "$f" ]] || continue
    printf '%s\n' "$f"
    found=1
  done
  if [[ "$found" == "0" ]]; then
    printf 'No *.ninfer artifacts in %s\n' "$dir" >&2
    printf 'Run download-qwen38.sh first.\n' >&2
    return 1
  fi
}

while (( $# )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --list) list_only=1; shift ;;
    --estimate|--vram-only) estimate_only=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --no-vram-check) vram_check=0; shift ;;
    --profile) profile="${2:?--profile needs c1|c8|vision|balanced|max}"; shift 2 ;;
    --profile=*) profile="${1#--profile=}"; shift ;;
    --host) host="${2:?--host needs a value}"; shift 2 ;;
    --host=*) host="${1#--host=}"; shift ;;
    --port) port="${2:?--port needs a value}"; shift 2 ;;
    --port=*) port="${1#--port=}"; shift ;;
    --device) device="${2:?--device needs a value}"; shift 2 ;;
    --device=*) device="${1#--device=}"; shift ;;
    --context|--max-context) ctx_override="${2:?--context needs a value}"; shift 2 ;;
    --context=*|--max-context=*) ctx_override="${1#*=}"; shift ;;
    --kv-capacity) kv_cap_override="${2:?--kv-capacity needs a value}"; shift 2 ;;
    --kv-capacity=*) kv_cap_override="${1#--kv-capacity=}"; shift ;;
    --concurrency|--max-concurrency) conc_override="${2:?--concurrency needs a value}"; shift 2 ;;
    --concurrency=*|--max-concurrency=*) conc_override="${1#*=}"; shift ;;
    --kv-dtype) kv_dtype_override="${2:?--kv-dtype needs a value}"; shift 2 ;;
    --kv-dtype=*) kv_dtype_override="${1#--kv-dtype=}"; shift ;;
    --model-id) model_id_override="${2:?--model-id needs a value}"; shift 2 ;;
    --model-id=*) model_id_override="${1#--model-id=}"; shift ;;
    --api-key) api_key_override="${2:?--api-key needs a value}"; shift 2 ;;
    --api-key=*) api_key_override="${1#--api-key=}"; shift ;;
    --default-max-tokens) default_max_tokens_override="${2:?--default-max-tokens needs a value}"; shift 2 ;;
    --default-max-tokens=*) default_max_tokens_override="${1#--default-max-tokens=}"; shift ;;
    --) shift; while (( $# )); do passthrough+=("$1"); shift; done ;;
    --*) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    *) if [[ -z "$model_arg" ]]; then model_arg="$1"; else printf 'Unexpected arg: %s\n' "$1" >&2; exit 1; fi; shift ;;
  esac
done

if [[ "$list_only" == "1" ]]; then
  list_models
  exit $?
fi

case "$profile" in
  c1)
    ctx=65536; kv_cap=65536; conc=1; pending=16; chunk=1024; kv_dtype="int8"
    spec=(--spec mtp --draft-tokens 3 --lm-head-draft); vision=0; model_id="qwen3.8-27b"
    profile_label="one request, 64K context, MTP3" ;;
  c8)
    ctx=8192; kv_cap=16384; conc=8; pending=32; chunk=1024; kv_dtype="int8"
    spec=(--spec mtp --draft-tokens 3 --lm-head-draft); vision=0; model_id="qwen3.8-27b"
    profile_label="up to eight requests, 8K context, MTP3" ;;
  vision)
    ctx=32768; kv_cap=32768; conc=1; pending=8; chunk=512; kv_dtype="int8"
    spec=(--vision --spec mtp --draft-tokens 3 --lm-head-draft); vision=1; model_id="qwen3.8-27b"
    profile_label="one request, 32K context, vision, MTP3" ;;
  balanced)
    ctx=131072; kv_cap=131072; conc=1; pending=16; chunk=1024; kv_dtype="rk8v4"
    spec=(--spec mtp --draft-tokens 3 --lm-head-draft); vision=0; model_id="qwen3.8-27b"
    profile_label="one request, 128K context, MTP3, rk8v4 KV (retrieval-gated 5/5)" ;;
  max)
    ctx=196608; kv_cap=196608; conc=1; pending=16; chunk=1024; kv_dtype="rk4v4-e8"
    spec=(--spec mtp --draft-tokens 3 --lm-head-draft); vision=0; model_id="qwen3.8-27b"
    profile_label="one request, 192K context, MTP3, rk4v4-e8 KV (retrieval-gated 5/5)" ;;
  *) printf 'Unknown --profile: %s (want c1|c8|vision|balanced|max)\n' "$profile" >&2; exit 1 ;;
esac

[[ -n "$ctx_override" ]] && ctx="$ctx_override"
[[ -n "$kv_cap_override" ]] && kv_cap="$kv_cap_override"
[[ -n "$conc_override" ]] && conc="$conc_override"
[[ -n "$kv_dtype_override" ]] && kv_dtype="$kv_dtype_override"
[[ -n "$model_id_override" ]] && model_id="$model_id_override"

# Resolve server binary (native first, docker fallback handled at exec time).
server="${NINFER_SERVER:-}"
if [[ -z "$server" ]]; then
  candidates=(
    "$root/ninfer-serve"
    "$root/../build-sm89/apps/ninfer-serve"
    "$root/../build-sm86/apps/ninfer-serve"
    "$root/../build/apps/ninfer-serve"
  )
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then server="$c"; break; fi
  done
fi
docker_image="${NINFER_DOCKER_IMAGE:-ninfer-4090:sm89}"
use_docker=0
if [[ -z "$server" || ! -x "$server" ]]; then
  if command -v docker >/dev/null 2>&1 && docker image inspect "$docker_image" >/dev/null 2>&1; then
    use_docker=1
  fi
fi

# Resolve model.
model="${model_arg:-${NINFER_MODEL_DIR:-$model_dir_default}/qwen3_8_27b.ninfer}"
if [[ ! -f "$model" ]]; then
  printf 'Missing model: %s\n' "$model" >&2
  printf 'Run download-qwen38.sh or pass the model path.\n' >&2
  exit 2
fi

# Fast artifact generation check (real launches only; --estimate/--dry-run just
# do math or print). This fork's reader accepts container v1/v2 magic only
# (NINFER\x00\x01|\x02). A v3 file (current HF main) fails after a full
# container boot otherwise; reject it here with a pointer to the v2 rev.
if [[ "$estimate_only" == "0" && "$dry_run" == "0" ]]; then
  model_magic="$(head -c 8 -- "$model" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
  case "$model_magic" in
    4e494e4645520001|4e494e4645520002) ;;
    *)
      printf 'Unsupported artifact (magic %s): need NInfer container v1/v2\n' \
        "${model_magic:-unreadable}" >&2
      printf 'Main-branch artifacts are v3; fetch the last v2 instead:\n' >&2
      printf '  NINFER_REVISION=18dfc887423f NINFER_QWEN38_SHA256=%s download-qwen38.sh\n' \
        "eec39564993d6e9c7d5e383382a760f093465c9d163ec9a1bd6b80199514bf3e" >&2
      exit 2 ;;
  esac
fi

# Marginal KV cost (KiB/token) by kv-dtype: fitted 2026-10-12 from server
# "KV capacity explicit resolved=... runtime=..." log lines on RTX 4090
# (int8 35 @64K, rk8v4 27 @141K, rk4v4-e8 19 @203K; rest scaled, uncalibrated).
# Runtime is ~0.7 GiB fixed + marginal*tokens; the fixed part folds into overhead.
kv_kib_per_token() {
  case "$1" in
    bf16) printf '96' ;;
    int8) printf '35' ;;
    rk8v4) printf '27' ;;
    rk4v4) printf '24' ;;
    rk4v4-e8) printf '19' ;;
    rk2v4-e8) printf '16' ;;
    *) printf '35' ;;
  esac
}

# required_mib <model> <kv_cap> <kv_dtype> -> prints integer MiB estimate.
required_mib() {
  local file="$1" cap="$2" dtype="$3"
  local bytes per_kib kv_mib model_mib overhead total
  if stat -c%s -- "$file" >/dev/null 2>&1; then
    bytes="$(stat -c%s -- "$file")"
  else
    bytes="$(wc -c < "$file" | tr -d ' ')"
  fi
  per_kib="$(kv_kib_per_token "$dtype")"
  if [[ "$cap" == "auto" ]]; then
    # 'auto' fills VRAM minus 1 GiB headroom: gate on weights + overhead only.
    kv_mib=0
  else
    kv_mib="$(awk -v c="$cap" -v k="$per_kib" 'BEGIN { printf "%d", (c * k + 1023) / 1024 }')"
  fi
  # Resident weights measure ~16.67 GiB for the 16.96 GiB v2 file, so no markup.
  model_mib="$(awk -v b="$bytes" 'BEGIN { printf "%d", b / 1048576 }')"
  # Explicit 141248-token rk8v4 boot fits in 21990 MiB free alongside a live
  # desktop (weights 17067 + KV runtime 4403 leave ~520 MiB for the rest), so
  # keep overhead small: graphs/workspace/slack. The server enforces its own
  # 1 GiB headroom at startup; the gate warning below flags tight fits.
  overhead=768
  total=$((model_mib + kv_mib + overhead))
  printf '%d|%d|%d' "$total" "$model_mib" "$kv_mib"
}

# vram_gate -> 0 if enough VRAM (or check skipped/unavailable with warning).
vram_gate() {
  if [[ "$vram_check" == "0" ]]; then
    return 0
  fi
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    printf 'warning: nvidia-smi not found, skipping VRAM check\n' >&2
    return 0
  fi
  local smi free_mib total_mib
  if ! smi="$(nvidia-smi -i "$device" --query-gpu=memory.free,memory.total --format=csv,noheader,nounits 2>/dev/null)"; then
    printf 'warning: nvidia-smi unreachable for device %s, skipping VRAM check\n' "$device" >&2
    return 0
  fi
  free_mib="$(printf '%s' "$smi" | awk -F',' '{ gsub(/[^0-9]/, "", $1); print $1 }')"
  total_mib="$(printf '%s' "$smi" | awk -F',' '{ gsub(/[^0-9]/, "", $2); print $2 }')"
  if [[ -z "$free_mib" || -z "$total_mib" ]]; then
    printf 'warning: could not parse nvidia-smi output, skipping VRAM check\n' >&2
    return 0
  fi

  local need_mib weights_mib kv_mib
  if [[ -n "${NINFER_MIN_FREE_GIB:-}" ]]; then
    need_mib="$(awk -v g="$NINFER_MIN_FREE_GIB" 'BEGIN { printf "%d", g * 1024 }')"
    weights_mib=0; kv_mib=0
  else
    IFS='|' read -r need_mib weights_mib kv_mib <<< "$(required_mib "$model" "$kv_cap" "$kv_dtype")"
  fi

  printf 'VRAM device %s: free %d MiB / total %d MiB; need ~%d MiB (weights ~%d + kv ~%d + overhead 768)\n' \
    "$device" "$free_mib" "$total_mib" "$need_mib" "$weights_mib" "$kv_mib"

  if (( need_mib > total_mib )); then
    printf 'error: estimate (%d MiB) exceeds total VRAM (%d MiB); reduce --context/--kv-capacity\n' \
      "$need_mib" "$total_mib" >&2
    return 3
  fi
  if (( free_mib < need_mib )); then
    printf 'error: insufficient free VRAM: %d MiB free, ~%d MiB required\n' "$free_mib" "$need_mib" >&2
    printf 'Top GPU processes:\n' >&2
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv 2>/dev/null >&2 || true
    printf 'Free VRAM (stop idle Ollama models?) or set NINFER_MIN_FREE_GIB to override.\n' >&2
    return 3
  fi
  if (( free_mib < need_mib + 1024 )); then
    printf 'warning: headroom under 1 GiB after load (%d MiB free vs ~%d MiB need)\n' \
      "$free_mib" "$need_mib" >&2
  fi
  return 0
}

if [[ "$estimate_only" == "1" ]]; then
  if [[ -n "${NINFER_MIN_FREE_GIB:-}" ]]; then
    printf 'Required free VRAM (override NINFER_MIN_FREE_GIB): %s GiB\n' "$NINFER_MIN_FREE_GIB"
  else
    IFS='|' read -r need_mib weights_mib kv_mib <<< "$(required_mib "$model" "$kv_cap" "$kv_dtype")"
    printf 'Model: %s\n' "$model"
    printf 'Profile: %s (ctx=%s kv=%s conc=%s kv-dtype=%s)\n' "$profile" "$ctx" "$kv_cap" "$conc" "$kv_dtype"
    printf 'Estimate: weights ~%d MiB + kv ~%d MiB + overhead 768 MiB = ~%d MiB (%.1f GiB)\n' \
      "$weights_mib" "$kv_mib" "$need_mib" "$(awk -v m="$need_mib" 'BEGIN { printf "%.1f", m / 1024 }')"
  fi
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi -i "$device" --query-gpu=memory.free,memory.total --format=csv 2>/dev/null || true
  fi
  exit 0
fi

if ! vram_gate; then
  exit 3
fi

# Port conflict: best-effort warning (non-fatal; server bind is authoritative).
if command -v ss >/dev/null 2>&1; then
  if ss -ltn "sport = :$port" 2>/dev/null | grep -q ":$port"; then
    printf 'warning: port %s already listening; start may fail to bind\n' "$port" >&2
  fi
fi

# Docker -p publishing only reaches the server if it binds a container-wide
# address; 127.0.0.1 would lock it to container loopback. Native runs keep $host.
bind_host="$host"
if [[ "$use_docker" == "1" ]]; then
  bind_host="0.0.0.0"
fi

args=(
  --host "$bind_host" --port "$port"
  --max-context "$ctx" --kv-capacity "$kv_cap"
  --max-concurrency "$conc" --max-pending-requests "$pending"
  --prefill-chunk "$chunk" --kv-dtype "$kv_dtype"
  --model-id "$model_id"
  "${spec[@]}"
)
if [[ -n "$api_key_override" ]]; then
  args+=(--api-key "$api_key_override")
fi
if [[ -n "$default_max_tokens_override" ]]; then
  args+=(--default-max-tokens "$default_max_tokens_override")
fi
if (( ${#passthrough[@]} )); then
  args+=("${passthrough[@]}")
fi

if [[ "$dry_run" == "1" ]]; then
  if [[ "$use_docker" == "1" ]]; then
    printf 'docker run --gpus all --rm -p %s:%s -v %s:/workspace/models:ro %s ninfer-serve /workspace/models/%s' \
      "$port" "$port" "$(dirname -- "$model")" "$docker_image" "$(basename -- "$model")"
    printf ' %q' "${args[@]}"
    printf '\n'
  else
    printf '%q %q' "$server" "$model"
    printf ' %q' "${args[@]}"
    printf '\n'
  fi
  exit 0
fi

if [[ "$use_docker" == "1" ]]; then
  if [[ -z "$server" || ! -x "$server" ]]; then
    : # docker path needs no native binary
  fi
  printf '%s\n' "Starting Qwen3.8-27B (docker $docker_image) at http://$host:$port/v1"
  printf '%s\n' "Profile: $profile_label"
  model_base="$(basename -- "$model")"
  model_host_dir="$(cd -- "$(dirname -- "$model")" && pwd)"
  exec docker run --gpus all --rm --init \
    -p "$port:$port" \
    -v "$model_host_dir:/workspace/models:ro" \
    "$docker_image" \
    ninfer-serve "/workspace/models/$model_base" "${args[@]}"
fi

if [[ -z "$server" || ! -x "$server" ]]; then
  printf 'Missing executable: %s\n' "${server:-<unset>}" >&2
  printf 'Set NINFER_SERVER, build apps/ninfer-serve, or provide docker image %s.\n' "$docker_image" >&2
  exit 2
fi

printf '%s\n' "Starting Qwen3.8-27B at http://$host:$port/v1"
printf '%s\n' "Profile: $profile_label"
exec "$server" "$model" "${args[@]}"
