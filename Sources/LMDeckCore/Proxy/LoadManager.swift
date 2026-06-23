import Foundation

// The cross-engine memory-admission gate. Every path that loads a model — the implicit proxy JIT
// load and the explicit load endpoint — consults `LoadManager.admit` before the engine commits RAM,
// so admission + LRU eviction + pinning live in one place instead of duplicating the `canLoad`
// gate. The pure decision logic (EvictionPlanner) and the persisted pin set (Pins) sit alongside
// the actor that owns the live last-use state.

// MARK: - Pinning (user intent — persisted, shared truth)

// Models the user has pinned so the manager never evicts them. Stored in UserDefaults as an array
// of qualified ids ("<token>/<model>") — the single source read by both the eviction logic here and
// the Settings UI (ModelStore mirrors it for SwiftUI).
enum Pins {
    static func keyFor(_ kind: EngineKind, _ model: String) -> String { "\(kind.token)/\(model)" }

    static func all() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: SettingsKeys.pinnedModels) ?? []) }

    static func isPinned(_ kind: EngineKind, _ model: String) -> Bool { all().contains(keyFor(kind, model)) }

    static func setPinned(_ pinned: Bool, _ kind: EngineKind, _ model: String) {
        let next = toggled(in: all(), key: keyFor(kind, model), on: pinned)
        UserDefaults.standard.set(Array(next).sorted(), forKey: SettingsKeys.pinnedModels)
    }

    // Pure: the pin set with `key` added (on) or removed (off). Unit-tested.
    static func toggled(in set: Set<String>, key: String, on: Bool) -> Set<String> {
        var s = set
        if on { s.insert(key) } else { s.remove(key) }
        return s
    }
}

// MARK: - Eviction planning (pure — unit-tested)

// One resident model considered as an eviction candidate.
struct LoadedModel: Equatable {
    let kind: EngineKind
    let model: String           // engine-local id
    let estimatedBytes: Int?    // predicted footprint; nil = unknown
    let lastUsed: Date          // .distantPast when LMDeck has never observed it used
    let pinned: Bool
}

// Decides whether an incoming model fits the memory free *right now*, and if not, which already-
// loaded models to evict (LRU-unpinned, across all engines) to make room. Built on the same
// MemoryBudget.canLoad gate the UI and load endpoint use, so the math isn't duplicated.
enum EvictionPlanner {
    enum Decision: Equatable {
        case admit                              // fits as-is (or unknown footprint → can't block)
        case evictThenAdmit([LoadedModel])      // evict these (LRU first), then it fits
        case cannotFit                          // won't fit even after evicting every unpinned model
    }

    static func plan(incomingEstimate: Int?, freeBytes: Int, reserveBytes: Int,
                     loaded: [LoadedModel]) -> Decision {
        // Already fits? canLoad also returns true for an unknown incoming estimate — we can't prove
        // it won't fit, consistent with the rest of the gate.
        if MemoryBudget.canLoad(estimatedSizeBytes: incomingEstimate, availableBytes: freeBytes,
                                reserveBytes: reserveBytes) {
            return .admit
        }
        // Make room LRU-first from models whose footprint we can measure, stopping at the minimal set.
        // Pinned models are protected (user intent).
        let unpinned = loaded.filter { !$0.pinned }.sorted { $0.lastUsed < $1.lastUsed }
        var freed = 0
        var victims: [LoadedModel] = []
        for c in unpinned where (c.estimatedBytes ?? 0) > 0 {
            victims.append(c)
            freed = satAdd(freed, c.estimatedBytes!)   // safe: filtered to > 0
            if MemoryBudget.canLoad(estimatedSizeBytes: incomingEstimate,
                                    availableBytes: satAdd(freeBytes, freed), reserveBytes: reserveBytes) {
                return .evictThenAdmit(victims)
            }
        }
        // Measurable evictions weren't enough. As a LAST resort, also evict unpinned models whose
        // footprint we *can't* measure (a running llama-swap / LM Studio model with no reported size):
        // they hold real RAM but are invisible to the byte math, so one could otherwise silently wedge
        // admission like a pin. We can't prove this frees enough, so we admit
        // optimistically — the pending-load reservation + memory reserve are the backstop. No unknowns
        // to try ⇒ give up.
        let unknown = unpinned.filter { ($0.estimatedBytes ?? 0) <= 0 }
        guard !unknown.isEmpty else { return .cannotFit }
        return .evictThenAdmit((victims + unknown).sorted { $0.lastUsed < $1.lastUsed })
    }

