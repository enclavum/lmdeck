# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security reports.

- **Preferred:** open a private report via **GitHub → Security → Report a vulnerability**.
- **Alternatively:** email **security@lmdeck.app** (active once the domain is live).

Include the LMDeck version, your macOS version, reproduction steps, and the impact. We aim to
acknowledge reports within a few days and will coordinate a fix and disclosure timeline with you.
Please give us reasonable time to release a fix before public disclosure.

## Supported versions

LMDeck is pre-1.0; only the latest release and `main` receive security fixes.

| Version | Supported |
|---------|-----------|
| latest / `main` | ✅ |
| older pre-releases | ❌ |

## Scope & hardening notes

LMDeck is a **local control plane** in front of your own model engines. Properties worth knowing
when assessing risk:

- The endpoint binds to **`127.0.0.1` by default**. Binding to `0.0.0.0` exposes it on your LAN; set
  an API key to require `Authorization: Bearer`. Without a key on `0.0.0.0`, the **load/unload**
  control endpoints are refused (they could exhaust RAM or drive compute) — the chat proxy stays open.
- The endpoint key comparison is constant-time. Inbound `Authorization` headers are dropped and
  replaced with each provider's own key, so the endpoint key never leaks upstream.
- Provider/endpoint keys are stored via the macOS **data-protection Keychain** on a signed build
  (UserDefaults on the ad-hoc dev build).
- Forwarding targets only locally-configured engines; the upstream path is guarded against traversal
  and request bodies are size-bounded.

Out of scope: vulnerabilities in the upstream engines themselves (Ollama, oMLX, LM Studio,
llama-swap) — report those to the respective projects.
