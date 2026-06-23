# LMDeck integration tests

End-to-end tests against a **running** LMDeck instance — they exercise the real endpoints: the
OpenAI list (`GET /v1/models`), the native catalog (`GET /api/v1/models`), the auth gate, model
routing (bare-id priority + qualified-id pinning), and streaming/non-streaming completions. They do
**not** launch LMDeck; start it first (`make run` from the repo root).

> **Secrets:** your endpoint API key lives only in `integration/.env`, which is
> **gitignored**. Never commit real keys — `.env.example` is the committed template.

> **Keep this suite current:** update it whenever you change proxy behavior (and add Swift unit
> tests for new pure logic). See the repo README's *Testing* section.

## Run

From the repo root, `make integration-test` does everything (creates the venv, installs deps, loads
`integration/.env`, runs pytest):

```sh
make integration-test                       # all tests
make integration-test ARGS="-m 'not slow'"  # skip the model-inference tests (fast)
```

(`make test` runs the **Swift unit tests** — a different suite.)

Or manually:

```sh
cd integration
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

cp .env.example .env            # then edit .env: set LMDECK_API_KEY=... if an endpoint key is set
set -a; . ./.env; set +a        # load it into the environment

pytest                 # everything
pytest -m "not slow"   # skip the model-inference tests
```

## Configuration (env vars — set in `.env`)

| Var | Default | Purpose |
|-----|---------|---------|
| `LMDECK_API_KEY`    | _(empty)_ | Endpoint key, if one is configured |
| `LMDECK_BASE_URL`   | `http://localhost:5678` | LMDeck root URL (a trailing `/v1` is tolerated) |
| `LMDECK_TEST_MODEL` | `qwen2.5:7b` | Bare name or qualified id for the completion tests (skipped if not in the catalog) |
| `LMDECK_TIMEOUT`    | `120` | Seconds to wait on inference calls |

## What's covered

- `GET /v1/models` — OpenAI-shaped list of **qualified** ids (`<engine>/<model>`) with `owned_by`
- `GET /api/v1/models` — native catalog: `id == engine/model`, `loaded`/`can_load` booleans, `size`/`context_length`/`estimated_size` int-or-null
- **Parity:** both endpoints list the same rows with the same ids
- `POST /api/v1/models/load` + `/unload` — load/unload round-trip (`loaded` flips), the memory gate (`409 insufficient_memory`), unknown → `404`, missing `model` → `400`
- **Proxy-path memory admission** — a chat request to an unloaded model that won't fit is gated: LMDeck either frees room and serves it (`200`, auto-evict default) or refuses cleanly (`503 insufficient_memory`) — never an ungated JIT load
- Auth: no key / wrong key → `401` when an endpoint key is set (open otherwise)
- Routing errors: unknown bare model → `404`, qualified id whose engine lacks it → `404`, missing `model` → `400`
- Real completions through the forwarder, by **bare name** (priority-routed) and **qualified id**:
  non-streaming (`chat.completion`) and streaming SSE (`chat.completion.chunk` … `[DONE]`) — marked `slow`
