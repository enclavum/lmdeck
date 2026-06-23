# Changelog

All notable changes to LMDeck are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Pre-1.0 development. Highlights so far:

- **Cross-engine memory-aware admission** (the moat): the proxy pre-flights an unloaded model's
  footprint before forwarding and silently evicts the least-recently-used **unpinned** model across
  any engine to make room, or refuses with `503` — so a request never OOMs the machine. Pinning +
  an auto-evict toggle included.
- **One OpenAI-compatible endpoint** (`POST /v1/**`) plus a native catalog (`GET /api/v1/models`)
  across Ollama, oMLX, LM Studio, and llama.cpp (via llama-swap), with gated native load/unload.
- **Memory estimates** with a generic KV term where an engine doesn't expose its architecture, and a
  realistic default-context cap for unloaded models.
- **Logs** tab — a durable, monospaced activity log of model + server events.
- **Keychain-backed API keys** via the macOS data-protection Keychain (UserDefaults fallback on the
  ad-hoc dev build), read-once-cached and write-through.
- Admin (load/unload) endpoints refused when bound to `0.0.0.0` without an API key.

_No tagged releases yet._
