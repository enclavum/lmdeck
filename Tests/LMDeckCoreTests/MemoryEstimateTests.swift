import Testing
@testable import LMDeckCore

struct MemoryEstimateTests {

    @Test func kvBytesPerToken() {
        // Llama-3-8B: 32 layers, 8 KV heads, head_dim 128, fp16 → 128 KB/token.
        #expect(MemoryEstimate.kvBytesPerToken(layers: 32, kvHeads: 8, headDim: 128) == 131072)
        // 8-bit KV-cache quantization halves it.
        #expect(MemoryEstimate.kvBytesPerToken(layers: 32, kvHeads: 8, headDim: 128, bytesPerElement: 1) == 65536)
    }

    @Test func totalFromWeightsAndKV() {
        #expect(MemoryEstimate.total(weightsBytes: 1000, kvBytes: 100) == 1210)   // (1000+100) × 1.1
        #expect(MemoryEstimate.total(weightsBytes: 1000, kvBytes: nil) == 1100)   // weights + overhead
        #expect(MemoryEstimate.total(weightsBytes: nil, kvBytes: 100) == nil)
    }

    @Test func totalSaturatesInsteadOfTrapping() {
        // A garbage huge input must saturate, not trap on Int overflow.
        #expect(MemoryEstimate.total(weightsBytes: Int.max, kvBytes: nil) == Int.max)
    }

    @Test func totalFromPerTokenAndContext() {
        // KV term applied only when both per-token cost and context are known.
        #expect(MemoryEstimate.total(weightsBytes: 1000, kvBytesPerToken: 10, context: 8) == 1188)  // (1000+80) × 1.1
        #expect(MemoryEstimate.total(weightsBytes: 1000, kvBytesPerToken: nil, context: 8) == 1100)
        #expect(MemoryEstimate.total(weightsBytes: 1000, kvBytesPerToken: 10, context: nil) == 1100)
    }

    @Test func genericKVScalesWithSizeAndIsNilWhenUnknown() {
        // ~Q4 8B model (≈4.4 GB) ≈ 128 KiB/token (calibrated to Llama-3-8B GQA).
        let kv = MemoryEstimate.genericKVBytesPerToken(weightsBytes: 4_400_000_000)
        #expect(kv != nil)
        #expect((120_000...140_000).contains(kv!))
        // Unknown / non-positive weights → nil (can't estimate).
        #expect(MemoryEstimate.genericKVBytesPerToken(weightsBytes: nil) == nil)
        #expect(MemoryEstimate.genericKVBytesPerToken(weightsBytes: 0) == nil)
        // Larger model → larger per-token KV.
        #expect(MemoryEstimate.genericKVBytesPerToken(weightsBytes: 20_000_000_000)! >
                MemoryEstimate.genericKVBytesPerToken(weightsBytes: 4_400_000_000)!)
    }

    @Test func genericKVHandlesHugeInputWithoutTrapping() {
        #expect(MemoryEstimate.genericKVBytesPerToken(weightsBytes: Int.max)! > 0)
    }
}

struct MemoryBudgetTests {

    @Test func canLoadFitsWithReserve() {
        // needed + reserve must be ≤ available.
        #expect(MemoryBudget.canLoad(estimatedSizeBytes: 100, availableBytes: 1000, reserveBytes: 0))
        #expect(MemoryBudget.canLoad(estimatedSizeBytes: 1000, availableBytes: 1000, reserveBytes: 0))   // exact fit
        #expect(!MemoryBudget.canLoad(estimatedSizeBytes: 1001, availableBytes: 1000, reserveBytes: 0))
        #expect(MemoryBudget.canLoad(estimatedSizeBytes: 100, availableBytes: 1000, reserveBytes: 900))   // 1000 ≤ 1000
        #expect(!MemoryBudget.canLoad(estimatedSizeBytes: 100, availableBytes: 1000, reserveBytes: 901))  // 1001 > 1000
    }

    @Test func canLoadUnknownEstimateIsAllowed() {
        // Can't prove an unknown footprint won't fit → don't block.
        #expect(MemoryBudget.canLoad(estimatedSizeBytes: nil, availableBytes: 0))
        #expect(MemoryBudget.canLoad(estimatedSizeBytes: nil, availableBytes: 1_000_000))
    }

    @Test func canLoadHandlesHugeEstimateWithoutOverflow() {
        #expect(!MemoryBudget.canLoad(estimatedSizeBytes: Int.max, availableBytes: 1_000_000_000))
    }
}
