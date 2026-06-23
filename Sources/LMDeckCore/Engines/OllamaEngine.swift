import Foundation

// Ollama: list/size via /api/tags, loaded state via /api/ps; load via /api/generate (Ollama's own
// keep-alive applies), unload via /api/generate with keep_alive=0.
// /api/show supplies each model's native context length AND architecture (layers / KV heads / hidden
// size), which together give a KV-cache-accurate RAM estimate.
final class OllamaEngine: ModelEngine {
    override var canControl: Bool { true }
    override var probePath: String { "api/tags" }

    override func discover() async -> EngineState? {
        guard let tags = try? await get("api/tags") else { return nil }
        let ps = try? await get("api/ps")
        let parsed = Self.parse(tags: tags, ps: ps)
        let digests = Self.digests(tags: tags)   // model id → content digest (the cache key)
        // Fetch each model's /api/show once (cached by digest) for native context + architecture.
        var info: [String: ShowInfo] = [:]
        let maxConcurrent = 6   // bound the cold-start /api/show burst against the local daemon
        await withTaskGroup(of: (String, ShowInfo?).self) { group in
            var next = 0
            for _ in 0..<min(maxConcurrent, parsed.count) {
                let m = parsed[next]; next += 1
                group.addTask { (m.id, await self.showInfo(of: m.id, digest: digests[m.id])) }
            }
            while let (id, si) = await group.next() {
                if let si { info[id] = si }
                if next < parsed.count {                       // keep at most maxConcurrent in flight
                    let m = parsed[next]; next += 1
                    group.addTask { (m.id, await self.showInfo(of: m.id, digest: digests[m.id])) }
                }
            }
        }
        // The context Ollama is actually loading at here (OLLAMA_CONTEXT_LENGTH, or a request's
        // num_ctx) — inferred from the largest context among currently-resident models — so the
        // footprint estimate for *unloaded* models tracks reality instead of a stale 4K default.
        let effectiveContext = parsed.compactMap { $0.loaded ? $0.contextLength : nil }.max()
        let models = parsed.map { m -> ModelInfo in
            let e = Self.estimate(weightsBytes: m.sizeBytes, loaded: m.loaded,
                                  loadedContext: m.contextLength, nativeContext: info[m.id]?.context,
                                  archKVPerToken: info[m.id]?.kvPerToken, effectiveContext: effectiveContext)
            return ModelInfo(id: m.id, loaded: m.loaded, sizeBytes: m.sizeBytes,
                             contextLength: e.context, estimatedSizeBytes: e.estimate)
        }
        return state(models)
    }

    struct ShowInfo { let context: Int?; let kvPerToken: Int? }

    // Keyed by content digest (not the tag), so a re-pulled tag with changed arch/context isn't
    // served stale. Falls back to the model id when no digest is available. Never evicted, but bounded
    // by the count of distinct local model digests, so it can't grow unbounded.
    private static let cacheLock = NSLock()
    private static var infoCache: [String: ShowInfo] = [:]

    private func showInfo(of model: String, digest: String?) async -> ShowInfo? {
        let cacheKey = digest ?? model
        Self.cacheLock.lock(); let hit = Self.infoCache[cacheKey]; Self.cacheLock.unlock()
        if let hit { return hit }
        guard let data = await postForData(path: "api/show", json: ["model": model]) else { return nil }
        let si = ShowInfo(context: Self.contextFromShow(data), kvPerToken: Self.kvPerTokenFromShow(data))
        Self.cacheLock.lock(); Self.infoCache[cacheKey] = si; Self.cacheLock.unlock()
        return si
    }

