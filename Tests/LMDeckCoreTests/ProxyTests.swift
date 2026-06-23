import Testing
import Foundation
@testable import LMDeckCore

struct ProxyTests {

    // Sample discovery: Cydonia only in oMLX (single engine); llama3:latest in both Ollama and
    // llama-swap (collision). Deliberately out of priority order to prove the serializers sort.
    private func sampleStates() -> [EngineState] {
        [
            EngineState(name: "oMLX", kind: .omlx, canControl: true, models: [
                ModelInfo(id: "Cydonia-24B-v4.3-mlx-8Bit", loaded: false, sizeBytes: 26298482076, contextLength: 131072, estimatedSizeBytes: 26298482076),
            ]),
            EngineState(name: "Ollama", kind: .ollama, canControl: true, models: [
                ModelInfo(id: "llama3:latest", loaded: true, sizeBytes: 4661224676, contextLength: 8192, estimatedSizeBytes: 6_270_000_000),
            ]),
            EngineState(name: "llama-swap", kind: .llamaswap, canControl: true, models: [
                ModelInfo(id: "llama3:latest", loaded: false, sizeBytes: nil, contextLength: nil, estimatedSizeBytes: nil),
            ]),
        ]
    }

    private func decodeArray(_ data: Data, _ key: String) throws -> [[String: Any]] {
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(obj[key] as? [[String: Any]])
    }

    // MARK: GET /v1/models (OpenAI-compatible endpoint)

    @Test func openAIModelsListsQualifiedRowsOwnedByEngine() throws {
        let data = Proxy.openAIModelsJSON(sampleStates(), now: 1000)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["object"] as? String == "list")
        let rows = try #require(obj["data"] as? [[String: Any]])

