import Testing
import Foundation
@testable import LMDeckCore

// MARK: - Pure eviction planner

struct EvictionPlannerTests {
    private func lm(_ model: String, est: Int?, used: Double, pinned: Bool = false,
                    kind: EngineKind = .ollama) -> LoadedModel {
        LoadedModel(kind: kind, model: model, estimatedBytes: est,
                    lastUsed: Date(timeIntervalSince1970: used), pinned: pinned)
    }
    private func plan(_ incoming: Int?, free: Int, reserve: Int = 0,
                      _ loaded: [LoadedModel]) -> EvictionPlanner.Decision {
        EvictionPlanner.plan(incomingEstimate: incoming, freeBytes: free, reserveBytes: reserve, loaded: loaded)
    }

    @Test func fitsWithoutEviction() {
        #expect(plan(100, free: 1000, []) == .admit)
    }

    @Test func unknownIncomingAlwaysAdmits() {
        // An unknown footprint can't be proven not to fit → admit (consistent with MemoryBudget).
        #expect(plan(nil, free: 0, [lm("A", est: 500, used: 1)]) == .admit)
    }

    @Test func exactFitAdmits() {
        #expect(plan(1000, free: 1000, []) == .admit)
    }

    @Test func respectsReserveBoundary() {
        #expect(plan(100, free: 1000, reserve: 900, []) == .admit)       // 100 ≤ 1000-900
        #expect(plan(100, free: 1000, reserve: 901, []) == .cannotFit)   // 100 > 1000-901, nothing to evict
    }

    @Test func evictsSingleLRUToFit() {
        let a = lm("A", est: 600, used: 1)
        #expect(plan(500, free: 100, [a]) == .evictThenAdmit([a]))
    }

    @Test func evictsInLRUOrderAccumulating() {
        let a = lm("A", est: 300, used: 1)   // older → evicted first
        let b = lm("B", est: 300, used: 2)
        // need 500, free 100: A→400 (<500), then B→700 (≥500). Order is by lastUsed, not input order.
        #expect(plan(500, free: 100, [b, a]) == .evictThenAdmit([a, b]))
    }

    @Test func stopsAtMinimalVictims() {
        let a = lm("A", est: 300, used: 1)
        let b = lm("B", est: 300, used: 2)
        #expect(plan(350, free: 100, [a, b]) == .evictThenAdmit([a]))   // A alone (400 ≥ 350) is enough
    }

    @Test func skipsPinnedCandidates() {
        let pinned = lm("A", est: 600, used: 1, pinned: true)
        let unpinned = lm("B", est: 600, used: 2)
        #expect(plan(500, free: 100, [pinned, unpinned]) == .evictThenAdmit([unpinned]))
    }

    @Test func skipsUnknownEstimateCandidates() {
        let unknown = lm("A", est: nil, used: 1)
        let known = lm("B", est: 600, used: 2)
        #expect(plan(500, free: 100, [unknown, known]) == .evictThenAdmit([known]))
    }

    @Test func cannotFitWhenUnpinnedInsufficient() {
        #expect(plan(1000, free: 100, [lm("A", est: 200, used: 1)]) == .cannotFit)
    }

    @Test func cannotFitWhenEverythingPinned() {
        #expect(plan(500, free: 100, [lm("A", est: 600, used: 1, pinned: true)]) == .cannotFit)
    }

    @Test func hugeCandidateEstimateDoesNotOverflow() {
        // A garbage huge resident estimate must saturate, not trap.
        #expect(plan(500, free: 100, [lm("A", est: .max, used: 1)]) == .evictThenAdmit([lm("A", est: .max, used: 1)]))
    }

    @Test func evictsUnknownAsLastResortWhenMeasurableInsufficient() {
        // B(200) can't cover the 1000 need; the unmeasured A is evicted too as a last resort (LRU
        // order), admitting optimistically rather than refusing on an unmeasurable blocker.
        let unknown = lm("A", est: nil, used: 1)
        let known = lm("B", est: 200, used: 2)
        #expect(plan(1000, free: 100, [known, unknown]) == .evictThenAdmit([unknown, known]))
    }

    @Test func evictsOnlyUnknownsWhenNoMeasurableCandidates() {
        let a = lm("A", est: nil, used: 1)
        let b = lm("B", est: nil, used: 2)
        #expect(plan(500, free: 100, [b, a]) == .evictThenAdmit([a, b]))   // LRU order, optimistic admit
    }