    // Pure: model id → content digest from /api/tags.
    static func digests(tags: Data) -> [String: String] {
        struct Tags: Decodable { struct M: Decodable { let name: String; let digest: String? }; let models: [M] }
        guard let t = try? JSONDecoder().decode(Tags.self, from: tags) else { return [:] }
        return Dictionary(t.models.compactMap { m in m.digest.map { (m.name, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    // Pure: "<arch>.context_length" from /api/show's model_info (e.g. "qwen2.context_length").
    static func contextFromShow(_ data: Data) -> Int? {
        guard let (info, arch) = modelInfoAndArch(data) else { return nil }
        return archInt(info, arch, "context_length")
    }

    // Pure: KV-cache bytes per token from /api/show's architecture fields, or nil if incomplete.
    static func kvPerTokenFromShow(_ data: Data) -> Int? {
        guard let (info, arch) = modelInfoAndArch(data),
              let layers = archInt(info, arch, "block_count"),
              let heads = archInt(info, arch, "attention.head_count"), heads > 0,
              let kvHeads = archInt(info, arch, "attention.head_count_kv"),
              let embedding = archInt(info, arch, "embedding_length") else { return nil }
        return MemoryEstimate.kvBytesPerToken(layers: layers, kvHeads: kvHeads,
                                              headDim: embedding / heads)
    }

    // model_info + its primary architecture, so we read keys for the *right* block (a multimodal
    // model's model_info carries both a vision tower and the LLM under different `<arch>.` prefixes).
    private static func modelInfoAndArch(_ data: Data) -> (info: [String: Any], arch: String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = obj["model_info"] as? [String: Any],
              let arch = info["general.architecture"] as? String else { return nil }
        return (info, arch)
    }

    private static func archInt(_ info: [String: Any], _ arch: String, _ key: String) -> Int? {
        (info["\(arch).\(key)"] as? NSNumber)?.intValue
    }

    override func load(_ id: String) async -> String? {
        // A pinned model is meant to stay hot, so ask Ollama to keep it resident with no idle timeout
        // (keep_alive: -1). Unpinned loads send no keep_alive → the engine's own OLLAMA_KEEP_ALIVE
        // governs (and LMDeck's LRU can still evict it). LMDeck manages unload explicitly below.
        var json: [String: Any] = ["model": id, "prompt": "", "stream": false]
        if Pins.isPinned(kind, id) { json["keep_alive"] = -1 }
        return await firePOST(path: "api/generate", json: json, timeout: Self.loadTimeout)
    }

    override func unload(_ id: String) async -> String? {
        await firePOST(path: "api/generate",
                       json: ["model": id, "prompt": "", "stream": false, "keep_alive": "0"])
    }

    // Auto-config: Ollama's bind is OLLAMA_HOST (env-only — no config file). Read it from this app's
    // own environment (set session-wide via `launchctl setenv` → inherited here); otherwise fall back
    // to Ollama's default port so the field is always set. Local Ollama has no API key.
    static func detectConfig() -> DetectedEngineConfig {
        var c = DetectedEngineConfig()
        c.port = ProcessInfo.processInfo.environment["OLLAMA_HOST"]
            .flatMap { EngineConfigReader.port(fromListen: $0) } ?? 11434
        return c
    }

    // Pure: (display context, RAM estimate) for one model. The *display* context is the actual loaded
    // window (/api/ps) if loaded, else the native trained window (/api/show). The *estimate* context
    // for an unloaded model is capped at the engine's *effective* context — Ollama loads at
    // OLLAMA_CONTEXT_LENGTH (or a request's num_ctx), not the full native window. `effectiveContext`
    // is inferred from what other models are currently loaded at (see discover); it falls back to the
    // engine default when nothing is resident. The full native 128K would over-estimate; a stale 4K
    // under-estimates when the user raised OLLAMA_CONTEXT_LENGTH (e.g. to 64K). Capped at native so it
    // never exceeds the model's own ceiling. KV uses /api/show's per-token cost when known, else generic.
    static func estimate(weightsBytes: Int?, loaded: Bool, loadedContext: Int?, nativeContext: Int?,
                         archKVPerToken: Int?, effectiveContext: Int? = nil) -> (context: Int?, estimate: Int?) {
        let display = loadedContext ?? nativeContext
        let cap = effectiveContext ?? MemoryEstimate.defaultContextWindow
        let estimateContext = loaded ? display : display.map { min($0, cap) }
        let kv = archKVPerToken ?? MemoryEstimate.genericKVBytesPerToken(weightsBytes: weightsBytes)
        return (display, MemoryEstimate.total(weightsBytes: weightsBytes, kvBytesPerToken: kv, context: estimateContext))
    }

    // Pure: /api/tags (names + size) merged with /api/ps (loaded set + context_length). The estimate
    // here is the weights-only baseline; discover() refines it with KV once /api/show arch is known.
    static func parse(tags: Data, ps: Data?) -> [ModelInfo] {
        struct Tags: Decodable { struct M: Decodable { let name: String; let size: Double? }; let models: [M] }
        struct PS: Decodable { struct M: Decodable { let name: String; let context_length: Int? }; let models: [M] }
        guard let t = try? JSONDecoder().decode(Tags.self, from: tags) else { return [] }
        var loaded = Set<String>()
        var ctx: [String: Int] = [:]
        if let ps, let v = try? JSONDecoder().decode(PS.self, from: ps) {
            for m in v.models { loaded.insert(m.name); if let c = m.context_length { ctx[m.name] = c } }
        }
        return t.models
            .map { m -> ModelInfo in
                let weights = m.size.map { Int($0) }
                return ModelInfo(id: m.name, loaded: loaded.contains(m.name), sizeBytes: weights,
                                 contextLength: ctx[m.name],
                                 estimatedSizeBytes: MemoryEstimate.total(weightsBytes: weights, kvBytes: nil))
            }
            .sorted { $0.id < $1.id }
    }
}