        // One row per (engine, model); ordered by engine priority, then model id.
        #expect(rows.compactMap { $0["id"] as? String } ==
                ["ollama/llama3:latest", "omlx/Cydonia-24B-v4.3-mlx-8Bit", "llamaswap/llama3:latest"])
        for r in rows { #expect(r["object"] as? String == "model"); #expect(r["created"] as? Int == 1000) }
        #expect(rows.first?["owned_by"] as? String == "ollama")
        #expect(rows.last?["owned_by"] as? String == "llamaswap")
        // No bare names are listed — only qualified ids.
        #expect(!rows.contains { ($0["id"] as? String) == "llama3:latest" })
    }

    @Test func openAIModelsEmpty() throws {
        let rows = try decodeArray(Proxy.openAIModelsJSON([], now: 0), "data")
        #expect(rows.isEmpty)
    }

    // MARK: GET /api/v1/models (native rich endpoint)

    @Test func nativeCatalogHasRichFieldsAndNullsForUnknown() throws {
        let huge = 1_000_000_000_000   // 1 TB free → everything is loadable
        let rows = try decodeArray(Proxy.nativeCatalogJSON(sampleStates(), availableBytes: huge), "models")
        #expect(rows.count == 3)

        let cyd = try #require(rows.first { $0["id"] as? String == "omlx/Cydonia-24B-v4.3-mlx-8Bit" })
        #expect(cyd["model"] as? String == "Cydonia-24B-v4.3-mlx-8Bit")
        #expect(cyd["engine"] as? String == "omlx")
        #expect(cyd["loaded"] as? Bool == false)
        #expect(cyd["size"] as? Int == 26298482076)
        #expect(cyd["context_length"] as? Int == 131072)
        #expect(cyd["estimated_size"] as? Int == 26298482076)
        #expect(cyd["can_load"] as? Bool == true)

        let ol = try #require(rows.first { $0["id"] as? String == "ollama/llama3:latest" })
        #expect(ol["engine"] as? String == "ollama")
        #expect(ol["loaded"] as? Bool == true)
        #expect(ol["size"] as? Int == 4661224676)
        #expect(ol["estimated_size"] as? Int == 6_270_000_000)

        // Unknown size/context/estimate are emitted as JSON null (present, not omitted).
        let ls = try #require(rows.first { $0["id"] as? String == "llamaswap/llama3:latest" })
        #expect(ls["model"] as? String == "llama3:latest")
        #expect(ls["loaded"] as? Bool == false)
        #expect(ls["size"] is NSNull)
        #expect(ls["context_length"] is NSNull)
        #expect(ls["estimated_size"] is NSNull)
    }

    @Test func nativeCatalogCanLoadReflectsMemory() throws {
        // Only ~10 GB free: the 26 GB Cydonia can't load; the loaded ollama row is trivially true;
        // the llama-swap row (unknown estimate) is treated as loadable.
        let rows = try decodeArray(Proxy.nativeCatalogJSON(sampleStates(), availableBytes: 10_000_000_000), "models")
        #expect((rows.first { $0["id"] as? String == "omlx/Cydonia-24B-v4.3-mlx-8Bit" })?["can_load"] as? Bool == false)
        #expect((rows.first { $0["id"] as? String == "ollama/llama3:latest" })?["can_load"] as? Bool == true)
        #expect((rows.first { $0["id"] as? String == "llamaswap/llama3:latest" })?["can_load"] as? Bool == true)
    }

    @Test func nativeCatalogEmpty() throws {
        let rows = try decodeArray(Proxy.nativeCatalogJSON([], availableBytes: 0), "models")
        #expect(rows.isEmpty)
    }

    // MARK: parity — both endpoints expose the same rows with the same ids

    @Test func bothEndpointsHaveSameIdsInSameOrder() throws {
        let states = sampleStates()
        let openAI = try decodeArray(Proxy.openAIModelsJSON(states, now: 0), "data").compactMap { $0["id"] as? String }
        let native = try decodeArray(Proxy.nativeCatalogJSON(states, availableBytes: 0), "models").compactMap { $0["id"] as? String }
        #expect(openAI == native)
        #expect(openAI.count == 3)
    }

    // MARK: routing index + resolution

    @Test func buildIndexGroupsAndSortsByPriority() {
        let index = Proxy.buildIndex([
            (kind: .llamaswap, models: ["b", "shared"]),
            (kind: .ollama,    models: ["a", "shared"]),
            (kind: .omlx,      models: ["shared"]),
        ])
        #expect(index["a"] == [.ollama])
        #expect(index["b"] == [.llamaswap])
        #expect(index["shared"] == [.ollama, .omlx, .llamaswap])   // priority order
        #expect(index["nope"] == nil)
    }

    @Test func resolveBareQualifiedAndMisses() {
        let index = Proxy.buildIndex([
            (kind: .ollama,    models: ["llama3:latest", "huggingface.co/x/y:Q6_K"]),
            (kind: .omlx,      models: ["Cydonia"]),
            (kind: .llamaswap, models: ["llama3:latest", "huggingface.co/x/y:Q6_K"]),
        ])
        func r(_ s: String) -> (kind: EngineKind, model: String)? { Proxy.resolve(s, index: index) }

        // bare collision → highest priority
        #expect(r("llama3:latest")?.kind == .ollama)
        #expect(r("llama3:latest")?.model == "llama3:latest")
        // qualified → exact engine, engine-local model name
        #expect(r("llamaswap/llama3:latest")?.kind == .llamaswap)
        #expect(r("llamaswap/llama3:latest")?.model == "llama3:latest")
        #expect(r("ollama/llama3:latest")?.kind == .ollama)
        // single engine, bare
        #expect(r("Cydonia")?.kind == .omlx)
        #expect(r("omlx/Cydonia")?.kind == .omlx)
        // explicit engine that doesn't have it → nil
        #expect(r("omlx/llama3:latest") == nil)
        #expect(r("lmstudio/llama3:latest") == nil)
        // HF-style bare id (slashes, non-engine prefix) → bare lookup by priority
        #expect(r("huggingface.co/x/y:Q6_K")?.kind == .ollama)
        // HF-style qualified id → exact engine, prefix stripped
        #expect(r("llamaswap/huggingface.co/x/y:Q6_K")?.kind == .llamaswap)
        #expect(r("llamaswap/huggingface.co/x/y:Q6_K")?.model == "huggingface.co/x/y:Q6_K")
        // unknown → nil
        #expect(r("nope") == nil)
    }

    // MARK: forward body rewrite

    @Test func bodyForUpstreamRewritesModelKeepingOtherFields() throws {
        let body = Data(#"{"model":"llamaswap/llama3:latest","messages":[{"role":"user","content":"hi"}],"temperature":0.1,"stream":true}"#.utf8)
        let obj = try #require(try JSONSerialization.jsonObject(with: Proxy.bodyForUpstream(body, model: "llama3:latest")) as? [String: Any])
        #expect(obj["model"] as? String == "llama3:latest")     // rewritten to engine-local name
        #expect(obj["temperature"] as? Double == 0.1)           // other fields preserved
        #expect(obj["stream"] as? Bool == true)
        #expect((obj["messages"] as? [[String: Any]])?.first?["content"] as? String == "hi")
    }

    @Test func bodyForUpstreamNonJSONReturnsOriginal() {
        let body = Data("not json".utf8)
        #expect(Proxy.bodyForUpstream(body, model: "x") == body)
    }

    @Test func bodyForUpstreamNonObjectJSONReturnsOriginal() {
        let arr = Data("[1,2,3]".utf8)          // valid JSON, but not a top-level object
        #expect(Proxy.bodyForUpstream(arr, model: "x") == arr)
    }

    // MARK: streaming back-pressure

    @Test func flowControlSuspendsAndResumesAtWatermarks() {
        var suspends = 0, resumes = 0
        let flow = FlowControl(high: 100, low: 20)
        flow.bind(onSuspend: { suspends += 1 }, onResume: { resumes += 1 })
        flow.produced(50);  #expect(suspends == 0)   // below high
        flow.produced(60);  #expect(suspends == 1)   // 110 ≥ 100 → suspend
        flow.produced(30);  #expect(suspends == 1)   // already suspended → no double
        flow.consumed(100); #expect(resumes == 0)    // 40 still > low
        flow.consumed(30);  #expect(resumes == 1)    // 10 ≤ 20 → resume
        flow.consumed(5);   #expect(resumes == 1)    // not suspended → no double
    }

    // MARK: EngineKind

    @Test func engineKindTokenPriorityAndLookup() {
        #expect(EngineKind.ollama.token == "ollama")
        #expect(EngineKind.omlx.token == "omlx")
        #expect(EngineKind.lmstudio.token == "lmstudio")
        #expect(EngineKind.llamaswap.token == "llamaswap")
        #expect(EngineKind.ollama.priority < EngineKind.omlx.priority)
        #expect(EngineKind.omlx.priority < EngineKind.lmstudio.priority)
        #expect(EngineKind.lmstudio.priority < EngineKind.llamaswap.priority)
        #expect(EngineKind.from(token: "llamaswap") == .llamaswap)
        #expect(EngineKind.from(token: "nope") == nil)
    }

    // MARK: auth

    @Test func isAuthorized() {
        #expect(Proxy.isAuthorized("Bearer k", key: "k"))
        #expect(!Proxy.isAuthorized("Bearer wrong", key: "k"))
        #expect(!Proxy.isAuthorized(nil, key: "k"))
        #expect(Proxy.isAuthorized(nil, key: ""))        // open endpoint
        #expect(Proxy.isAuthorized("anything", key: ""))
    }

    @Test func constantTimeEqual() {
        #expect(Proxy.constantTimeEqual("Bearer k", "Bearer k"))
        #expect(!Proxy.constantTimeEqual("Bearer k", "Bearer x"))
        #expect(!Proxy.constantTimeEqual("Bearer k", "Bearer kk"))   // differing lengths
        #expect(Proxy.constantTimeEqual("", ""))
    }

    // MARK: admin gate + not-found sniffing

    @Test func adminAllowedGatesNetworkExposedNoKey() {
        #expect(Proxy.adminAllowed(host: "127.0.0.1", key: ""))      // loopback, no key → local-only, fine
        #expect(Proxy.adminAllowed(host: "localhost", key: ""))      // loopback alias
        #expect(Proxy.adminAllowed(host: "127.0.0.1", key: "k"))
        #expect(!Proxy.adminAllowed(host: "0.0.0.0", key: ""))       // wildcard + no key → blocked
        #expect(!Proxy.adminAllowed(host: "192.168.1.50", key: "")) // routable IP + no key → blocked too
        #expect(Proxy.adminAllowed(host: "0.0.0.0", key: "k"))       // network + key → authed, fine
    }

    // The proxy chat path evicts only when auto-evict is on AND the caller may admin (loopback or
    // keyed). An anonymous network peer (exposed + no key) must refuse, never evict — even with
    // auto-evict on — so it can't unload your models from the LAN.
    @Test func admissionPolicyGatesEvictionLikeAdmin() {
        // auto-evict OFF → always refuse, regardless of caller.
        #expect(Proxy.admissionPolicy(autoEvict: false, host: "127.0.0.1", key: "") == .refuseIfFull)
        #expect(Proxy.admissionPolicy(autoEvict: false, host: "0.0.0.0", key: "k") == .refuseIfFull)

        // auto-evict ON → evict only when the caller is loopback or authenticated.
        #expect(Proxy.admissionPolicy(autoEvict: true, host: "127.0.0.1", key: "") == .evictToFit)  // loopback
        #expect(Proxy.admissionPolicy(autoEvict: true, host: "localhost", key: "") == .evictToFit)  // loopback alias
        #expect(Proxy.admissionPolicy(autoEvict: true, host: "0.0.0.0", key: "k") == .evictToFit)   // exposed + key → authed
        #expect(Proxy.admissionPolicy(autoEvict: true, host: "192.168.1.50", key: "k") == .evictToFit)

        // The hardening case: auto-evict ON but exposed with no key → still refuse (no anonymous eviction).
        #expect(Proxy.admissionPolicy(autoEvict: true, host: "0.0.0.0", key: "") == .refuseIfFull)
        #expect(Proxy.admissionPolicy(autoEvict: true, host: "192.168.1.50", key: "") == .refuseIfFull)
    }

    @Test func isNotFoundMatchesCommonPhrasings() {
        #expect(Proxy.isNotFound("Model not found: MarkItDown"))
        #expect(Proxy.isNotFound("error: not_found"))
        #expect(Proxy.isNotFound("No such model: x"))
        #expect(!Proxy.isNotFound("connection refused"))
        #expect(!Proxy.isNotFound("HTTP 500: internal error"))
    }
}
