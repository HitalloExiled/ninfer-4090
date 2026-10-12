#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

for script in "$root"/*.sh; do
  bash -n "$script"
done
for pyscript in "$root"/*.py; do
  python3 -m py_compile "$pyscript"
done
for windows_script in "$root"/*.bat "$root"/*.ps1; do
  # Windows-only helpers with no Linux equivalent (RTX 3090 .exe benchmark,
  # RTX 4090 Windows release packager).
  case "$(basename -- "$windows_script")" in
    benchmark-qwen38-3090.bat|package-release-rtx4090.ps1) continue ;;
  esac
  counterpart="${windows_script%.*}.sh"
  if [[ ! -x "$counterpart" ]]; then
    printf 'Missing Bash counterpart: %s\n' "$counterpart" >&2
    exit 1
  fi
done

cat > "$tmp/ninfer-serve" <<'SERVER'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$NINFER_TEST_ARGS"
SERVER
chmod +x "$tmp/ninfer-serve"
# Minimal v2 magic so serve.sh's artifact pre-check passes on stubs.
printf 'NINFER\x00\x02\x00\x00\x00\x00\x00\x00' > "$tmp/qwen3_8_27b.ninfer"
printf 'NINFER\x00\x02\x00\x00\x00\x00\x00\x00' > "$tmp/qwen3_6_35b_a3b.ninfer"

launchers=(
  'run-qwen38-c1.sh:qwen3_8_27b.ninfer:--max-context:65536'
  'run-qwen38-c8.sh:qwen3_8_27b.ninfer:--max-concurrency:8'
  'run-qwen38-vision.sh:qwen3_8_27b.ninfer:--vision:--spec'
  'run-qwen36-35b-vision.sh:qwen3_6_35b_a3b.ninfer:--vision:--no-thinking'
)
for entry in "${launchers[@]}"; do
  IFS=: read -r script model expected value <<< "$entry"
  args="$tmp/${script%.sh}.args"
  NINFER_SERVER="$tmp/ninfer-serve" NINFER_TEST_ARGS="$args" \
    "$root/$script" "$tmp/$model" >/dev/null
  grep -Fx -- "$expected" "$args" >/dev/null
  grep -Fx -- "$value" "$args" >/dev/null
done

mkdir -- "$tmp/bin" "$tmp/models"
test_stub_sha="$(printf 'ninfer-test-stub' | sha256sum | awk '{ print $1 }')"
# serve.sh: simplified launcher with VRAM pre-flight gate.
# Bypass the nvidia-smi gate (no GPU in CI) via NINFER_NO_VRAM_CHECK=1.
NINFER_NO_VRAM_CHECK=1 NINFER_SERVER="$tmp/ninfer-serve" NINFER_TEST_ARGS="$tmp/serve-c1.args" \
  "$root/serve.sh" "$tmp/qwen3_8_27b.ninfer" >/dev/null
grep -Fx -- '--max-context' "$tmp/serve-c1.args" >/dev/null
grep -Fx -- '65536' "$tmp/serve-c1.args" >/dev/null
NINFER_NO_VRAM_CHECK=1 NINFER_SERVER="$tmp/ninfer-serve" NINFER_TEST_ARGS="$tmp/serve-c8.args" \
  "$root/serve.sh" --profile c8 "$tmp/qwen3_8_27b.ninfer" >/dev/null
grep -Fx -- '--max-concurrency' "$tmp/serve-c8.args" >/dev/null
grep -Fx -- '8' "$tmp/serve-c8.args" >/dev/null
NINFER_NO_VRAM_CHECK=1 NINFER_SERVER="$tmp/ninfer-serve" NINFER_TEST_ARGS="$tmp/serve-vision.args" \
  "$root/serve.sh" --profile vision "$tmp/qwen3_8_27b.ninfer" >/dev/null
grep -Fx -- '--vision' "$tmp/serve-vision.args" >/dev/null
NINFER_NO_VRAM_CHECK=1 NINFER_SERVER="$tmp/ninfer-serve" NINFER_TEST_ARGS="$tmp/serve-balanced.args" \
  "$root/serve.sh" --profile balanced "$tmp/qwen3_8_27b.ninfer" >/dev/null
grep -Fx -- '--max-context' "$tmp/serve-balanced.args" >/dev/null
grep -Fx -- '131072' "$tmp/serve-balanced.args" >/dev/null
grep -Fx -- 'rk8v4' "$tmp/serve-balanced.args" >/dev/null
NINFER_NO_VRAM_CHECK=1 NINFER_SERVER="$tmp/ninfer-serve" NINFER_TEST_ARGS="$tmp/serve-max.args" \
  "$root/serve.sh" --profile max "$tmp/qwen3_8_27b.ninfer" >/dev/null
grep -Fx -- '196608' "$tmp/serve-max.args" >/dev/null
grep -Fx -- 'rk4v4-e8' "$tmp/serve-max.args" >/dev/null
# Locale regression: estimate must print dotted decimals under pt_BR locale.
LC_ALL=pt_BR.UTF-8 NINFER_NO_VRAM_CHECK=1 NINFER_SERVER="$tmp/ninfer-serve" \
  "$root/serve.sh" --estimate "$tmp/qwen3_8_27b.ninfer" >/dev/null
NINFER_NO_VRAM_CHECK=1 NINFER_SERVER="$tmp/ninfer-serve" \
  "$root/serve.sh" --dry-run "$tmp/qwen3_8_27b.ninfer" >/dev/null
NINFER_MODEL_DIR="$tmp" "$root/serve.sh" --list | grep -q 'qwen3_8_27b.ninfer'
# Exit codes: 2 missing model, 1 usage error.
if NINFER_NO_VRAM_CHECK=1 NINFER_SERVER="$tmp/ninfer-serve" \
  "$root/serve.sh" "$tmp/does-not-exist.ninfer" >/dev/null 2>&1; then
  printf 'serve.sh should exit 2 on missing model\n' >&2
  exit 1
fi
if "$root/serve.sh" --bogus-flag >/dev/null 2>&1; then
  printf 'serve.sh should exit nonzero on unknown flag\n' >&2
  exit 1
fi
cat > "$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
while (( $# )); do
  if [[ "$1" == '--output' ]]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
  printf 'ninfer-test-stub' > "$output"
CURL
chmod +x "$tmp/bin/curl"
PATH="$tmp/bin:$PATH" NINFER_MODEL_DIR="$tmp/models" NINFER_QWEN38_SHA256="$test_stub_sha" "$root/download-qwen38.sh" >/dev/null
PATH="$tmp/bin:$PATH" NINFER_MODEL_DIR="$tmp/models" "$root/download-qwen36-35b-vision.sh" >/dev/null
[[ -f "$tmp/models/qwen3_8_27b.ninfer" ]]
[[ -f "$tmp/models/qwen3_6_35b_a3b.ninfer" ]]

# serve.sh rejects v3 artifacts fast (exit 2) instead of booting a container.
printf 'NINFER\x00\x03\x00\x00\x00\x00\x00\x00' > "$tmp/v3.ninfer"
if NINFER_NO_VRAM_CHECK=1 NINFER_SERVER="$tmp/ninfer-serve" \
  "$root/serve.sh" "$tmp/v3.ninfer" >/dev/null 2>&1; then
  printf 'serve.sh should exit 2 on v3 artifact\n' >&2
  exit 1
fi

# switch.sh usage errors.
if "$root/switch.sh" >/dev/null 2>&1; then
  printf 'switch.sh should exit nonzero without --profile\n' >&2
  exit 1
fi
if "$root/switch.sh" --bogus-flag >/dev/null 2>&1; then
  printf 'switch.sh should exit nonzero on unknown flag\n' >&2
  exit 1
fi

# switch.sh with no running server: stub docker reports nothing, stub pgrep
# matches nothing (so the test can never touch a real live server), serve.sh
# forwards the profile to the stub server binary.
cat > "$tmp/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
if [[ "$1" == "ps" ]]; then
  exit 0
fi
printf '%s\n' "$@" >> "$DOCKER_CALLS"
exit 0
DOCKER
chmod +x "$tmp/bin/docker"
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/pgrep"
chmod +x "$tmp/bin/pgrep"
export DOCKER_CALLS="$tmp/docker.calls"
NINFER_NO_VRAM_CHECK=1 NINFER_SERVER="$tmp/ninfer-serve" NINFER_TEST_ARGS="$tmp/switch-c1.args" \
  PATH="$tmp/bin:$PATH" "$root/switch.sh" --profile c1 --port 18083 "$tmp/qwen3_8_27b.ninfer" >/dev/null
grep -Fx -- '65536' "$tmp/switch-c1.args" >/dev/null
grep -Fx -- '18083' "$tmp/switch-c1.args" >/dev/null
NINFER_NO_VRAM_CHECK=1 NINFER_SERVER="$tmp/ninfer-serve" NINFER_TEST_ARGS="$tmp/switch-max.args" \
  PATH="$tmp/bin:$PATH" "$root/switch.sh" --profile max --port 18083 "$tmp/qwen3_8_27b.ninfer" >/dev/null
grep -Fx -- '196608' "$tmp/switch-max.args" >/dev/null
grep -Fx -- 'rk4v4-e8' "$tmp/switch-max.args" >/dev/null

printf '%s\n' 'Linux script checks passed.'