    @Test func pinnedUnknownIsNeverEvictedEvenAsLastResort() {
        #expect(plan(500, free: 100, [lm("A", est: nil, used: 1, pinned: true)]) == .cannotFit)
    }
}

// MARK: - LoadManager actor (injected seams — no real I/O)

struct LoadManagerActorTests {
    private actor Recorder {
        private(set) var unloaded: [String] = []
        func record(_ kind: EngineKind, _ model: String) { unloaded.append("\(kind.token)/\(model)") }
        func calls() -> [String] { unloaded }
    }
    // Monotonic clock so last-use ordering is deterministic across admit() calls.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t = 0.0
        func next() -> Date { lock.lock(); defer { lock.unlock() }; t += 1; return Date(timeIntervalSince1970: t) }
    }

    private func model(_ id: String, loaded: Bool, est: Int?) -> ModelInfo {
        ModelInfo(id: id, loaded: loaded, sizeBytes: est, contextLength: nil, estimatedSizeBytes: est)
    }
    private func state(_ kind: EngineKind, _ models: [ModelInfo]) -> EngineState {
        EngineState(name: kind.token, kind: kind, canControl: true, models: models)
    }
    private func manager(_ states: [EngineState], free: Int, recorder: Recorder,
                         pinned: Set<String> = [], clock: Clock = Clock()) -> LoadManager {
        LoadManager(
            discover: { states },
            availableBytes: { free },
            unload: { kind, model in await recorder.record(kind, model); return nil },
            isPinned: { kind, model in pinned.contains("\(kind.token)/\(model)") },
            now: { clock.next() },
            logEvent: { _, _, _, _ in },
            reserveBytes: 0
        )
    }

    @Test func loadedTargetAdmitsWithoutUnload() async {
        let rec = Recorder()
        let mgr = manager([state(.ollama, [model("A", loaded: true, est: 600)])], free: 0, recorder: rec)
        #expect(await mgr.admit(kind: .ollama, model: "A", force: false, policy: .evictToFit) == .admitted)
        #expect(await rec.calls().isEmpty)
    }

    @Test func fittingTargetAdmitsWithoutUnload() async {
        let rec = Recorder()
        let mgr = manager([state(.ollama, [model("B", loaded: false, est: 100)])], free: 10_000, recorder: rec)
        #expect(await mgr.admit(kind: .ollama, model: "B", force: false, policy: .evictToFit) == .admitted)
        #expect(await rec.calls().isEmpty)
    }

    @Test func evictsLRUUnpinnedThenAdmits() async {
        let rec = Recorder()
        let states = [state(.ollama, [
            model("A", loaded: true, est: 600),
            model("B", loaded: true, est: 600),
            model("C", loaded: false, est: 500),
        ])]
        let mgr = manager(states, free: 100, recorder: rec)
        // Warm A then B → A is the least-recently-used.
        _ = await mgr.admit(kind: .ollama, model: "A", force: false, policy: .evictToFit)
        _ = await mgr.admit(kind: .ollama, model: "B", force: false, policy: .evictToFit)
        #expect(await mgr.admit(kind: .ollama, model: "C", force: false, policy: .evictToFit) == .admitted)
        #expect(await rec.calls() == ["ollama/A"])
    }

    // Eviction is needed to fit C, but the unload fails → no room is actually freed, so admission must
    // refuse rather than load C on top of A (the OOM the "clean refusal" guarantee is meant to prevent).
    @Test func failedEvictionRefusesInsteadOfAdmitting() async {
        let rec = Recorder()
        let states = [state(.ollama, [
            model("A", loaded: true, est: 600),
            model("C", loaded: false, est: 500),
        ])]
        let mgr = LoadManager(
            discover: { states },
            availableBytes: { 100 },                                   // C(500) needs A(600) evicted
            unload: { kind, model in await rec.record(kind, model); return "engine error" },   // fails
            isPinned: { _, _ in false },
            now: { Date() },
            logEvent: { _, _, _, _ in },
            reserveBytes: 0
        )
        let result = await mgr.admit(kind: .ollama, model: "C", force: false, policy: .evictToFit)
        #expect(result == .insufficientMemory(estimatedBytes: 500, availableBytes: 100))
        #expect(await rec.calls() == ["ollama/A"])                     // it tried to evict A; the unload failed
    }

    @Test func refuseIfFullDoesNotEvict() async {
        let rec = Recorder()
        let states = [state(.ollama, [
            model("A", loaded: true, est: 600),
            model("C", loaded: false, est: 500),
        ])]
        let mgr = manager(states, free: 100, recorder: rec)
        let result = await mgr.admit(kind: .ollama, model: "C", force: false, policy: .refuseIfFull)
        #expect(result == .insufficientMemory(estimatedBytes: 500, availableBytes: 100))
        #expect(await rec.calls().isEmpty)
    }

    @Test func forceAdmitsWithoutGate() async {
        let rec = Recorder()
        let states = [state(.ollama, [
            model("A", loaded: true, est: 600),
            model("C", loaded: false, est: 5000),
        ])]
        let mgr = manager(states, free: 100, recorder: rec)
        #expect(await mgr.admit(kind: .ollama, model: "C", force: true, policy: .refuseIfFull) == .admitted)
        #expect(await rec.calls().isEmpty)
    }

    @Test func pinnedModelIsNeverEvicted() async {
        let rec = Recorder()
        let states = [state(.ollama, [
            model("A", loaded: true, est: 600),   // pinned
            model("B", loaded: true, est: 600),
            model("C", loaded: false, est: 500),
        ])]
        let mgr = manager(states, free: 100, recorder: rec, pinned: ["ollama/A"])
        #expect(await mgr.admit(kind: .ollama, model: "C", force: false, policy: .evictToFit) == .admitted)
        #expect(await rec.calls() == ["ollama/B"])   // A protected, B evicted
    }

    @Test func evictsAcrossEngines() async {
        // Incoming ollama model; the LRU unpinned victim is on a *different* engine (omlx) — the
        // whole point of a cross-engine manager.
        let rec = Recorder()
        let states = [
            state(.omlx, [model("X", loaded: true, est: 600)]),
            state(.ollama, [model("C", loaded: false, est: 500)]),
        ]
        let mgr = manager(states, free: 100, recorder: rec)
        #expect(await mgr.admit(kind: .ollama, model: "C", force: false, policy: .evictToFit) == .admitted)
        #expect(await rec.calls() == ["omlx/X"])
    }

    @Test func cannotFitReturnsInsufficientAndEvictsNothing() async {
        let rec = Recorder()
        let states = [state(.ollama, [
            model("A", loaded: true, est: 200),
            model("C", loaded: false, est: 5000),
        ])]
        let mgr = manager(states, free: 100, recorder: rec)
        let result = await mgr.admit(kind: .ollama, model: "C", force: false, policy: .evictToFit)
        #expect(result == .insufficientMemory(estimatedBytes: 5000, availableBytes: 100))
        #expect(await rec.calls().isEmpty)   // don't evict when it can't be made to fit anyway
    }

    // MARK: pending-load reservations (the TOCTOU fix)

    private actor StatesBox {
        private var states: [EngineState]
        init(_ initial: [EngineState]) { states = initial }
        func get() -> [EngineState] { states }
        func set(_ s: [EngineState]) { states = s }
    }
    private final class MutableClock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ start: Date) { t = start }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
    }

    @Test func reservationBlocksSecondConcurrentAdmit() async {
        let rec = Recorder()
        let states = [state(.ollama, [
            model("A", loaded: false, est: 500),
            model("B", loaded: false, est: 500),
        ])]
        let mgr = manager(states, free: 700, recorder: rec)
        #expect(await mgr.admit(kind: .ollama, model: "A", force: false, policy: .refuseIfFull) == .admitted)
        // A is admitted but not yet resident; its reservation leaves only 200 free, so B is refused.
        // Without the reservation both would pass and together exceed 700 — the OOM the admission gate prevents.
        let second = await mgr.admit(kind: .ollama, model: "B", force: false, policy: .refuseIfFull)
        #expect(second == .insufficientMemory(estimatedBytes: 500, availableBytes: 200))
    }

    @Test func reservationReleasedWhenModelBecomesResident() async {
        let rec = Recorder()
        let box = StatesBox([state(.ollama, [
            model("A", loaded: false, est: 500),
            model("B", loaded: false, est: 500),
        ])])
        let mgr = LoadManager(discover: { await box.get() }, availableBytes: { 700 },
                              unload: { k, m in await rec.record(k, m); return nil },
                              isPinned: { _, _ in false }, now: { Date() },
                              logEvent: { _, _, _, _ in }, reserveBytes: 0)
        #expect(await mgr.admit(kind: .ollama, model: "A", force: false, policy: .refuseIfFull) == .admitted)
        await box.set([state(.ollama, [
            model("A", loaded: true, est: 500),     // A finished loading → its reservation should clear
            model("B", loaded: false, est: 500),
        ])])
        #expect(await mgr.admit(kind: .ollama, model: "B", force: false, policy: .refuseIfFull) == .admitted)
    }

    @Test func reservationExpiresAfterTTL() async {
        let rec = Recorder()
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let states = [state(.ollama, [
            model("A", loaded: false, est: 500),
            model("B", loaded: false, est: 500),
        ])]
        let mgr = LoadManager(discover: { states }, availableBytes: { 700 },
                              unload: { k, m in await rec.record(k, m); return nil },
                              isPinned: { _, _ in false }, now: { clock.now() },
                              logEvent: { _, _, _, _ in }, reserveBytes: 0, reservationTTL: 5)
        #expect(await mgr.admit(kind: .ollama, model: "A", force: false, policy: .refuseIfFull) == .admitted)
        clock.advance(10)   // past the 5 s TTL → A's stale reservation lapses, freeing the budget
        #expect(await mgr.admit(kind: .ollama, model: "B", force: false, policy: .refuseIfFull) == .admitted)
    }

    // The fix for the spurious-eviction bug: a reservation is released the moment its load resolves,
    // so it can't linger and block later admits even when there's plenty of real RAM.
    @Test func releaseReservationFreesTheBudget() async {
        let rec = Recorder()
        let states = [state(.ollama, [
            model("A", loaded: false, est: 500),
            model("B", loaded: false, est: 500),
        ])]
        let mgr = manager(states, free: 700, recorder: rec)
        #expect(await mgr.admit(kind: .ollama, model: "A", force: false, policy: .refuseIfFull) == .admitted)
        // While A's reservation stands, B would be refused (700 − 500 = 200 < 500)…
        await mgr.releaseReservation(kind: .ollama, model: "A")   // …but releasing it (A's load resolved) frees the budget
        #expect(await mgr.admit(kind: .ollama, model: "B", force: false, policy: .refuseIfFull) == .admitted)
        #expect(await rec.calls().isEmpty)   // and B admits without evicting anything
    }

    // The reported symptom precisely (proxy / evictToFit path): a prior model-switch left B with a
    // standing load-reservation. While it stands, the next request (C) would evict the resident A to
    // make room — but B's load has resolved, so releasing the reservation restores the real free RAM
    // and C fits with nothing evicted. This is the "evicts despite plenty of RAM" bug, at the actor level.
    @Test func releasingReservationPreventsSpuriousEviction() async {
        let rec = Recorder()
        let states = [state(.ollama, [
            model("A", loaded: true,  est: 400),   // resident, unpinned → the would-be victim
            model("B", loaded: false, est: 400),   // prior switch: admitted + reserved, still "loading"
            model("C", loaded: false, est: 500),   // the new request
        ])]
        let mgr = manager(states, free: 800, recorder: rec)
        #expect(await mgr.admit(kind: .ollama, model: "B", force: false, policy: .evictToFit) == .admitted)
        #expect(await rec.calls().isEmpty)                         // B fit (800 ≥ 400) without eviction
        // B's 400 reservation now stands → effective free 400; admitting C(500) here would evict A.
        await mgr.releaseReservation(kind: .ollama, model: "B")    // B's load resolved → reservation gone
        #expect(await mgr.admit(kind: .ollama, model: "C", force: false, policy: .evictToFit) == .admitted)
        #expect(await rec.calls().isEmpty)                         // A is NOT evicted — the bug's fix
    }
}

// MARK: - Pins pure helper

struct PinsTests {
    @Test func keyForIsQualifiedId() {
        #expect(Pins.keyFor(.omlx, "Model-X") == "omlx/Model-X")
    }

    @Test func toggledAddsAndRemoves() {
        #expect(Pins.toggled(in: [], key: "ollama/A", on: true) == ["ollama/A"])
        #expect(Pins.toggled(in: ["ollama/A"], key: "ollama/A", on: false) == [])
        #expect(Pins.toggled(in: ["ollama/A"], key: "omlx/B", on: true) == ["ollama/A", "omlx/B"])
        #expect(Pins.toggled(in: ["ollama/A"], key: "ollama/A", on: true) == ["ollama/A"])   // idempotent add
    }
}
