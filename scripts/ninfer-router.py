#!/usr/bin/env python3
"""NInfer model router: Ollama-style load/unload across serve.sh profiles.

Listens on ROUTER_PORT (default 18089) and forwards to a single ninfer-serve
backend on BACKEND_PORT (default 8080). The requested OpenAI model name picks
the backend profile:

  qwen3.8-27b-max   -> serve.sh --profile max      (192K, rk4v4-e8)
  *64k*             -> serve.sh --profile c1        (64K, int8, widest KV)
  qwen3.8-27b*      -> serve.sh --profile balanced (128K, rk8v4)

Any other model name reuses whatever backend is running (the server accepts
arbitrary model strings). Switching profiles stops the running container and
boots the wanted one (~60s cold start); after IDLE_SEC seconds without
requests the backend is stopped to free VRAM.

Env:
  NINFER_ROUTER_PORT / NINFER_BACKEND_PORT / NINFER_ROUTER_IDLE_SEC (default 900)
  NINFER_MODEL_DIR / NINFER_DOCKER_IMAGE (forwarded to serve.sh)
"""
import http.client
import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.path.dirname(os.path.abspath(__file__))
SERVE = os.path.join(REPO, "serve.sh")
MODEL_V2 = os.path.join(
    os.environ.get("NINFER_MODEL_DIR", os.path.join(REPO, "models")),
    "qwen3_8_27b-v2.ninfer",
)
IMAGE = os.environ.get("NINFER_DOCKER_IMAGE", "ninfer-4090:sm89")
ROUTER_PORT = int(os.environ.get("NINFER_ROUTER_PORT", "18089"))
BACKEND_PORT = int(os.environ.get("NINFER_BACKEND_PORT", "8080"))
IDLE_SEC = int(os.environ.get("NINFER_ROUTER_IDLE_SEC", "900"))
BOOT_TIMEOUT = 420

PROFILES = {"balanced", "max", "c1"}

lock = threading.Lock()
state = {"profile": None, "busy": False, "last_used": 0.0, "active": 0}


def log(*a):
    print(f"[router {time.strftime('%H:%M:%S')}]", *a, flush=True)


def sh(*cmd, timeout=60):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "").strip()
    except Exception as e:
        return 1, str(e)


def backend_container():
    rc, out = sh("docker", "ps", "-q", "--filter", f"ancestor={IMAGE}")
    return out.split()[0] if rc == 0 and out else None


def stop_backend():
    cid = backend_container()
    if cid:
        log("stopping backend", cid)
        sh("docker", "stop", cid, timeout=120)
    state["profile"] = None


