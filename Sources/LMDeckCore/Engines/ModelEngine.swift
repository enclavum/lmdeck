import Foundation

// One model exposed by a engine.
struct ModelInfo: Identifiable {
    let id: String
    let loaded: Bool
    let sizeBytes: Int?       // on-disk size in bytes, when the engine reports it
    let contextLength: Int?   // max context window (tokens), when the engine reports it
    // Best-effort predicted RAM footprint at `contextLength` (weights + KV + overhead). KV is
    // included only where the engine exposes architecture (Ollama); see MemoryEstimate.
    let estimatedSizeBytes: Int?
}

enum EngineKind: CaseIterable, Sendable {
    case ollama, omlx, lmstudio, llamaswap

    // Lowercase routing token — the `engine` value and the prefix of a qualified id `token/model`.
    var token: String {
        switch self {
        case .ollama: return "ollama"
        case .omlx: return "omlx"
        case .lmstudio: return "lmstudio"
        case .llamaswap: return "llamaswap"
        }
    }

    // Routing priority for bare-id collisions: lower wins (ollama > omlx > lmstudio > llamaswap).
    var priority: Int {
        switch self {
        case .ollama: return 0
        case .omlx: return 1
        case .lmstudio: return 2
        case .llamaswap: return 3
        }
    }

    static func from(token: String) -> EngineKind? { allCases.first { $0.token == token } }

    // Per-engine enable/disable (UserDefaults; first-run auto-detect seeds it). The single gate that
    // discovery, routing, the catalog, and load/unload honour — via EngineRegistry.
    var enabledKey: String { "\(token)Enabled" }
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    // UserDefaults key for this engine's endpoint port (matches SettingsKeys.<token>Port).
    var portKey: String { "\(token)Port" }
}

// Per-engine reachability — distinct from "has models". Used by the Engines pane status + the
// first-run auto-detect: the port answered (ok), answered but rejected our key (unauthorized → key
// error), or didn't answer at all (unreachable).
public enum EngineStatus: Equatable { case ok, unauthorized, unreachable }

// A engine's discovered state (one card in the Models pane).
struct EngineState: Identifiable {
    var id: String { name }
    let name: String
    let kind: EngineKind
    let canControl: Bool
    let models: [ModelInfo]
}

// Base class for a backend engine client. Subclasses override discovery + load/unload;
// the base supplies the shared HTTP plumbing and the "unsupported" defaults (so a engine
// that only lists models just works). Pure response parsing lives in each subclass as a
// `static func parse(...)` and is unit-tested.
class ModelEngine {
    let kind: EngineKind
    let displayName: String
    let base: URL
    let key: String

    init(kind: EngineKind, displayName: String, base: URL, key: String) {
        self.kind = kind
        self.displayName = displayName
        self.base = base
        self.key = key
    }

    // Can the UI load/unload this engine's models? Overridden to true where supported.
    var canControl: Bool { false }

    // Discover models (list + size + loaded state). Returns nil when unreachable.
    func discover() async -> EngineState? { nil }

    // The path the reachability probe hits (a cheap GET). Overridden per engine.
    var probePath: String { "" }

