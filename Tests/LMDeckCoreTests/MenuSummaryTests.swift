import Testing
import Foundation
@testable import LMDeckCore

// The menu's at-a-glance list: loaded models across every engine, largest first.
struct MenuSummaryTests {

    @Test func flattensLoadedAcrossEnginesLargestFirst() {
        let states = [
            EngineState(name: "Ollama", kind: .ollama, canControl: true, models: [
                ModelInfo(id: "small", loaded: true, sizeBytes: 1_000, contextLength: nil, estimatedSizeBytes: nil),
                ModelInfo(id: "unloaded", loaded: false, sizeBytes: 9_999, contextLength: nil, estimatedSizeBytes: nil),
            ]),
            EngineState(name: "oMLX", kind: .omlx, canControl: true, models: [
                ModelInfo(id: "big", loaded: true, sizeBytes: 5_000, contextLength: nil, estimatedSizeBytes: nil),
                ModelInfo(id: "unknown", loaded: true, sizeBytes: nil, contextLength: nil, estimatedSizeBytes: nil),
            ]),
        ]
        let rows = MenuSummary.loadedRows(states)

        #expect(rows.map(\.model) == ["big", "small", "unknown"])   // unloaded excluded; size desc; nil last
        #expect(rows.first?.engine == "oMLX")
        #expect(rows.first?.kind == .omlx)
        #expect(rows.map(\.id) == ["omlx/big", "ollama/small", "omlx/unknown"])   // qualified, unique
    }

    @Test func emptyWhenNothingLoaded() {
        let states = [
            EngineState(name: "Ollama", kind: .ollama, canControl: true, models: [
                ModelInfo(id: "x", loaded: false, sizeBytes: 1, contextLength: nil, estimatedSizeBytes: nil),
            ]),
        ]
        #expect(MenuSummary.loadedRows(states).isEmpty)
    }

    // Same model id loaded under two engines stays distinct (qualified id).
    @Test func sameModelIdUnderTwoEnginesStaysDistinct() {
        let states = [
            EngineState(name: "Ollama", kind: .ollama, canControl: true, models: [
                ModelInfo(id: "qwen2.5:7b", loaded: true, sizeBytes: 4_000, contextLength: nil, estimatedSizeBytes: nil),
            ]),
            EngineState(name: "llama-swap", kind: .llamaswap, canControl: true, models: [
                ModelInfo(id: "qwen2.5:7b", loaded: true, sizeBytes: 4_000, contextLength: nil, estimatedSizeBytes: nil),
            ]),
        ]
        let rows = MenuSummary.loadedRows(states)
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)) == ["ollama/qwen2.5:7b", "llamaswap/qwen2.5:7b"])
    }
}