def start_backend(profile):
    env = dict(os.environ)
    log(f"starting profile {profile}")
    subprocess.Popen(
        [SERVE, MODEL_V2, "--profile", profile, "--port", str(BACKEND_PORT)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL, env=env, start_new_session=True,
    )
    t0 = time.time()
    while time.time() - t0 < BOOT_TIMEOUT:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", BACKEND_PORT, timeout=5)
            conn.request("GET", "/health")
            if conn.getresponse().status == 200:
                state["profile"] = profile
                log(f"profile {profile} listening")
                return True
        except Exception:
            pass
        time.sleep(3)
    log(f"profile {profile} failed to listen in {BOOT_TIMEOUT}s")
    return False


def wanted_profile(model):
    if isinstance(model, str):
        if model.startswith("qwen3.8-27b-max"):
            return "max"
        if "64k" in model:
            return "c1"
    return "balanced"


def ensure_backend(profile):
    """Must hold `lock`. Returns True when the wanted profile serves."""
    if state["profile"] == profile and backend_container():
        return True
    if backend_container() or state["profile"]:
        stop_backend()
    # Wait for the port to actually free (container teardown races).
    t0 = time.time()
    while time.time() - t0 < 120:
        try:
            c = http.client.HTTPConnection("127.0.0.1", BACKEND_PORT, timeout=3)
            c.request("GET", "/health")
            c.getresponse()
            time.sleep(2)
        except Exception:
            break
    return start_backend(profile)


def idle_watch():
    while True:
        time.sleep(30)
        with lock:
            if (state["profile"] and state["active"] == 0
                    and time.time() - state["last_used"] > IDLE_SEC):
                log(f"idle {IDLE_SEC}s: unloading {state['profile']}")
                stop_backend()


STATIC_MODELS = {
    "object": "list",
    "data": [
        {"id": "qwen3.8-27b-64k", "object": "model", "owned_by": "ninfer",
         "name": "qwen3.8-27b-64k", "context_window": 65536,
         "max_model_len": 65536, "modalities": {"vision": False}},
        {"id": "qwen3.8-27b", "object": "model", "owned_by": "ninfer",
         "name": "qwen3.8-27b", "context_window": 131072,
         "max_model_len": 131072, "modalities": {"vision": False}},
        {"id": "qwen3.8-27b-max", "object": "model", "owned_by": "ninfer",
         "name": "qwen3.8-27b-max", "context_window": 196608,
         "max_model_len": 196608, "modalities": {"vision": False}},
    ],
}

HOP_HEADERS = {"connection", "keep-alive", "transfer-encoding", "upgrade"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ninfer-router"

    def _send(self, status, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        return self.rfile.read(n) if n > 0 else b""

    def do_GET(self):
        if self.path == "/health":
            with lock:
                snap = dict(state)
            return self._send(200, json.dumps({"status": "router-ok",
                                              "backend": snap["profile"],
                                              "busy": snap["busy"]}))
        if self.path == "/v1/models":
            with lock:
                up = state["profile"] and backend_container()
            if up:
                return self._relay(None)
            # Idle: advertise both variants so pickers work cold.
            return self._send(200, json.dumps(STATIC_MODELS))
        return self._relay(None)

    def do_POST(self):
        body = self._read_body()
        profile = None
        if self.path.startswith("/v1/chat/completions") or \
                self.path.startswith("/v1/messages"):
            try:
                profile = wanted_profile(json.loads(body or b"{}").get("model"))
            except Exception:
                profile = None
        return self._relay(body, profile)

    def _relay(self, body, profile=None):
        with lock:
            if profile and profile in PROFILES:
                state["busy"] = True
                try:
                    if not ensure_backend(profile):
                        state["busy"] = False
                        return self._send(502, json.dumps(
                            {"error": f"backend profile {profile} failed to start"}))
                finally:
                    state["busy"] = False
            state["active"] += 1
        try:
            fwd = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP_HEADERS}
            conn = http.client.HTTPConnection("127.0.0.1", BACKEND_PORT,
                                              timeout=3600)
            conn.request(self.command, self.path, body=body or None,
                         headers=fwd)
            resp = conn.getresponse()
            self.send_response(resp.status)
            ctype = resp.getheader("Content-Type", "application/octet-stream")
            self.send_header("Content-Type", ctype)
            length = resp.getheader("Content-Length")
            is_sse = "text/event-stream" in ctype
            if not is_sse and length is not None:
                self.send_header("Content-Length", length)
            self.end_headers()
            if is_sse:
                # Forward event-by-event: block reads batch tokens into
                # bursts and the tail hangs without EOF propagation.
                while True:
                    line = resp.readline()
                    if not line:
                        break
                    try:
                        self.wfile.write(line)
                        self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        break
                self.close_connection = True
            else:
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    try:
                        self.wfile.write(chunk)
                        self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        break
            with lock:
                state["last_used"] = time.time()
        except Exception as e:
            try:
                self._send(502, json.dumps({"error": f"backend error: {e}"}))
            except Exception:
                pass
        finally:
            with lock:
                state["active"] -= 1

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    if not os.path.isfile(MODEL_V2):
        raise SystemExit(f"v2 model not found: {MODEL_V2}")
    # Adopt an already-running backend instead of rebooting it: infer the
    # profile from the container's ninfer-serve args.
    cid = backend_container()
    if cid:
        rc, args = sh("docker", "inspect", "-f", "{{join .Args \" \"}}", cid)
        if rc == 0:
            if "--max-context 196608" in args:
                state["profile"] = "max"
            elif "--max-context 131072" in args:
                state["profile"] = "balanced"
            elif "--max-context 65536" in args:
                state["profile"] = "c1"
            log(f"adopted running backend {cid} as {state['profile']}")
    threading.Thread(target=idle_watch, daemon=True).start()
    log(f"router :{ROUTER_PORT} -> backend :{BACKEND_PORT} (idle {IDLE_SEC}s)")
    ThreadingHTTPServer(("127.0.0.1", ROUTER_PORT), Handler).serve_forever()