    // Reachability + auth: any HTTP response → .ok except 401/403 → .unauthorized (the key was
    // rejected); no HTTP response (refused / timed out) → .unreachable.
    func probe() async -> EngineStatus {
        var req = URLRequest(url: base.appending(path: probePath))
        req.timeoutInterval = 3
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return .unreachable }
        return (http.statusCode == 401 || http.statusCode == 403) ? .unauthorized : .ok
    }

    // Load / unload a model — returns an error message on failure, nil on success.
    // No-ops (success) in the base for uncontrollable engines.
    func load(_ modelID: String) async -> String? { nil }
    func unload(_ modelID: String) async -> String? { nil }

    // Wrap parsed models into a EngineState (carries name/kind/canControl).
    func state(_ models: [ModelInfo]) -> EngineState {
        EngineState(name: displayName, kind: kind, canControl: canControl, models: models)
    }

    // MARK: shared HTTP

    // Model loads can be slow (a cold load of a large model off slow disk), so they use a generous
    // timeout rather than the default POST 120 s — a slow-but-succeeding load mustn't read as a failure.
    static let loadTimeout: TimeInterval = 600

    // GET base+path; returns the body on 2xx (throws otherwise). Sends the engine key.
    func get(_ path: String, timeout: TimeInterval = 3) async throws -> Data {
        var req = URLRequest(url: base.appending(path: path))
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData   // engine state (e.g. Ollama /api/ps) must be fresh
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // POST (load/unload). Returns nil on 2xx, else a human error message (parsed from the body).
    @discardableResult
    func firePOST(_ url: URL, json: [String: Any]? = nil, timeout: TimeInterval = 120) async -> String? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        req.timeoutInterval = timeout
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return "Unexpected non-HTTP response." }
            return (200..<300).contains(http.statusCode) ? nil : Self.errorMessage(status: http.statusCode, body: data)
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func firePOST(path: String, json: [String: Any]? = nil, timeout: TimeInterval = 120) async -> String? {
        await firePOST(base.appending(path: path), json: json, timeout: timeout)
    }

    // POST returning the body on 2xx (for read endpoints like Ollama's /api/show), nil otherwise.
    func postForData(path: String, json: [String: Any], timeout: TimeInterval = 5) async -> Data? {
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = "POST"
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        req.timeoutInterval = timeout
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    // Pure: a human-readable message from an error response body (OpenAI-style or raw text).
    static func errorMessage(status: Int, body: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let e = obj["error"] as? [String: Any], let m = e["message"] as? String, !m.isEmpty { return m }
            if let m = obj["error"] as? String, !m.isEmpty { return m }
            if let m = obj["message"] as? String, !m.isEmpty { return m }
        }
        let s = (String(data: body, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(String(s.prefix(200)))"
    }
}

// Builds the live engine clients from current settings (rebuilt on each call so port/key edits
// take effect immediately). The fixed array order is the routing priority. Shared by ModelStore
// (the UI) and the proxy (discovery, /v1 + /api/v1 model lists, and request routing).
enum EngineRegistry {
    struct Config { let kind: EngineKind; let displayName: String; let base: URL; let key: String }

    // All four engines' connection settings (read live from UserDefaults / Keychain), unfiltered.
    static func allConfigs() -> [Config] {
        func cfg(_ kind: EngineKind, _ name: String, _ portKey: String, _ defPort: Int, _ keyKey: String) -> Config {
            let port = Net.port(UserDefaults.standard.integer(forKey: portKey), default: defPort)
            let base = URL(string: "http://localhost:\(port)")!   // always valid: loopback + integer port
            let key = SecretStore.shared.get(keyKey).trimmingCharacters(in: .whitespaces)
            return Config(kind: kind, displayName: name, base: base, key: key)
        }
        return [
            cfg(.ollama,    "Ollama",     SettingsKeys.ollamaPort,    11434, SettingsKeys.ollamaKey),
            cfg(.omlx,      "oMLX",       SettingsKeys.omlxPort,      8000,  SettingsKeys.omlxKey),
            cfg(.lmstudio,  "LM Studio",  SettingsKeys.lmstudioPort,  1234,  SettingsKeys.lmstudioKey),
            cfg(.llamaswap, "llama-swap", SettingsKeys.llamaswapPort, 8080,  SettingsKeys.llamaswapKey),
        ]
    }

    // Only the user-enabled engines — the set discovery, routing, the catalog, and load/unload use.
    static func configs() -> [Config] { allConfigs().filter { $0.kind.isEnabled } }

    static func live() -> [ModelEngine] { configs().map(client) }

    // Every engine client regardless of enabled state — for the first-run reachability probe.
    static func allClients() -> [ModelEngine] { allConfigs().map(client) }

    private static func client(_ c: Config) -> ModelEngine {
        switch c.kind {
        case .ollama:    return OllamaEngine(kind: c.kind, displayName: c.displayName, base: c.base, key: c.key)
        case .omlx:      return OmlxEngine(kind: c.kind, displayName: c.displayName, base: c.base, key: c.key)
        case .lmstudio:  return LMStudioEngine(kind: c.kind, displayName: c.displayName, base: c.base, key: c.key)
        case .llamaswap: return LlamaSwapEngine(kind: c.kind, displayName: c.displayName, base: c.base, key: c.key)
        }
    }
}
