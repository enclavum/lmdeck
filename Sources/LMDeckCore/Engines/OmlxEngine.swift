import Foundation

// oMLX: list/size/loaded/context via /v1/models/status; load/unload via /v1/models/{id}/{load,unload}.
final class OmlxEngine: ModelEngine {
    override var canControl: Bool { true }
    override var probePath: String { "v1/models/status" }

    // Auto-config: oMLX persists its server config (plaintext) in ~/.omlx/settings.json.
    static func detectConfig() -> DetectedEngineConfig {
        var c = DetectedEngineConfig()
        guard let json = EngineConfigReader.homeJSON(".omlx/settings.json") else { return c }
        c.port = (json["server"] as? [String: Any])?["port"] as? Int
        if let key = (json["auth"] as? [String: Any])?["api_key"] as? String, !key.isEmpty { c.apiKey = key }
        return c
    }

    override func discover() async -> EngineState? {
        guard let data = try? await get("v1/models/status") else { return nil }
        return state(Self.parse(data))
    }

    override func load(_ id: String) async -> String? { await control(id, "load", timeout: Self.loadTimeout) }
    override func unload(_ id: String) async -> String? { await control(id, "unload") }

    // POST /v1/models/{id}/{load|unload} — id path-encoded (like quote(safe='')).
    private func control(_ id: String, _ action: String, timeout: TimeInterval = 120) async -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        guard let url = URL(string: "\(base.absoluteString)/v1/models/\(encoded)/\(action)") else { return "Invalid model id." }
        return await firePOST(url, timeout: timeout)
    }

    static func parse(_ data: Data) -> [ModelInfo] {
        struct Status: Decodable { struct M: Decodable { let id: String; let loaded: Bool; let estimated_size: Double?; let max_context_window: Int? }; let models: [M] }
        guard let st = try? JSONDecoder().decode(Status.self, from: data) else { return [] }
        return st.models
            .map { m -> ModelInfo in
                // oMLX's estimated_size IS its own RAM/load estimate, so use it as both the size and
                // the footprint estimate (it has no per-context/arch breakdown over HTTP).
                let bytes = m.estimated_size.map { Int($0) }
                return ModelInfo(id: m.id, loaded: m.loaded, sizeBytes: bytes,
                                 contextLength: m.max_context_window, estimatedSizeBytes: bytes)
            }
            .sorted { $0.id < $1.id }
    }
}
