import Foundation

// Coordinates the per-engine clients (see Engines/): builds them from current settings,
// polls discovery concurrently, and dispatches load/unload. The UI binds to `engines`.
@MainActor
public final class ModelStore: ObservableObject {
    @Published var engines: [EngineState] = []
    // Models with an in-flight load/unload — so only the clicked button disables (others stay live).
    // A key is cleared after its operation completes plus a short cool-down.
    @Published private(set) var busyModels: Set<String> = []
    // Per-model load/unload error (shown inline on that model's row); keyed like busyModels.
    @Published private(set) var errorByModel: [String: String] = [:]
    // Models the user has pinned (qualified ids) — protected from the load manager's LRU eviction.
    // A SwiftUI-observable mirror of the persisted Pins set; writes go through Pins (shared truth).
    @Published private(set) var pinnedModels: Set<String> = []
    // Per-engine reachability for the Engines pane (enabled engines only): .ok / .unauthorized
    // (key rejected) / .unreachable. .ok is derived from discovery; the rest from a probe.
    @Published private(set) var engineStatus: [EngineKind: EngineStatus] = [:]
    // Ollama's /api/ps lags ~100–200ms behind /api/generate, so refreshing right after a
    // load/unload would still report the old loaded state. Let it settle first.
    private static let settleNanos: UInt64 = 250_000_000   // 250ms

    private var pollTask: Task<Void, Never>?

    public init() { pinnedModels = Pins.all() }

    // Live engine clients from current settings (rebuilt each use so port/key edits take effect).
    // Shared with the proxy via EngineRegistry so the UI and the endpoint see one source of truth.
    private func clients() -> [ModelEngine] { EngineRegistry.live() }

    private var refreshSeconds: UInt64 { UInt64(max(1, UserDefaults.standard.integer(forKey: SettingsKeys.refreshInterval))) }

    func start() async {
        guard pollTask == nil else { return }
        await ModelStore.autoDetectEnginesIfNeeded()   // first run: seed the enabled set from what's reachable
        await refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let secs = self?.refreshSeconds ?? 5
                try? await Task.sleep(nanoseconds: secs * 1_000_000_000)
                await self?.refresh()
            }
        }
    }

    // Stop polling (e.g. when the Settings window closes) so we don't discover forever in the
    // background. start() re-arms it.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // Shared with the proxy via DiscoveryCache, so the UI and the HTTP endpoints discover once.
    func refresh() async {
        let states = await DiscoveryCache.shared.current()
        engines = states
        await updateEngineStatus(discovered: states)
    }

    // Force a fresh discovery + status probe now (e.g. right after toggling an engine on/off).
    func refreshNow() async {
        await DiscoveryCache.shared.invalidate()
        await refresh()
    }

    // Per-engine status: an engine that discovered is .ok; for an enabled engine that didn't, probe
    // it to tell "key rejected" from "down" — so working engines cost no extra requests.
    private func updateEngineStatus(discovered states: [EngineState]) async {
        let discoveredKinds = Set(states.map(\.kind))
        let toProbe = EngineRegistry.live().filter { !discoveredKinds.contains($0.kind) }
        var probed: [EngineKind: EngineStatus] = [:]
        await withTaskGroup(of: (EngineKind, EngineStatus).self) { group in
            for client in toProbe { group.addTask { (client.kind, await client.probe()) } }
            for await (kind, s) in group { probed[kind] = s }
        }
        var status: [EngineKind: EngineStatus] = [:]
        for kind in EngineKind.allCases where kind.isEnabled {
            status[kind] = discoveredKinds.contains(kind) ? .ok : (probed[kind] ?? .unreachable)
        }
        engineStatus = status
    }

    // First launch only: probe every engine and enable those that answer (.ok or .unauthorized — the
    // engine is there even with a bad key), so the user starts with just the engines they run.
    // Static + nonisolated so it can run at app launch (not only when Settings opens). Idempotent.
    public nonisolated static func autoDetectEnginesIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: SettingsKeys.enginesAutoDetected) else { return }
        await withTaskGroup(of: (EngineKind, EngineStatus).self) { group in
            for client in EngineRegistry.allClients() { group.addTask { (client.kind, await client.probe()) } }
            for await (kind, status) in group {
                UserDefaults.standard.set(status != .unreachable, forKey: kind.enabledKey)
            }
        }
        UserDefaults.standard.set(true, forKey: SettingsKeys.enginesAutoDetected)
    }

    func canControl(_ engineName: String) -> Bool {
        engines.first { $0.name == engineName }?.canControl ?? false
    }

    // Is this specific model's Load/Unload operation in flight?
    func isBusy(engineName: String, modelID: String) -> Bool {
        busyModels.contains(Self.busyKey(engineName, modelID))
    }

    // Per-model load/unload error message (shown on that model's row), or nil.
    func error(engineName: String, modelID: String) -> String? {
        errorByModel[Self.busyKey(engineName, modelID)]
    }

    private static func busyKey(_ engine: String, _ id: String) -> String { engine + "\u{0}" + id }

    // Is this model pinned (protected from eviction)?
    func isPinned(kind: EngineKind, modelID: String) -> Bool {
        pinnedModels.contains(Pins.keyFor(kind, modelID))
    }

    // Toggle a model's pin, persisting through Pins (read live by the load manager).
    func togglePin(kind: EngineKind, modelID: String) {
        Pins.setPinned(!isPinned(kind: kind, modelID: modelID), kind, modelID)
        pinnedModels = Pins.all()
        // Re-apply keep-warm to a currently-loaded Ollama model: OllamaEngine.load reads the pin and
        // sets keep_alive accordingly (-1 when pinned so the engine never idle-unloads it; its own
        // default otherwise). Other engines have no equivalent, so their pins stay best-effort.
        guard kind == .ollama,
              engines.first(where: { $0.kind == kind })?.models.first(where: { $0.id == modelID })?.loaded == true,
              let client = clients().first(where: { $0.kind == kind }) else { return }
        Task { _ = await client.load(modelID) }
    }

    func toggleLoad(engineName: String, modelID: String) {
        let key = Self.busyKey(engineName, modelID)
        guard !busyModels.contains(key),
              let p = engines.first(where: { $0.name == engineName }),
              let model = p.models.first(where: { $0.id == modelID }),
              let client = clients().first(where: { $0.kind == p.kind }) else { return }
        let load = !model.loaded
        busyModels.insert(key)
        errorByModel[key] = nil
        Task {
            // A UI load goes through the same admission gate as the endpoint (refuse-if-full, never
            // auto-evict): it seeds LoadManager's LRU — so a deliberately-loaded model isn't the first
            // eviction victim — and keeps the canLoad gate in one place. Unload is never gated.
            if load, case .insufficientMemory = await LoadManager.shared.admit(
                kind: p.kind, model: modelID, force: false, policy: .refuseIfFull) {
                errorByModel[key] = "Not enough free memory to load this model right now."
                busyModels.remove(key)
                return
            }
            let t0 = Date()
            let opError = load ? await client.load(modelID) : await client.unload(modelID)
            let secs = Date().timeIntervalSince(t0)
            if load { await LoadManager.shared.releaseReservation(kind: p.kind, model: modelID) }   // load resolved
            let qualified = "\(p.kind.token)/\(modelID)"
            if let opError {
                EventLog.model("Failed to \(load ? "load" : "unload") \(qualified)", detail: opError, seconds: secs, ok: false)
            } else {
                EventLog.model("\(load ? "Loaded" : "Unloaded") \(qualified)", seconds: secs)
            }
            try? await Task.sleep(nanoseconds: Self.settleNanos)   // see settleNanos (Ollama /api/ps lag)
            await DiscoveryCache.shared.invalidate()               // re-discover fresh post-op
            await refresh()
            // Primary signal is the op's own error; the discovery is a secondary "did it take?" check.
            if let opError {
                errorByModel[key] = "Couldn't \(load ? "load" : "unload"): \(opError)"
            } else if let m = engines.first(where: { $0.name == engineName })?
                .models.first(where: { $0.id == modelID }), m.loaded != load {
                errorByModel[key] = "Couldn't \(load ? "load" : "unload")."
            }
            busyModels.remove(key)
        }
    }
}

