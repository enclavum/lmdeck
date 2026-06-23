```
Apps, agents, scripts                       LMDeck menu bar                               User
        │                  ┌─────────────────────────────────────────────┐                  │
        │                  │  ┌───────────────────────────────────────┐  │    at a glance   │
        │                  │  │      cross-engine loaded models       │◀─┼──────────────────┘
        │                  │  │     overview in the toolbar popup     │  │
        │                  │  ├───────────────────────────────────────┤  │
        │                  │  │         controls in settings          │  │
        │                  │  └───────────────────────────────────────┘  │
        │                  ├─────────────────────────────────────────────┤
        │                  │               localhost:5678/v1             │
        │    OpenAI API    │  ┌──────────────┐  ┌─────────────────────┐  │
        └──────────────────┼─▶│ smart router │─▶│ memory-aware loader │  │
                           │  │  to engines  │  │   (with optional    │  │
                           │  │   by model   │  │    auto-eviction)   │  │
                           │  └──────────────┘  └─────────────────────┘  │
                           └────────┬────────┬────────────────┬──────────┘
                                    │        │                │
                               ┌────▼───┐ ┌──▼───┐     ┌──────▼───────┐
                               │ Ollama │ │ oMLX │ ... │ more engines │
                               └────────┘ └──────┘     └──────────────┘
```

```
OpenAI client  (Open WebUI · your IDE · curl · scripts)
      │
      │  POST /v1/chat/completions   { "model": "qwen3.6:27b", … }
      ▼
  ┌──────────────────────────────────────────────────────────────────────────────────────────────┐
  │                                                                                              │
  │  LMDeck  ·  http://localhost:5678/v1                                                         │ 
  │                                                                                              │
  │   │                                                                                          │
  │   ├─ 1  resolve engine        "qwen3.6:27b"      ─▶  the engine that owns it                 │
  │   │                                                                                          │
  │   ├─ 2  check model status    is the model already loaded?                                   │
  │   │                           • yes              ─▶  forward (step #4)                       │
  │   │                                                                                          │
  │   ├─ 3  admit                 will the model fit in free RAM (minus a safety reserve)?       │
  │   │                           • fits             ─▶  forward (step #4)                       │
  │   │                           • needs room       ─▶  evict the least-recently-used UNPINNED  │
  │   │                                                  model across ANY engine, then load      │
  │   │                           • still won't fit  ─▶  503 insufficient_memory (never an OOM)  │
  │   │                                                                                          │
  │   └─ 4  stream                the SSE response straight back, unbuffered                     │
  │                                                                                              │
  └───┬──────────────────────────────────────────────────────────────────────────────────────────┘
      │
      ├────────────────┬───────────────────────┐
      │                │                       │
      ▼                ▼                       ▼
    Ollama           oMLX        ...      more engines
```
