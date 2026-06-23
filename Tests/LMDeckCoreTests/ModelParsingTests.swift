import Testing
import Foundation
@testable import LMDeckCore

struct ModelParsingTests {

    @Test func parseOllamaMergesLoadedSizeContext() throws {
        let tags = Data(#"{"models":[{"name":"qwen2.5:7b","size":4831838208},{"name":"llama3:latest","size":null}]}"#.utf8)
        let ps = Data(#"{"models":[{"name":"qwen2.5:7b","context_length":8192}]}"#.utf8)
        let models = OllamaEngine.parse(tags: tags, ps: ps)

        #expect(models.map(\.id) == ["llama3:latest", "qwen2.5:7b"])  // sorted by id

        let qwen = try #require(models.first { $0.id == "qwen2.5:7b" })
        #expect(qwen.loaded)
        #expect(qwen.sizeBytes == 4831838208)
        #expect(qwen.contextLength == 8192)
        // parse() gives the weights-only baseline; discover() refines it with KV from /api/show.
        #expect(qwen.estimatedSizeBytes == MemoryEstimate.total(weightsBytes: 4831838208, kvBytes: nil))

        let llama = try #require(models.first { $0.id == "llama3:latest" })
        #expect(!llama.loaded)
        #expect(llama.sizeBytes == nil)
        #expect(llama.estimatedSizeBytes == nil)
        #expect(llama.contextLength == nil)  // unloaded → no context from /api/ps
    }

    @Test func parseOllamaWithoutPS() {
        let tags = Data(#"{"models":[{"name":"a","size":1073741824}]}"#.utf8)
        let models = OllamaEngine.parse(tags: tags, ps: nil)
        #expect(models.count == 1)
        #expect(!models[0].loaded)
        #expect(models[0].contextLength == nil)
    }

    @Test func parseOllamaGarbageReturnsEmpty() {
        #expect(OllamaEngine.parse(tags: Data("nope".utf8), ps: nil).isEmpty)
    }

    @Test func ollamaEstimateCapsUnloadedContext() {
        let w = 5_000_000_000, native = 131072, kv = 131072   // ~5 GB, 128K native, 128 KB/token
        // Loaded → use the actual /api/ps context.
        let loaded = OllamaEngine.estimate(weightsBytes: w, loaded: true, loadedContext: 8192,
                                             nativeContext: native, archKVPerToken: kv)
        #expect(loaded.context == 8192)
        #expect(loaded.estimate == MemoryEstimate.total(weightsBytes: w, kvBytesPerToken: kv, context: 8192))
        // Unloaded → display the native max, but estimate KV only at the default window.
        let unloaded = OllamaEngine.estimate(weightsBytes: w, loaded: false, loadedContext: nil,
                                               nativeContext: native, archKVPerToken: kv)
        #expect(unloaded.context == native)
        #expect(unloaded.estimate == MemoryEstimate.total(weightsBytes: w, kvBytesPerToken: kv,
                                                          context: MemoryEstimate.defaultContextWindow))
        // …far smaller than counting the full native window (the old over-estimate).
        #expect(unloaded.estimate! < MemoryEstimate.total(weightsBytes: w, kvBytesPerToken: kv, context: native)!)
    }

    @Test func ollamaEstimateUsesEffectiveContextWhenResident() {
        let w = 5_000_000_000, native = 131072, kv = 131072
        // Nothing resident (effectiveContext nil) → estimate an unloaded model at the 4K default cap.
        let dflt = OllamaEngine.estimate(weightsBytes: w, loaded: false, loadedContext: nil,
                                           nativeContext: native, archKVPerToken: kv)
        // Other models resident at 64K (OLLAMA_CONTEXT_LENGTH) → use 64K instead: bigger, accurate.
        let effective = OllamaEngine.estimate(weightsBytes: w, loaded: false, loadedContext: nil,
                                                nativeContext: native, archKVPerToken: kv, effectiveContext: 65536)
        #expect(effective.context == native)   // display still shows the native window
        #expect(effective.estimate == MemoryEstimate.total(weightsBytes: w, kvBytesPerToken: kv, context: 65536))
        #expect(effective.estimate! > dflt.estimate!)
        // …but never above the model's own native ceiling (min with native).
        let capped = OllamaEngine.estimate(weightsBytes: w, loaded: false, loadedContext: nil,
                                             nativeContext: 8192, archKVPerToken: kv, effectiveContext: 65536)
        #expect(capped.estimate == MemoryEstimate.total(weightsBytes: w, kvBytesPerToken: kv, context: 8192))
    }

    @Test func ollamaEstimateFallsBackToGenericKV() {
        let w = 4_400_000_000
        // No arch from /api/show → generic size-based KV term.
        let e = OllamaEngine.estimate(weightsBytes: w, loaded: true, loadedContext: 8192,
                                        nativeContext: 8192, archKVPerToken: nil)
        #expect(e.estimate == MemoryEstimate.total(weightsBytes: w,
                    kvBytesPerToken: MemoryEstimate.genericKVBytesPerToken(weightsBytes: w), context: 8192))
    }

    @Test func ollamaEstimateUnknownContextIsWeightsOnly() {
        // No context anywhere → weights + overhead (KV needs a context to apply).
        let e = OllamaEngine.estimate(weightsBytes: 1_000_000_000, loaded: false, loadedContext: nil,
                                        nativeContext: nil, archKVPerToken: 1000)
        #expect(e.context == nil)
        #expect(e.estimate == MemoryEstimate.total(weightsBytes: 1_000_000_000, kvBytes: nil))
    }

    @Test func parseOmlx() throws {
        let data = Data(#"{"models":[{"id":"m-b","loaded":true,"estimated_size":2147483648,"max_context_window":131072},{"id":"m-a","loaded":false,"estimated_size":null}]}"#.utf8)
        let models = OmlxEngine.parse(data)
        #expect(models.map(\.id) == ["m-a", "m-b"])

        let mb = try #require(models.first { $0.id == "m-b" })
        #expect(mb.loaded)
        #expect(mb.sizeBytes == 2147483648)
        #expect(mb.contextLength == 131072)
        #expect(mb.estimatedSizeBytes == 2147483648)   // oMLX: engine-reported estimate

        let ma = try #require(models.first { $0.id == "m-a" })
        #expect(ma.sizeBytes == nil)
        #expect(ma.estimatedSizeBytes == nil)
        #expect(ma.contextLength == nil)
    }

    @Test func parseOmlxGarbageReturnsEmpty() {
        #expect(OmlxEngine.parse(Data("{}".utf8)).isEmpty)
    }

    @Test func parseLmstudioModels() throws {
        let data = Data(#"{"models":[{"key":"qwen2.5-7b","size_bytes":4831838208,"max_context_length":32768,"loaded_instances":[{"id":"qwen2.5-7b:1"}]},{"key":"gemma-2b","size_bytes":1610612736,"loaded_instances":[]}]}"#.utf8)
        let models = LMStudioEngine.parse(data)
        #expect(models.map(\.id) == ["gemma-2b", "qwen2.5-7b"])  // sorted by key

        let q = try #require(models.first { $0.id == "qwen2.5-7b" })
        #expect(q.loaded)
        #expect(q.sizeBytes == 4831838208)
        #expect(q.contextLength == 32768)
        // weights + a generic KV term from size + context (no architecture over LM Studio's API).
        #expect(q.estimatedSizeBytes == MemoryEstimate.total(
            weightsBytes: 4831838208,
            kvBytesPerToken: MemoryEstimate.genericKVBytesPerToken(weightsBytes: 4831838208),
            context: 32768))

        let g = try #require(models.first { $0.id == "gemma-2b" })
        #expect(!g.loaded)
        #expect(g.contextLength == nil)
    }

    @Test func estimateContextCapsUnloadedNotLoaded() {
        // Loaded → the actual context; unloaded → capped at the default window; already-small stays;
        // nil stays nil. The cap is what stops a long-context *unloaded* model over-estimating KV.
        #expect(MemoryEstimate.estimateContext(loaded: true, context: 131072) == 131072)
        #expect(MemoryEstimate.estimateContext(loaded: false, context: 131072) == MemoryEstimate.defaultContextWindow)
        #expect(MemoryEstimate.estimateContext(loaded: false, context: 2048) == 2048)
        #expect(MemoryEstimate.estimateContext(loaded: false, context: nil) == nil)
    }

    @Test func lmstudioCapsUnloadedContextInEstimate() throws {
        // An *unloaded* model with a large advertised max → KV charged at the 4K cap, not 128K, so a
        // model that would fit isn't wrongly marked too big. (Regression: functional-review #1.)
        let data = Data(#"{"models":[{"key":"big","size_bytes":5000000000,"max_context_length":131072,"loaded_instances":[]}]}"#.utf8)
        let m = try #require(LMStudioEngine.parse(data).first)
        #expect(!m.loaded)
        #expect(m.contextLength == 131072)   // display still shows the advertised max
        #expect(m.estimatedSizeBytes == MemoryEstimate.total(
            weightsBytes: 5000000000,
            kvBytesPerToken: MemoryEstimate.genericKVBytesPerToken(weightsBytes: 5000000000),
            context: MemoryEstimate.defaultContextWindow))   // …but KV is charged at the cap, not 131072
    }

    @Test func parseLmstudioGarbageReturnsEmpty() {
        #expect(LMStudioEngine.parse(Data(#"{"error":"unknown path"}"#.utf8)).isEmpty)
    }

    @Test func lmstudioInstanceIDsForKey() {
        let data = Data(#"{"models":[{"key":"m","loaded_instances":[{"id":"m:1"},{"id":"m:2"}]},{"key":"other","loaded_instances":[{"id":"other:1"}]}]}"#.utf8)
        #expect(LMStudioEngine.instanceIDs(in: data, forKey: "m") == ["m:1", "m:2"])
        #expect(LMStudioEngine.instanceIDs(in: data, forKey: "nope").isEmpty)
    }

    @Test func parseLlamaSwapModels() throws {
        let data = Data(#"{"object":"list","data":[{"id":"b","context_length":4096},{"id":"a"}]}"#.utf8)
        let parsed = LlamaSwapEngine.parseModels(data)
        #expect(parsed.map(\.id) == ["b", "a"])   // input order (discover sorts)
        #expect(try #require(parsed.first { $0.id == "b" }).context == 4096)
        #expect(try #require(parsed.first { $0.id == "a" }).context == nil)
        #expect(LlamaSwapEngine.parseModels(Data("nope".utf8)).isEmpty)
    }

    @Test func parseLlamaSwapRunning() {
        // Only "ready" counts as loaded — "starting"/"stopping" aren't resident; missing state = ready.
        let data = Data(#"{"running":[{"model":"m1","cmd":"llama-server -m /models/m1.gguf --port 9000","state":"ready"},{"model":"m2","cmd":"","state":"starting"},{"model":"m3","cmd":"x"}]}"#.utf8)
        let r = LlamaSwapEngine.parseRunning(data)
        #expect(Set(r.keys) == ["m1", "m3"])   // m2 (starting) excluded; m3 (no state) treated as ready
        #expect(r["m1"]?.contains("/models/m1.gguf") == true)
    }

    @Test func llamaSwapModelPathFromCmd() {
        #expect(LlamaSwapEngine.modelPath(fromCmd: "llama-server -m /models/x.gguf --port 9000") == "/models/x.gguf")
        #expect(LlamaSwapEngine.modelPath(fromCmd: "srv --model /models/y.gguf") == "/models/y.gguf")
        #expect(LlamaSwapEngine.modelPath(fromCmd: "srv -m \"/models/z.gguf\"") == "/models/z.gguf")
        // llama-swap puts args on separate lines:
        #expect(LlamaSwapEngine.modelPath(fromCmd: "llama-server --port 5810\n\n--model /b/sha256-abc\n-c 8192\n") == "/b/sha256-abc")
        #expect(LlamaSwapEngine.modelPath(fromCmd: "srv --no-model-here") == nil)
    }

    @Test func ollamaContextFromShow() {
        let data = Data(#"{"model_info":{"general.architecture":"qwen2","qwen2.context_length":32768,"qwen2.embedding_length":3584}}"#.utf8)
        #expect(OllamaEngine.contextFromShow(data) == 32768)
        #expect(OllamaEngine.contextFromShow(Data("{}".utf8)) == nil)
    }

    @Test func ollamaKvPerTokenFromShow() {
        // Llama-3-8B arch → 2 × 32 × 8 × (4096/32) × 2 bytes = 131072 B/token.
        let data = Data(#"{"model_info":{"general.architecture":"llama","llama.block_count":32,"llama.attention.head_count":32,"llama.attention.head_count_kv":8,"llama.embedding_length":4096}}"#.utf8)
        #expect(OllamaEngine.kvPerTokenFromShow(data) == 131072)
        #expect(OllamaEngine.kvPerTokenFromShow(Data("{}".utf8)) == nil)
        // Has arch but missing head counts → nil.
        #expect(OllamaEngine.kvPerTokenFromShow(Data(#"{"model_info":{"general.architecture":"llama","llama.block_count":32}}"#.utf8)) == nil)
        // Multimodal: read the primary architecture's block, not the vision tower's (clip.* here).
        let mm = Data(#"{"model_info":{"general.architecture":"llama","clip.block_count":2,"clip.attention.head_count":4,"clip.attention.head_count_kv":4,"clip.embedding_length":16,"llama.block_count":32,"llama.attention.head_count":32,"llama.attention.head_count_kv":8,"llama.embedding_length":4096}}"#.utf8)
        #expect(OllamaEngine.kvPerTokenFromShow(mm) == 131072)
    }

    @Test func engineErrorMessage() {
        #expect(ModelEngine.errorMessage(status: 500, body: Data(#"{"error":{"message":"boom"}}"#.utf8)) == "boom")
        #expect(ModelEngine.errorMessage(status: 400, body: Data(#"{"error":"bad"}"#.utf8)) == "bad")
        #expect(ModelEngine.errorMessage(status: 404, body: Data(#"{"message":"missing"}"#.utf8)) == "missing")
        #expect(ModelEngine.errorMessage(status: 502, body: Data("plain text".utf8)) == "HTTP 502: plain text")
        #expect(ModelEngine.errorMessage(status: 503, body: Data()) == "HTTP 503")
    }
}
