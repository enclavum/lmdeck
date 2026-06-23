# Changelog

All notable changes to LMDeck are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-06-23

First public release.

### Added

- **One OpenAI-compatible endpoint** (`http://localhost:5678/v1`) fronting **Ollama, oMLX, LM Studio,
  and llama.cpp (via llama-swap)**. `POST /v1/**` routes by the request's `model` to the owning engine
  and streams the response back unbuffered; `GET /v1/models` returns the union across engines.
- **Smart routing** — a bare id resolves to the highest-priority engine that has it; `engine/model`
  pins an engine (404 rather than silent reroute); an HF-style `org/model` id is treated as a bare name.
- **Cross-engine memory-aware admission** — every load (proxy just-in-time or explicit) is pre-flighted
  against free RAM. With auto-evict on (default), LMDeck silently unloads the least-recently-used
  **unpinned** model across *any* engine to make room; otherwise it refuses with `503` / `409
  insufficient_memory`. In-flight loads reserve their footprint so concurrent first-loads can't OOM.
- **Pinning** — pinned models are never evicted by LMDeck; on Ollama they're also held resident in the
  engine (no idle timeout).
- **Native control API** — `GET /api/v1/models` (catalog with `loaded`, `size`, `context_length`,
  `estimated_size`, `can_load`) and memory-gated, idempotent `POST /api/v1/models/{load,unload}`.
- **Menu-bar app** — an at-a-glance popup (free RAM + every loaded model across engines) and a native
  Settings window (Server, Models, Engines, Logs, About).
- **Near-zero setup** — first launch auto-detects and enables the engines you're running; an
  **Auto configure** button reads each engine's port and API key from its settings file, environment,
  or launch arguments (read-only, never shells out to a CLI).
- **Exposure-scaled security** — loopback is open; binding to `0.0.0.0` auto-enables an admin gate
  (load/unload blocked without a key), a concurrency cap, and a request-size limit. Endpoint and engine
  API keys are stored in the macOS data-protection Keychain in signed builds.
- **Activity log** — a durable, monospaced log of model and server events.
- **Automatic update check** against GitHub Releases.
