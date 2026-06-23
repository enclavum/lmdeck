"""
Integration tests for LMDeck's proxy + model-list endpoints.

These run against a *running* LMDeck instance (they don't start one). From the repo root:

    make integration-test            # venv + deps + loads integration/.env, then pytest

Or directly (secrets go in a gitignored .env, never hardcoded):

    pip install -r requirements.txt
    cp .env.example .env             # set LMDECK_API_KEY=... in .env if an endpoint key is set
    set -a; . ./.env; set +a         # load it into the environment
    pytest                           # or:  pytest -m "not slow"   to skip model inference

Env vars:
    LMDECK_BASE_URL    default http://localhost:5678   (the LMDeck root; a trailing /v1 is tolerated)
    LMDECK_API_KEY     default ""                      (the endpoint key, if one is configured)
    LMDECK_TEST_MODEL  default "qwen2.5:7b"            (bare name or qualified id for the chat tests)
    LMDECK_TIMEOUT     default 120                     (seconds, for inference calls)

Endpoints under test:
    GET  /v1/models       OpenAI-compatible list (qualified ids: "<engine>/<model>")
    GET  /api/v1/models   native rich catalog (id, model, engine, loaded, size, context_length)
    POST /v1/**           forwarder; bare ids route by hard-coded priority, qualified ids pin an engine
"""
import json
import os

import pytest
import requests

_RAW = os.environ.get("LMDECK_BASE_URL", "http://localhost:5678").rstrip("/")
ROOT = _RAW[:-3] if _RAW.endswith("/v1") else _RAW      # tolerate an old ".../v1" value
V1 = ROOT + "/v1"
APIV1 = ROOT + "/api/v1"
API_KEY = os.environ.get("LMDECK_API_KEY", "")
TEST_MODEL = os.environ.get("LMDECK_TEST_MODEL", "qwen2.5:7b")
SLOW_TIMEOUT = float(os.environ.get("LMDECK_TIMEOUT", "120"))

ENGINES = {"ollama", "omlx", "lmstudio", "llamaswap"}
_SENTINEL = "__default__"


def _headers(key=_SENTINEL, json_body=False):
    h = {}
    k = API_KEY if key is _SENTINEL else key
    if k:
        h["Authorization"] = f"Bearer {k}"
    if json_body:
        h["Content-Type"] = "application/json"
    return h


@pytest.fixture(scope="session")
def session():
    s = requests.Session()
    yield s
    s.close()


@pytest.fixture(scope="session")
def catalog(session):
    """Rows from /api/v1/models. Skips the suite if LMDeck is unreachable or a key is missing."""
    try:
        r = session.get(f"{APIV1}/models", headers=_headers(), timeout=15)
    except requests.RequestException as e:
        pytest.skip(f"LMDeck not reachable at {ROOT} ({e}). Start it and retry.")
    if r.status_code == 401:
        pytest.skip("Endpoint requires an API key — set LMDECK_API_KEY to the key in Settings → Server.")
    assert r.status_code == 200, f"GET /api/v1/models -> {r.status_code}: {r.text[:200]}"
    return r.json().get("models", [])


def _find(catalog, name):
    """A catalog row matching `name` as either a bare model name or a qualified id, else None."""
    for row in catalog:
        if row.get("id") == name or row.get("model") == name:
            return row
    return None


def _chat(session, model, *, stream=False, content="Reply with exactly: hello", max_tokens=16):
    return session.post(
        f"{V1}/chat/completions",
        headers=_headers(json_body=True),
        json={"model": model,
              "messages": [{"role": "user", "content": content}],
              "max_tokens": max_tokens,
              "stream": stream},
        stream=stream,
        timeout=SLOW_TIMEOUT,
    )


# ---------------------------------------------------------------- GET /v1/models

def test_v1_models_qualified_shape(catalog, session):
    r = session.get(f"{V1}/models", headers=_headers(), timeout=15)
    assert r.status_code == 200
    body = r.json()
    assert body.get("object") == "list"
    rows = body.get("data")
    assert isinstance(rows, list)
    for m in rows:
        assert m.get("object") == "model"
        mid = m.get("id")
        assert isinstance(mid, str) and "/" in mid                    # qualified id
        assert mid.split("/", 1)[0] in ENGINES                      # engine prefix
        assert m.get("owned_by") in ENGINES


# ---------------------------------------------------------------- GET /api/v1/models