#if DEBUG
extension ModelStore {
    /// Sample data for SwiftUI previews (no network polling).
    static var preview: ModelStore {
        let s = ModelStore()
        s.engines = [
            EngineState(name: "Ollama", kind: .ollama, canControl: true, models: [
                ModelInfo(id: "qwen2.5:7b", loaded: true, sizeBytes: 4_700_000_000, contextLength: 8192, estimatedSizeBytes: 6_300_000_000),
                ModelInfo(id: "llama3.3:latest", loaded: false, sizeBytes: 42_500_000_000, contextLength: nil, estimatedSizeBytes: 46_750_000_000),
            ]),
            EngineState(name: "oMLX", kind: .omlx, canControl: true, models: [
                ModelInfo(id: "Qwen2.5-Coder-7B-Instruct-MLX-4bit", loaded: false, sizeBytes: 4_300_000_000, contextLength: 32768, estimatedSizeBytes: 4_300_000_000),
                ModelInfo(id: "Mistral-Nemo-Instruct-2407-4bit", loaded: true, sizeBytes: 7_100_000_000, contextLength: 131072, estimatedSizeBytes: 7_100_000_000),
            ]),
            EngineState(name: "LM Studio", kind: .lmstudio, canControl: true, models: [
                ModelInfo(id: "lmstudio-community/Qwen2.5-7B", loaded: false, sizeBytes: 4_400_000_000, contextLength: 32768, estimatedSizeBytes: 4_840_000_000),
            ]),
            EngineState(name: "llama-swap", kind: .llamaswap, canControl: true, models: [
                ModelInfo(id: "qwen2.5-coder", loaded: false, sizeBytes: nil, contextLength: nil, estimatedSizeBytes: nil),
            ]),
        ]
        s.pinnedModels = [Pins.keyFor(.ollama, "qwen2.5:7b")]   // a pinned example for previews
        s.engineStatus = [.ollama: .ok, .omlx: .ok, .lmstudio: .unauthorized, .llamaswap: .unreachable]
        return s
    }
}
#endif
