import Foundation

// Best-effort RAM-footprint estimation for a loaded model:
//
//   total ≈ (weights + KV cache) × (1 + overhead)
//
// `weights` is the on-disk/quantized size; the KV cache is the context-dependent term and needs
// the model's architecture (layers, KV heads, head dim) — available from Ollama's /api/show, but
// not over every engine's HTTP API. When the KV term can't be computed the estimate falls back to
// weights + overhead (a lower bound). The manager should add its own safety margin on top.
enum MemoryEstimate {
    // KV cache element precision (fp16). 8-bit KV-cache quantization would halve the KV term.
    static let kvBytesPerElementFP16 = 2
    // Rough allowance for compute/activation buffers + framework overhead.
    static let overheadFraction = 0.10

    // Context to assume for a model that isn't loaded yet. Engines (notably Ollama) load at a default
    // window, not the full trained context, unless asked — so counting KV at the native window (often
    // 128K) badly over-estimates an unloaded model. The estimate's context is capped at this.
    static let defaultContextWindow = 4096

    // Generic KV heuristic for engines that don't expose architecture (LM Studio, llama-swap): KV
    // cache bytes per token per ~billion parameters (fp16), calibrated to a typical GQA model
    // (Llama-3-8B ≈ 128 KiB/token at ~8B params → 16 KiB/token/B).
    static let genericKVBytesPerTokenPerBillion = 16 * 1024
    // Assumed quantized bytes/param (~Q4_K_M) used to recover a param count from on-disk weight size.
    static let assumedBytesPerParam = 0.56

    // KV cache bytes per token = 2 (K and V) × layers × n_kv_heads × head_dim × bytes/elem.
    static func kvBytesPerToken(layers: Int, kvHeads: Int, headDim: Int,
                                bytesPerElement: Int = kvBytesPerElementFP16) -> Int {
        2 * layers * kvHeads * headDim * bytesPerElement
    }

    // Generic per-token KV when architecture is unknown — scaled by model size (a param-count proxy
    // recovered from the on-disk weight size). A rough term, far better than omitting KV entirely;
    // nil when the weight size is unknown. Saturates instead of trapping on a garbage huge input.
    static func genericKVBytesPerToken(weightsBytes: Int?) -> Int? {
        guard let weightsBytes, weightsBytes > 0 else { return nil }
        let billions = Double(weightsBytes) / assumedBytesPerParam / 1_000_000_000
        let perToken = billions * Double(genericKVBytesPerTokenPerBillion)
        return perToken >= Double(Int.max) ? .max : Int(perToken.rounded())
    }

    // Predicted RAM from weights + an already-computed KV total. `kvBytes` nil → weights + overhead.
    // Computed in Double and saturated to avoid Int overflow on a garbage (huge) input.
    static func total(weightsBytes: Int?, kvBytes: Int?) -> Int? {
        guard let weightsBytes else { return nil }
        let scaled = (Double(weightsBytes) + Double(kvBytes ?? 0)) * (1 + overheadFraction)
        return scaled >= Double(Int.max) ? Int.max : Int(scaled.rounded())
    }

    // Convenience: weights + (per-token KV × context). KV term applied only when both are known.
    static func total(weightsBytes: Int?, kvBytesPerToken: Int?, context: Int?) -> Int? {
        var kvBytes: Int?
        if let perToken = kvBytesPerToken, let context { kvBytes = perToken * context }
        return total(weightsBytes: weightsBytes, kvBytes: kvBytes)
    }

    // The context to charge the KV term at: the actual context for a *loaded* model, else capped at the
    // engine default. An unloaded model loads at its default window, not the full advertised/native max,
    // so charging KV at the max badly over-estimates footprint — greying out the Load button and causing
    // spurious 503s for models that would fit. (Ollama infers a sharper effective context; engines
    // without that signal — LM Studio, llama-swap — use this cap.)
    static func estimateContext(loaded: Bool, context: Int?, cap: Int = defaultContextWindow) -> Int? {
        loaded ? context : context.map { min($0, cap) }
    }
}

// The uniform admission gate: "can a model of this predicted footprint be loaded into the memory
// that's free *right now*?" Reserves headroom for the OS and other apps. An unknown estimate is
// treated as loadable (we can't prove it won't fit). Pure + reusable — the Settings UI uses it to
// disable Load buttons today; the proxy/load manager can use the same call later.
enum MemoryBudget {
    static let defaultReserveBytes = 2 * 1_073_741_824   // 2 GB headroom for the OS / other apps

    static func canLoad(estimatedSizeBytes: Int?, availableBytes: Int,
                        reserveBytes: Int = defaultReserveBytes) -> Bool {
        guard let needed = estimatedSizeBytes else { return true }
        return needed <= availableBytes - reserveBytes   // not `needed + reserve` — avoids overflow
    }
}