def test_api_v1_models_shape(catalog):
    for m in catalog:
        assert m["engine"] in ENGINES
        assert m["id"] == f'{m["engine"]}/{m["model"]}'             # id == engine/model
        assert isinstance(m["loaded"], bool)                         # never null
        assert isinstance(m["can_load"], bool)                       # never null
        assert m["size"] is None or isinstance(m["size"], int)       # null when unknown
        assert m["context_length"] is None or isinstance(m["context_length"], int)
        assert m["estimated_size"] is None or isinstance(m["estimated_size"], int)


def test_estimated_size_covers_weights(catalog):
    """A model's estimated RAM footprint must be >= its on-disk size — the weights are resident, plus
    KV + overhead. Guards the memory estimator (the admission gate's input) against gross
    under-estimates. The exact estimate is environment-dependent, so only this invariant is asserted."""
    checked = 0
    for m in catalog:
        s, e = m.get("size"), m.get("estimated_size")
        if s and e:
            assert e >= s, f'{m["id"]}: estimated_size {e} < size {s}'
            checked += 1
    if checked == 0:
        pytest.skip("no model reports both size and estimated_size")


def test_unloaded_generic_estimate_not_ballooned(catalog):
    """Regression (functional-review #1): LM Studio / llama-swap charged the KV term at the *full*
    advertised context for unloaded models, ballooning the footprint to multiples of the weights
    (greys out the Load button / spurious 503s). With the context cap, an unloaded model's estimate
    stays close to its weights — the generic KV at the ~4K cap adds ~10-25%, never multiples. Scoped
    to generic-KV engines; Ollama infers an effective context that can legitimately be larger."""
    rows = [m for m in catalog
            if m["engine"] in ("lmstudio", "llamaswap")
            and not m["loaded"] and m.get("size") and m.get("estimated_size")]
    if not rows:
        pytest.skip("no unloaded LM Studio / llama-swap model with a known size")
    for m in rows:
        assert m["estimated_size"] <= m["size"] * 2, (
            f'{m["id"]}: estimated_size {m["estimated_size"]} is >2x size {m["size"]} '
            f"(unloaded KV context not capped?)")


def test_endpoints_have_identical_ids(catalog, session):
    """The OpenAI and native endpoints must list the same rows with the same ids."""
    v1_ids = [m["id"] for m in session.get(f"{V1}/models", headers=_headers(), timeout=15).json()["data"]]
    native_ids = [m["id"] for m in catalog]
    assert v1_ids == native_ids


# ---------------------------------------------------------------- auth gate

def test_auth_enforcement(session):
    """No key / wrong key are rejected when the endpoint has a key; open otherwise."""
    try:
        no_auth = session.get(f"{APIV1}/models", timeout=15)
    except requests.RequestException as e:
        pytest.skip(f"LMDeck not reachable at {ROOT} ({e}).")
    assert no_auth.status_code in (200, 401)
    if no_auth.status_code == 401:
        assert API_KEY, "Endpoint requires a key but LMDECK_API_KEY is unset — can't verify the happy path."
        assert session.get(f"{APIV1}/models", headers=_headers("wrong-key"), timeout=15).status_code == 401
        assert session.get(f"{APIV1}/models", headers=_headers(), timeout=15).status_code == 200


# ---------------------------------------------------------------- routing errors

def test_unknown_bare_model_returns_404(session, catalog):
    assert _chat(session, "lmdeck-no-such-model-zzz").status_code == 404


def test_qualified_unknown_model_returns_404(session, catalog):
    # Real engine token, model it doesn't have → 404 (an explicit pin is not silently rerouted).
    assert _chat(session, "ollama/lmdeck-no-such-model-zzz").status_code == 404


def test_missing_model_returns_400(session, catalog):
    r = session.post(f"{V1}/chat/completions", headers=_headers(json_body=True),
                     json={"messages": [{"role": "user", "content": "hi"}]}, timeout=30)
    assert r.status_code == 400, r.text[:200]


def test_path_traversal_rejected(session, catalog):
    # The forwarder echoes the path to the local engine, so traversal out of /v1/* is refused.
    r = session.post(f"{V1}/%2e%2e/admin", headers=_headers(json_body=True),
                     json={"model": "x"}, timeout=15)
    assert r.status_code == 400, r.text[:200]


# ---------------------------------------------------------------- native load / unload

