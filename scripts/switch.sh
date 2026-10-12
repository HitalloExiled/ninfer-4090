#!/usr/bin/env bash
# Switch the running ninfer-serve to another profile/model, Ollama-style:
# stop whatever is serving, wait for the port and VRAM to free up, then
# launch serve.sh with the requested profile.
#
# Usage:
#   switch.sh --profile NAME [--port N] [MODEL] [--timeout S] [-- <serve.sh args...>]
#
# Profiles: c1|c8|vision|balanced|max (see serve.sh --help).
# MODEL defaults to <model-dir>/qwen3_8_27b-v2.ninfer when present (the v3
# file under the canonical name cannot be loaded by this fork's reader).
# Exit codes: 0 ok, 1 usage/setup error, 2 missing server/model (from serve.sh),
# 3 insufficient VRAM (from serve.sh).
set -euo pipefail
export LC_ALL=C LC_NUMERIC=C

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
model_dir_default="$root/models"
docker_image="${NINFER_DOCKER_IMAGE:-ninfer-4090:sm89}"

profile=""
port="${NINFER_PORT:-8080}"
timeout_s="${NINFER_SWITCH_TIMEOUT:-120}"
model_arg=""
passthrough=()

usage() {
  cat <<USAGE
usage: $(basename -- "$0") --profile NAME [--port N] [MODEL] [--timeout S] [-- <serve.sh args...>]

Stop the running ninfer-serve (docker or native) and start another profile.

  --profile NAME  one of c1|c8|vision|balanced|max (required)
  --port N        wait on / start this port (default: $port)
  --timeout S     seconds to wait for stop (default: $timeout_s)
  MODEL           .ninfer path (default: qwen3_8_27b-v2.ninfer if present,
                  else serve.sh default)
  -- <args...>    extra args forwarded to serve.sh

Examples:
  $(basename -- "$0") --profile max
  $(basename -- "$0") --profile c1 -- --kv-dtype rk4v4-e8
USAGE
}

while (( $# )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --profile) profile="${2:?--profile needs a value}"; shift 2 ;;
    --profile=*) profile="${1#--profile=}"; shift ;;
    --port) port="${2:?--port needs a value}"; shift 2 ;;
    --port=*) port="${1#--port=}"; shift ;;
    --timeout) timeout_s="${2:?--timeout needs seconds}"; shift 2 ;;
    --timeout=*) timeout_s="${1#--timeout=}"; shift ;;
    --) shift; while (( $# )); do passthrough+=("$1"); shift; done ;;
    --*) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    *) if [[ -z "$model_arg" ]]; then model_arg="$1"; else printf 'Unexpected arg: %s\n' "$1" >&2; exit 1; fi; shift ;;
  esac
done

if [[ -z "$profile" ]]; then
  printf 'Missing required --profile (c1|c8|vision|balanced|max)\n' >&2
  usage >&2
  exit 1
fi

# Prefer the loadable v2 artifact when the caller did not pick a model.
if [[ -z "$model_arg" ]]; then
  v2="${NINFER_MODEL_DIR:-$model_dir_default}/qwen3_8_27b-v2.ninfer"
  if [[ -f "$v2" ]]; then
    model_arg="$v2"
  fi
fi

stopped_something=0

# 1. Docker runners from our image.
if command -v docker >/dev/null 2>&1; then
  ids="$(docker ps -q --filter "ancestor=$docker_image" 2>/dev/null || true)"
  if [[ -n "$ids" ]]; then
    printf 'Stopping docker container(s): %s\n' "$ids"
    # shellcheck disable=SC2086
    docker stop $ids >/dev/null 2>&1 || true
    stopped_something=1
  fi
fi

# 2. Native ninfer-serve processes (not this script).
if command -v pgrep >/dev/null 2>&1; then
  while read -r pid; do
    [[ -z "$pid" || "$pid" == "$$" ]] && continue
    printf 'Stopping native ninfer-serve pid %s\n' "$pid"
    kill "$pid" 2>/dev/null || true
    stopped_something=1
  done < <(pgrep -f 'ninfer-serve' 2>/dev/null || true)
fi

if [[ "$stopped_something" == "0" ]]; then
  printf 'No running ninfer-serve found; starting fresh.\n'
fi

# 3. Wait for the port to free up (best effort; the bind is authoritative).
if command -v ss >/dev/null 2>&1; then
  waited=0
  while ss -ltn "sport = :$port" 2>/dev/null | grep -q ":$port"; do
    if (( waited >= timeout_s )); then
      printf 'error: port %s still busy after %ss; refusing to start\n' "$port" "$timeout_s" >&2
      exit 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
fi

args=(--profile "$profile" --port "$port")
if [[ -n "$model_arg" ]]; then
  args+=("$model_arg")
fi
if (( ${#passthrough[@]} )); then
  args+=(-- "${passthrough[@]}")
fi

printf 'Switching to profile %s on port %s\n' "$profile" "$port"
exec "$root/serve.sh" "${args[@]}"
