import Foundation

// LM Studio: list/size/loaded via /api/v1/models (id is `key`); load via /api/v1/models/load,
// unload via /api/v1/models/unload (per loaded instance).
final class LMStudioEngine: ModelEngine {
    override var canControl: Bool { true }
    override var probePath: String { "api/v1/models" }

    // Auto-config: LM Studio persists the server port in ~/.lmstudio/.internal/http-server-config.json.
    // The API token is stored only as a SHA-512 hash (permissions-store.json), so it isn't recoverable.
    static func detectConfig() -> DetectedEngineConfig {
        var c = DetectedEngineConfig()
        c.port = EngineConfigReader.homeJSON(".lmstudio/.internal/http-server-config.json")?["port"] as? Int
        return c
    }

    override func discover() async -> EngineState? {
        guard let data = try? await get("api/v1/models") else { return nil }
        return state(Self.parse(data))
    }

    // /load takes {model}; it's not idempotent (stacks instances), but toggle only loads when unloaded.
    override func load(_ modelKey: String) async -> String? {
        await firePOST(path: "api/v1/models/load", json: ["model": modelKey], timeout: Self.loadTimeout)
    }

    // /unload takes {instance_id}; sweep every loaded instance for the key.
    override func unload(_ modelKey: String) async -> String? {
        // Distinguish "couldn't look up instances" from "nothing to unload" — returning nil here
        // would falsely report success while the model stays resident.
        guard let data = try? await get("api/v1/models") else {
            return "Couldn't reach LM Studio to find instances to unload."
        }
        var lastErr: String?
        for inst in Self.instanceIDs(in: data, forKey: modelKey) {
            if let e = await firePOST(path: "api/v1/models/unload", json: ["instance_id": inst]) { lastErr = e }
        }
        return lastErr
    }

    static func parse(_ data: Data) -> [ModelInfo] {
        struct Resp: Decodable {
            struct M: Decodable {
                let key: String
                let size_bytes: Int?
                let max_context_length: Int?
                let loaded_instances: [Inst]?
                struct Inst: Decodable { let id: String? }
            }
            let models: [M]
        }
        guard let r = try? JSONDecoder().decode(Resp.self, from: data) else { return [] }
        return r.models
            .map { m -> ModelInfo in
                // No architecture over LM Studio's HTTP API → weights + a generic KV term from
                // context_length + model size (better than omitting KV, which under-counts the gate).
                // An unloaded model's KV context is capped — it loads at its configured window, not the
                // advertised `max_context_length` — else a long-context model's footprint balloons and
                // greys out the Load button / triggers spurious 503s for models that would actually fit.
                let loaded = !(m.loaded_instances ?? []).isEmpty
                return ModelInfo(id: m.key, loaded: loaded,
                          sizeBytes: m.size_bytes, contextLength: m.max_context_length,
                          estimatedSizeBytes: MemoryEstimate.total(
                              weightsBytes: m.size_bytes,
                              kvBytesPerToken: MemoryEstimate.genericKVBytesPerToken(weightsBytes: m.size_bytes),
                              context: MemoryEstimate.estimateContext(loaded: loaded, context: m.max_context_length)))
            }
            .sorted { $0.id < $1.id }
    }

    // Pure: instance ids to unload for a given model key.
    static func instanceIDs(in data: Data, forKey modelKey: String) -> [String] {
        struct Resp: Decodable {
            struct M: Decodable { let key: String; let loaded_instances: [Inst]?; struct Inst: Decodable { let id: String? } }
            let models: [M]
        }
        guard let r = try? JSONDecoder().decode(Resp.self, from: data) else { return [] }
        return r.models.first { $0.key == modelKey }?.loaded_instances?.compactMap { $0.id } ?? []
    }
}
