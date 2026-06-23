# Contributing to LMDeck

Thanks for your interest! LMDeck is a native macOS menu-bar control plane that puts one
OpenAI-compatible endpoint, one catalog, and one memory-safe loader in front of your local LLM
engines (Ollama, oMLX, LM Studio, and llama.cpp via llama-swap).

## Ground rules

- Be respectful — see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
- Open an issue before a large change so we can agree on the approach first.
- Keep the project's deliberate minimalism: **system-native SwiftUI** (the macOS system accent, no
  custom brand theming), four engines, control-plane scope — please don't reintroduce intentionally
  cut features without discussion.

## Building & running

Command-line only — SwiftPM + a Makefile, no Xcode GUI needed to build (targets macOS 15+):

```sh
make run               # build + bundle + ad-hoc sign + launch LMDeck.app
make run-settings      # same, opening the Settings window
make test              # Swift unit tests (needs full Xcode for XCTest / Swift Testing)
make integration-test  # Python integration tests against a running LMDeck
make clean
```

The architecture and conventions are summarized below.

## Architecture & style

- **Core-as-library + thin `@main`**: logic lives in `LMDeckCore` (previewable, unit-testable); the
  executable is just `@main`.
- **Pure/impure split**: response parsing is a `static func parse(...)` (I/O-free, unit-tested);
  URLSession and other side effects stay in instance methods. Routing, aggregation, memory math, and
  auth are pure and covered by tests.
- **Match the surrounding code** — naming, comment density, idioms. Prefer existing components
  (`Card`, `SettingRow`, `Pane`, `DeckButton`) over new UI primitives.

## Tests (required)

Every change keeps **both** suites green and adds coverage:

- **Unit** (`Tests/LMDeckCoreTests/`, Swift Testing) — for new or changed **pure** logic.
- **Integration** (`integration/`, pytest against a running LMDeck) — for new or changed
  behavior with **side effects** (the proxy, routing, auth, load/unload, streaming).

Run `make test` and `make integration-test` before opening a PR.

## Pull requests

1. Branch off `main`; keep PRs focused.
2. Describe the change and how you tested it (the PR template prompts for this).
3. Ensure `make test` passes and the integration suite is updated where behavior changed.
4. By submitting a contribution, you agree it is licensed under the project's
   [Apache License 2.0](LICENSE) — inbound = outbound (section 5 of the license), so no separate CLA
   is required.