    // Saturating add — a garbage (huge) estimate must not trap on Int overflow.
    private static func satAdd(_ a: Int, _ b: Int) -> Int {
        let (s, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : s
    }
}

// MARK: - Admission

// Whether the caller will evict to make room.
enum AdmissionPolicy: Equatable {
    case evictToFit      // silently evict LRU-unpinned models to fit (the proxy default)
    case refuseIfFull    // never evict; refuse if it doesn't fit as-is (the explicit load endpoint)
}

enum Admission: Equatable {
    case admitted
    case insufficientMemory(estimatedBytes: Int?, availableBytes: Int)
}

// MARK: - LoadManager

// The single owner of "what's loaded across all engines, in what LRU order, and what's pinned."
// Tracks last-use per (engine, model) for LRU eviction and reads the pin set (user intent) from
// `Pins`. Dependencies are injectable (like DiscoveryCache) so the policy is unit-testable without
// real I/O.
actor LoadManager {
    static let shared = LoadManager()

    struct Key: Hashable { let kind: EngineKind; let model: String }

    private let discover: @Sendable () async -> [EngineState]
    private let availableBytes: @Sendable () -> Int
    private let unload: @Sendable (EngineKind, String) async -> String?
    private let isPinned: @Sendable (EngineKind, String) -> Bool
    private let now: @Sendable () -> Date
    private let logEvent: @Sendable (String, String?, TimeInterval, Bool) -> Void
    private let reserveBytes: Int
    private let reservationTTL: TimeInterval

    // Live last-use timestamps (ephemeral — LRU only; pins persist, this doesn't).
    private var lastUsed: [Key: Date] = [:]

    // Admitted-but-not-yet-resident footprints. admit() decisions serialize on the actor, but the
    // loads they authorize complete *outside* it (the engine JIT-loads during streaming), so a later
    // discover() won't yet show them loaded. We subtract these from free RAM until the model appears
    // loaded (pruned then) or the TTL lapses — the TTL matches the load timeout, so a slow cold load
    // stays protected for its whole duration yet a failed load still can't wedge memory forever. This
    // closes the TOCTOU window where two concurrent first-loads both pass admission and together OOM.
    private struct Reservation { let bytes: Int; let expires: Date }
    private var reservations: [Key: Reservation] = [:]

    init(discover: @escaping @Sendable () async -> [EngineState] = { await DiscoveryCache.shared.current() },
         availableBytes: @escaping @Sendable () -> Int = { Int(SystemMemory.availableBytes) },
         unload: @escaping @Sendable (EngineKind, String) async -> String? = { kind, model in
             guard let client = EngineRegistry.live().first(where: { $0.kind == kind }) else { return nil }
             return await client.unload(model)
         },
         isPinned: @escaping @Sendable (EngineKind, String) -> Bool = { Pins.isPinned($0, $1) },
         now: @escaping @Sendable () -> Date = { Date() },
         logEvent: @escaping @Sendable (String, String?, TimeInterval, Bool) -> Void = {
             EventLog.model($0, detail: $1, seconds: $2, ok: $3)
         },
         reserveBytes: Int = MemoryBudget.defaultReserveBytes,
         reservationTTL: TimeInterval = ModelEngine.loadTimeout) {   // outlive a slow cold load
        self.discover = discover
        self.availableBytes = availableBytes
        self.unload = unload
        self.isPinned = isPinned
        self.now = now
        self.logEvent = logEvent
        self.reserveBytes = reserveBytes
        self.reservationTTL = reservationTTL
    }

    // Consulted before a model is loaded — by the proxy path (before forwarding to an unloaded
    // model) and by the explicit load endpoint. Records use of the target, gates on free memory,
    // and (only for .evictToFit) silently evicts LRU-unpinned models across any engine to make room.
    func admit(kind: EngineKind, model: String, force: Bool, policy: AdmissionPolicy) async -> Admission {
        let key = Key(kind: kind, model: model)
        let states = await discover()
        pruneReservations(states: states)   // drop now-loaded / expired reservations before gating

        guard let target = states.first(where: { $0.kind == kind })?.models.first(where: { $0.id == model }) else {
            return .admitted   // caller already validated existence; nothing to gate on
        }
        // Already resident: admit and keep it warm (LRU touch). No reservation (already counted).
        if target.loaded { lastUsed[key] = now(); return .admitted }

        // This target's own prior reservation (a repeat request before it loaded) mustn't count
        // against itself — we're about to re-decide it.
        reservations[key] = nil
        let free = effectiveFree()   // free RAM minus other in-flight admits' reservations

        // Explicit force bypasses the gate but still commits RAM, so reserve its footprint too.
        if force { reserve(key, target); return .admitted }

        // Prefix for the admission-reasoning log below — the exact memory math behind the decision,
        // logged *in addition* to the per-event lines (Auto-evicted… / engine load / Couldn't serve…).
        let head = "Requested \(kind.token)/\(model). Available RAM \(Self.gb(free)), model size " +
                   "\(Self.gb(target.sizeBytes)), effective \(Self.gb(target.estimatedSizeBytes))"

        let loaded: [LoadedModel] = states.flatMap { s in
            s.models.filter(\.loaded).map { m in
                LoadedModel(kind: s.kind, model: m.id, estimatedBytes: m.estimatedSizeBytes,
                            lastUsed: lastUsed[Key(kind: s.kind, model: m.id)] ?? .distantPast,
                            pinned: isPinned(s.kind, m.id))
            }
        }
        switch EvictionPlanner.plan(incomingEstimate: target.estimatedSizeBytes, freeBytes: free,
                                    reserveBytes: reserveBytes, loaded: loaded) {
        case .admit:
            reserve(key, target)
            let left = target.estimatedSizeBytes.map { free - $0 }
            logEvent("\(head), \(Self.gb(left)) left after loading (keeping \(Self.gb(reserveBytes)) reserve) — admitted",
                     nil, 0, true)
            return .admitted
        case .evictThenAdmit(let victims):
            guard case .evictToFit = policy else {
                logEvent("\(head) — won't fit and this is an explicit load which does not auto-evict — refused",
                         nil, 0, false)
                return .insufficientMemory(estimatedBytes: target.estimatedSizeBytes, availableBytes: free)
            }
            let incoming = "\(kind.token)/\(model)"
            var evicted: [String] = []
            var freed = 0
            var failures = 0
            let tStart = Date()
            for v in victims {
                let t0 = Date()
                let err = await unload(v.kind, v.model)                 // best-effort
                let secs = Date().timeIntervalSince(t0)
                let victim = "\(v.kind.token)/\(v.model)"
                let unmeasured = (v.estimatedBytes ?? 0) <= 0
                if let err {
                    logEvent("Failed to auto-evict \(victim)", err, secs, false)
                    failures += 1
                } else {
                    if unmeasured {
                        logEvent("Auto-evicted \(victim) (size unknown)", "freeing memory for \(incoming) as a last resort", secs, true)
                    } else {
                        logEvent("Auto-evicted \(victim)", "to make room for \(incoming)", secs, true)
                    }
                    evicted.append("\(victim) (\(Self.gb(v.estimatedBytes)))")
                    freed = Self.satAdd(freed, max(0, v.estimatedBytes ?? 0))
                }
                let vk = Key(kind: v.kind, model: v.model)
                lastUsed[vk] = nil
                reservations[vk] = nil
            }
            await DiscoveryCache.shared.invalidate()                    // the loaded set changed
            let freeAfter = Self.satAdd(free, freed)
            // The planner assumed every victim would free its estimate. If some unloads failed, that
            // room may not exist — re-check before admitting so a failed eviction can't load a model on
            // top of the others (the OOM the "clean refusal" guarantee is meant to prevent).
            if failures > 0, !MemoryBudget.canLoad(estimatedSizeBytes: target.estimatedSizeBytes,
                                                   availableBytes: freeAfter, reserveBytes: reserveBytes) {
                logEvent("\(head) — \(failures) eviction(s) failed; only \(Self.gb(freed)) freed, still won't fit — refused",
                         nil, Date().timeIntervalSince(tStart), false)
                return .insufficientMemory(estimatedBytes: target.estimatedSizeBytes, availableBytes: freeAfter)
            }
            reserve(key, target)
            let left = target.estimatedSizeBytes.map { freeAfter - $0 }
            let evictedList = evicted.isEmpty ? "nothing (evictions failed)" : evicted.joined(separator: ", ")
            logEvent("\(head) — evicting \(evictedList); \(Self.gb(left)) left after evicting and loading (keeping \(Self.gb(reserveBytes)) reserve) — admitted",
                     nil, Date().timeIntervalSince(tStart), true)
            return .admitted
        case .cannotFit:
            logEvent("\(head) — won't fit even after evicting every unpinned model (keeping \(Self.gb(reserveBytes)) reserve) — refused",
                     nil, 0, false)
            return .insufficientMemory(estimatedBytes: target.estimatedSizeBytes, availableBytes: free)
        }
    }

    // Release a pending-load reservation once the load has *resolved* (the model is now resident, or
    // the load failed). The load paths call this when their forward/load returns — so a finished load
    // isn't double-counted (its RAM is real now) and a fast/failed load can't leave a phantom
    // reservation eating the budget until the TTL (which would cause spurious evictions when a client
    // switches between models). No-op when there was no reservation (the model was already loaded).
    func releaseReservation(kind: EngineKind, model: String) {
        reservations[Key(kind: kind, model: model)] = nil
    }

    // Record the LRU touch + a pending-load reservation for an admitted, not-yet-resident model.
    private func reserve(_ key: Key, _ target: ModelInfo) {
        let t = now()
        lastUsed[key] = t
        let bytes = target.estimatedSizeBytes ?? 0
        if bytes > 0 { reservations[key] = Reservation(bytes: bytes, expires: t.addingTimeInterval(reservationTTL)) }
    }

    // Free RAM minus what other in-flight admits have reserved but not yet committed.
    private func effectiveFree() -> Int {
        let reserved = reservations.values.reduce(0) { Self.satAdd($0, $1.bytes) }
        return max(0, availableBytes() - reserved)
    }

    // Bytes → "16.9 GB" for the admission-reasoning log; "unknown" when unmeasured (nil / ≤ 0).
    private static func gb(_ bytes: Int?) -> String {
        guard let bytes, bytes > 0 else { return "unknown" }
        return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    // Drop reservations whose model is now loaded (already counted in discovery) or whose TTL lapsed.
    private func pruneReservations(states: [EngineState]) {
        let loadedKeys = Set(states.flatMap { s in
            s.models.filter(\.loaded).map { Key(kind: s.kind, model: $0.id) }
        })
        let t = now()
        reservations = reservations.filter { key, r in !loadedKeys.contains(key) && r.expires > t }
    }

    private static func satAdd(_ a: Int, _ b: Int) -> Int {
        let (s, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : s
    }
}