def test_load_missing_model_returns_400(session, catalog):
    r = session.post(f"{APIV1}/models/load", headers=_headers(json_body=True), json={}, timeout=30)
    assert r.status_code == 400, r.text[:200]


def test_load_unknown_model_returns_404(session, catalog):
    r = session.post(f"{APIV1}/models/load", headers=_headers(json_body=True),
                     json={"model": "lmdeck-no-such-model-zzz"}, timeout=30)
    assert r.status_code == 404, r.text[:200]


def test_load_gate_rejects_when_too_big(session, catalog):
    """A model the catalog reports as can_load=false → 409 insufficient_memory (no force)."""
    row = next((m for m in catalog if not m["loaded"] and m["can_load"] is False), None)
    if not row:
        pytest.skip("no currently-unloadable model to exercise the gate")
    r = session.post(f"{APIV1}/models/load", headers=_headers(json_body=True),
                     json={"model": row["id"]}, timeout=30)
    assert r.status_code == 409, r.text[:200]
    assert r.json()["error"]["type"] == "insufficient_memory"


@pytest.mark.slow
def test_load_unload_round_trip(session, catalog):
    """Smallest unloaded model that fits → load (loaded:true) then unload (loaded:false)."""
    fits = [m for m in catalog if not m["loaded"] and m["can_load"] and m.get("size")]
    if not fits:
        pytest.skip("no small unloaded loadable model available")
    mid = min(fits, key=lambda m: m["size"])["id"]

    r = session.post(f"{APIV1}/models/load", headers=_headers(json_body=True),
                     json={"model": mid}, timeout=SLOW_TIMEOUT)
    assert r.status_code == 200, r.text[:200]
    body = r.json()
    assert body["id"] == mid and body["loaded"] is True

    r = session.post(f"{APIV1}/models/unload", headers=_headers(json_body=True),
                     json={"model": mid}, timeout=SLOW_TIMEOUT)
    assert r.status_code == 200, r.text[:200]
    assert r.json()["loaded"] is False


# ---------------------------------------------------------------- proxy-path memory admission

@pytest.mark.slow
def test_proxy_path_is_memory_gated(session, catalog):
    """A chat request to an unloaded model that doesn't fit must be admission-gated, not an ungated
    JIT load: LMDeck either frees room and serves it (200, the auto-evict default) or refuses cleanly
    (503 insufficient_memory). Skips when nothing in the catalog is currently too big to load."""
    row = next((m for m in catalog if not m["loaded"] and m["can_load"] is False), None)
    if not row:
        pytest.skip("no currently-unloadable model to exercise the proxy gate")
    r = _chat(session, row["id"], content="hi", max_tokens=1)
    assert r.status_code in (200, 503), r.text[:300]
    if r.status_code == 503:
        assert r.json()["error"]["type"] == "insufficient_memory", r.text[:300]


# ---------------------------------------------------------------- real completions (slow)

@pytest.mark.slow
def test_chat_completion_bare_and_qualified(session, catalog):
    row = _find(catalog, TEST_MODEL)
    if not row:
        pytest.skip(f"{TEST_MODEL!r} not in catalog; set LMDECK_TEST_MODEL to a listed model or its bare name")
    for model in (row["model"], row["id"]):          # bare name (priority-routed) then qualified id
        r = _chat(session, model, stream=False)
        assert r.status_code == 200, f"model={model}: {r.text[:300]}"
        body = r.json()
        assert body.get("object") == "chat.completion"
        content = body["choices"][0]["message"]["content"]
        assert isinstance(content, str) and content.strip() != ""


@pytest.mark.slow
def test_chat_completion_streaming(session, catalog):
    row = _find(catalog, TEST_MODEL)
    if not row:
        pytest.skip(f"{TEST_MODEL!r} not in catalog; set LMDECK_TEST_MODEL to a listed model or its bare name")
    chunks, saw_done = 0, False
    with _chat(session, row["id"], stream=True, content="Count 1 to 5", max_tokens=32) as r:
        assert r.status_code == 200, r.text[:300]
        for raw in r.iter_lines(decode_unicode=True):
            if not raw or not raw.startswith("data:"):
                continue
            payload = raw[len("data:"):].strip()
            if payload == "[DONE]":
                saw_done = True
                break
            obj = json.loads(payload)
            assert obj.get("object") == "chat.completion.chunk"
            chunks += 1
    assert chunks > 0, "no streaming chunks received"
    assert saw_done, "stream did not end with the [DONE] sentinel"
