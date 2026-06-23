import Foundation

// llama-swap loads on-demand and self-manages (idle TTL). We make it controllable:
//  • load  = route a tiny request to the model so llama-swap starts its process,
//  • unload = its per-model stop endpoint (/api/models/unload/{model}),
//  • loaded state = /running.
// /v1/models exposes no size; /running's launch `cmd` carries the model path (`-m`/`--model`),
// so we stat that file for size — available only for *running* models on this machine.
final class LlamaSwapEngine: ModelEngine {
    override var canControl: Bool { true }
    override var probePath: String { "v1/models" }

    // Auto-config: llama-swap's listen port is a launch arg (`--listen`), read from the process table;
    // its keys live in the config YAML's `apiKeys:` list (not a CLI flag), so read the first literal
    // one from the `--config` file.
    static func detectConfig() -> DetectedEngineConfig {
        var c = DetectedEngineConfig()
        guard let args = EngineConfigReader.processArgs(execContains: "llama-swap") else { return c }
        if let listen = EngineConfigReader.value(after: "--listen", in: args) {
            c.port = EngineConfigReader.port(fromListen: listen)
        }
        if let configPath = EngineConfigReader.value(after: "--config", in: args) {
            c.apiKey = EngineConfigReader.firstYAMLListItem(under: "apiKeys", inFileAt: configPath)
        }
        return c
    }

    override func discover() async -> EngineState? {
        guard let list = try? await get("v1/models") else { return nil }
        let parsed = Self.parseModels(list)   // [(id, context)]

        var loaded = Set<String>()
        var sizes: [String: Int] = [:]
        if let runData = try? await get("running") {
            let running = Self.parseRunning(runData)   // modelID -> launch cmd
            loaded = Set(running.keys)
            for (id, cmd) in running {
                if let path = Self.modelPath(fromCmd: cmd),
                   let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let bytes = (attrs[.size] as? NSNumber)?.int64Value {
                    sizes[id] = Int(bytes)
                }
            }
        }

        let models = parsed
            .map { p -> ModelInfo in
                // Size only known while running (GGUF stat); no architecture → weights + a generic KV
                // term from context_length + model size. An unloaded model's KV context is capped at
                // the engine default (it isn't running at the full advertised window) to avoid the
                // long-context over-estimate that greys out the Load button / triggers spurious 503s.
                let bytes = sizes[p.id]
                let isLoaded = loaded.contains(p.id)
                return ModelInfo(id: p.id, loaded: isLoaded, sizeBytes: bytes,
                                 contextLength: p.context,
                                 estimatedSizeBytes: MemoryEstimate.total(
                                     weightsBytes: bytes,
                                     kvBytesPerToken: MemoryEstimate.genericKVBytesPerToken(weightsBytes: bytes),
                                     context: MemoryEstimate.estimateContext(loaded: isLoaded, context: p.context)))
            }
            .sorted { $0.id < $1.id }
        return state(models)
    }

    // Load: a tiny request makes llama-swap start the model's process to serve it.
    override func load(_ id: String) async -> String? {
        await firePOST(path: "v1/chat/completions",
                       json: ["model": id,
                              "messages": [["role": "user", "content": "."]],
                              "max_tokens": 1, "stream": false],
                       timeout: Self.loadTimeout)
    }

    // Unload: llama-swap's per-model stop endpoint.
    override func unload(_ id: String) async -> String? {
        let p = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let url = URL(string: "\(base.absoluteString)/api/models/unload/\(p)") else { return nil }
        return await firePOST(url)
    }

    // MARK: pure parsing (unit-tested — no I/O)

    // /v1/models → [(id, context)]; context_length is present when set in the model's caps config.
    static func parseModels(_ data: Data) -> [(id: String, context: Int?)] {
        struct List: Decodable { struct M: Decodable { let id: String; let context_length: Int? }; let data: [M] }
        guard let l = try? JSONDecoder().decode(List.self, from: data) else { return [] }
        return l.data.map { ($0.id, $0.context_length) }
    }

    // /running → [modelID: launch cmd]. Only *ready* processes count as loaded — a "starting" or
    // "stopping" entry isn't resident yet, so including it would show a green dot and make it an
    // eviction candidate prematurely. A missing state is treated as ready (older llama-swap).
    static func parseRunning(_ data: Data) -> [String: String] {
        struct Running: Decodable {
            struct R: Decodable { let model: String; let cmd: String?; let state: String? }
            let running: [R]
        }
        guard let r = try? JSONDecoder().decode(Running.self, from: data) else { return [:] }
        var out: [String: String] = [:]
        for item in r.running where item.state == nil || item.state == "ready" {
            out[item.model] = item.cmd ?? ""
        }
        return out
    }

    // The `-m`/`--model` argument in a launch command (surrounding quotes stripped), or nil.
    // Splits on any whitespace — llama-swap cmds put args on separate lines. Paths containing
    // spaces aren't handled.
    static func modelPath(fromCmd cmd: String) -> String? {
        let toks = cmd.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (i, t) in toks.enumerated() where (t == "-m" || t == "--model") && i + 1 < toks.count {
            return toks[i + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }
}
