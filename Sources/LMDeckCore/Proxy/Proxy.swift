import Foundation
import Hummingbird
import NIOCore
import CryptoKit

// Per-engine connection info read live from settings. `key` becomes the Bearer token we send to
// that engine (empty = no Authorization header, e.g. local Ollama). `kind` carries the token +
// routing priority.
struct Engine: Sendable {
    let name: String
    let kind: EngineKind
    let base: URL
    let key: String
}

enum Proxy {
    // Lightweight per-engine connection info for the forwarder/routing, from the shared registry.
    static func engines() -> [Engine] {
        EngineRegistry.configs().map { Engine(name: $0.kind.token, kind: $0.kind, base: $0.base, key: $0.key) }
    }

    // Discover every engine's rich state concurrently — the raw primitive behind DiscoveryCache.
    // Unreachable engines drop out.
    static func discoverAll() async -> [EngineState] {
        // Only enabled engines (EngineRegistry.live()); a task group handles the variable count.
        // Results arrive in completion order, so sort by routing priority for a *stable* order — the
        // UI (Models pane) and menu render engines in this order and must not reshuffle each poll.
        await withTaskGroup(of: EngineState?.self) { group in
            for client in EngineRegistry.live() { group.addTask { await client.discover() } }
            var states: [EngineState] = []
            for await s in group { if let s { states.append(s) } }
            return states.sorted { $0.kind.priority < $1.kind.priority }
        }
    }

    // MARK: model-list serialization (pure — unit-tested)

    // OpenAI `GET /v1/models`. One row per (engine, model); id is the qualified `<token>/<model>`.
    // owned_by carries the engine so OpenAI clients can see which engine owns each entry. Bare
    // names are accepted as request input (see resolve) but are not listed — only the unique ids.
    static func openAIModelsJSON(_ states: [EngineState], now: Int) -> Data {
        var data: [[String: Any]] = []
        for s in states.sorted(by: { $0.kind.priority < $1.kind.priority }) {
            for m in s.models.sorted(by: { $0.id < $1.id }) {
                data.append(["id": "\(s.kind.token)/\(m.id)", "object": "model",
                             "created": now, "owned_by": s.kind.token])
            }
        }
        let payload: [String: Any] = ["object": "list", "data": data]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(#"{"object":"list","data":[]}"#.utf8)
    }

    // Native `GET /api/v1/models`. The same rows as openAIModelsJSON, with richer fields. Unknown
    // size / context_length / estimated_size are emitted as JSON `null` (not omitted); `loaded` and
    // `can_load` are always booleans.
    static func nativeCatalogJSON(_ states: [EngineState], availableBytes: Int) -> Data {
        var models: [[String: Any]] = []
        for s in states.sorted(by: { $0.kind.priority < $1.kind.priority }) {
            for m in s.models.sorted(by: { $0.id < $1.id }) {
                models.append(nativeRow(m, kind: s.kind, availableBytes: availableBytes))
            }
        }
        return (try? JSONSerialization.data(withJSONObject: ["models": models])) ?? Data(#"{"models":[]}"#.utf8)
    }

    // One catalog row. `can_load` is the admission gate against current free memory (a loaded model
    // is trivially true; an unknown footprint is treated as loadable). Same gate the UI uses.
    static func nativeRow(_ m: ModelInfo, kind: EngineKind, availableBytes: Int) -> [String: Any] {
        [
            "id": "\(kind.token)/\(m.id)",
            "model": m.id,
            "engine": kind.token,
            "loaded": m.loaded,
            "size": m.sizeBytes ?? NSNull(),
            "context_length": m.contextLength ?? NSNull(),
            "estimated_size": m.estimatedSizeBytes ?? NSNull(),
            "can_load": m.loaded || MemoryBudget.canLoad(estimatedSizeBytes: m.estimatedSizeBytes,
                                                         availableBytes: availableBytes),
        ]
    }

    // MARK: routing (pure — unit-tested)

    // model name -> the engines that have it, sorted by priority (highest first).
    static func buildIndex(_ pairs: [(kind: EngineKind, models: [String])]) -> [String: [EngineKind]] {
        var m: [String: [EngineKind]] = [:]
        for (kind, models) in pairs {
            for id in models { m[id, default: []].append(kind) }
        }
        for (id, kinds) in m { m[id] = kinds.sorted { $0.priority < $1.priority } }
        return m
    }

    // Resolve a requested `model` to (engine kind, engine-local model name), or nil (→ 404).
    //  • "<token>/<rest>" where token is a known engine → that engine iff it has <rest>, else nil.
    //  • otherwise (bare id, incl. HF ids with slashes) → the highest-priority engine that has it.
    static func resolve(_ requested: String, index: [String: [EngineKind]]) -> (kind: EngineKind, model: String)? {
        if let slash = requested.firstIndex(of: "/") {
            let prefix = String(requested[..<slash])
            if let kind = EngineKind.from(token: prefix) {
                let rest = String(requested[requested.index(after: slash)...])
                if let kinds = index[rest], kinds.contains(kind) { return (kind, rest) }
                return nil   // explicit engine that doesn't have this model
            }
        }
        if let kinds = index[requested], let best = kinds.first { return (best, requested) }
        return nil
    }

    // Resolve to a forwardable engine + engine-local name, from cached discovery. Built fresh each
    // call (cheap) so there's no torn index/engines state.
    static func route(_ requested: String) async -> (engine: Engine, upstreamModel: String, loaded: Bool)? {
        let states = await DiscoveryCache.shared.current()
        let index = buildIndex(states.map { (kind: $0.kind, models: $0.models.map(\.id)) })
        guard let (kind, model) = resolve(requested, index: index),
              let engine = engines().first(where: { $0.kind == kind }) else { return nil }
        let loaded = states.first { $0.kind == kind }?.models.first { $0.id == model }?.loaded ?? false
        return (engine, model, loaded)
    }

    // MARK: auth (pure)

    // Is this request authorized? An empty key means the endpoint is open. Constant-time comparison
    // so binding to 0.0.0.0 doesn't expose a timing oracle on the key.
    static func isAuthorized(_ authHeader: String?, key: String) -> Bool {
        if key.isEmpty { return true }
        guard let authHeader else { return false }
        return constantTimeEqual(authHeader, "Bearer \(key)")
    }

    // Compare fixed-length SHA-256 digests: the compare loop is always 32 bytes, so it leaks nothing
    // about the key's content or length. (Hashing itself runs in time proportional to the attacker-
    // supplied input length — a negligible signal on input size only, never on the key.)
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let da = SHA256.hash(data: Data(a.utf8)), db = SHA256.hash(data: Data(b.utf8))
        var diff: UInt8 = 0
        for (x, y) in zip(da, db) { diff |= x ^ y }
        return diff == 0
    }

    // Pure: does an engine's load/unload error look like "model not found"? Engines don't return
    // structured codes here, so this string-sniffs a few common phrasings to map to 404 vs 502.
    static func isNotFound(_ error: String) -> Bool {
        let e = error.lowercased()
        return e.contains("not found") || e.contains("not_found") || e.contains("no such")
    }

    static var endpointKey: String {
        SecretStore.shared.get(SettingsKeys.endpointKey).trimmingCharacters(in: .whitespaces)
    }

    // Live: should the proxy silently evict LRU-unpinned models to fit an incoming request?
    static var autoEvict: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.autoEvict) }

    static var endpointHost: String {
        UserDefaults.standard.string(forKey: SettingsKeys.endpointHost) ?? "127.0.0.1"
    }

    // Loopback (local-only) hosts. Anything else counts as network-exposed for the admin gate and the
    // in-flight throttle — so a routable IP set via `defaults write` (not just the literal `0.0.0.0`)
    // isn't mistaken for local.
    static func isLoopbackHost(_ host: String) -> Bool {
        ["127.0.0.1", "::1", "localhost"].contains(host)
    }

    // Admin (load/unload) endpoints can exhaust RAM or drive compute, so they're refused when the
    // server is network-exposed with no endpoint key — any LAN peer could otherwise hit them. Loopback
    // (local-only) or a configured key is required; the chat proxy itself stays open.
    static func adminAllowed(host: String, key: String) -> Bool {
        isLoopbackHost(host) || !key.isEmpty
    }

    // The proxy chat path's admission policy. Auto-evict is gated like the admin endpoints
    // (`adminAllowed`): an anonymous network peer (network-exposed, no key) must not be able to
    // unload your other models — that would contradict the "load/unload is blocked for anonymous
    // peers" hardening. So evict-to-fit only when auto-evict is on *and* the caller is loopback or
    // authenticated; otherwise refuse rather than evict. Pure so the matrix is unit-tested.
    static func admissionPolicy(autoEvict: Bool, host: String, key: String) -> AdmissionPolicy {
        autoEvict && adminAllowed(host: host, key: key) ? .evictToFit : .refuseIfFull
    }

    // MARK: router

    static func router() -> Router<BasicRequestContext> {
        let router = Router()
        // Auth first so unauthorized requests are rejected (and not counted). The key is read live
        // per request, so changing it in Settings takes effect without restarting the server.
        router.add(middleware: APIKeyMiddleware())
        router.add(middleware: CountingMiddleware())

        router.get("v1/models") { _, _ -> Response in
            jsonResponse(openAIModelsJSON(await DiscoveryCache.shared.current(), now: Int(Date().timeIntervalSince1970)))
        }
        router.get("api/v1/models") { _, _ -> Response in
            jsonResponse(nativeCatalogJSON(await DiscoveryCache.shared.current(), availableBytes: Int(SystemMemory.availableBytes)))
        }
        router.post("api/v1/models/load") { request, _ -> Response in
            await loadUnload(request, load: true)
        }
        router.post("api/v1/models/unload") { request, _ -> Response in
            await loadUnload(request, load: false)
        }
        // Catch-all forwarder — route any POST /v1/* to the engine that owns its `model`.
        router.post("v1/**") { request, _ -> Response in
            await forward(request)
        }
        return router
    }

    static func jsonResponse(_ json: Data) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: json)))
    }

    // MARK: model-routing streaming forwarder

    // Pure: the request body with its top-level `model` set to `model`, re-serialized. Falls back to
    // the original bytes when it isn't a JSON object. Applied uniformly to qualified and bare requests
    // so forwarding behaves identically either way (a bare id is a no-op rewrite).
    static func bodyForUpstream(_ data: Data, model: String) -> Data {
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        obj["model"] = model
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? data
    }

    // Read the `model` field, resolve the owning engine (qualified id → exact; bare → priority),
    // forward the body with that engine's Bearer key (inbound Authorization dropped) — rewriting
    // `model` to the engine-local name for a qualified id — and stream the response back unbuffered.
    static func forward(_ request: Request) async -> Response {
        // The upstream path is echoed to the local engine — reject traversal out of /v1/*.
        let path = request.uri.path
        let lowered = path.lowercased()
        guard !lowered.contains("..") && !lowered.contains("%2e") else {
            return errorResponse(.badRequest, "Invalid request path.")
        }

        // On a network-exposed bind (anything but loopback) cap concurrent forwards so an anonymous
        // peer can't pin many × maxRequestBytes of buffered bodies *or* many concurrent generations.
        // The slot is held for the whole request — buffering, admission, AND the streamed response —
        // so the cap bounds in-flight compute too. Loopback (the default, single-user) is unthrottled.
        // Released in streamUpstream's onComplete on success; the defer covers early-return paths.
        let networkExposed = !isLoopbackHost(endpointHost)
        if networkExposed, !InFlightLimiter.shared.tryAcquire() {
            return errorResponse(.serviceUnavailable, "Server busy: too many concurrent requests.")
        }
        var slotHeld = networkExposed
        defer { if slotHeld { InFlightLimiter.shared.release() } }

        let buffer: ByteBuffer
        do { buffer = try await request.body.collect(upTo: maxRequestBytes) }   // bound the buffered body
        catch { return errorResponse(.contentTooLarge, "Request body exceeds the \(maxRequestBytes / 1_048_576) MB limit.") }
        let data = Data(buffer.readableBytesView)

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requested = obj["model"] as? String, !requested.isEmpty else {
            return errorResponse(.badRequest, "Missing 'model' in request body.")
        }
        guard let routed = await route(requested) else {
            return errorResponse(.notFound, "No engine serves model '\(requested)'.")
        }
        let engine = routed.engine
        let wasLoaded = routed.loaded   // log an on-demand JIT load only when one actually happens

        // Cross-engine memory admission before the engine JIT-loads an unloaded model.
        // .evictToFit (default) silently frees room by unloading LRU-unpinned models across any
        // engine; .refuseIfFull (auto-evict off, or an anonymous network peer) refuses instead.
        // Loaded models pass straight through. See `admissionPolicy` for the gating rationale.
        let policy = Proxy.admissionPolicy(autoEvict: Proxy.autoEvict, host: endpointHost, key: endpointKey)
        // admit() logs the memory-math reasoning (admit / auto-evict / refusal) as an explanation; on
        // refusal we additionally log the event here and map it to the HTTP error.
        let admitStart = Date()
        if case .insufficientMemory(let est, let avail) = await LoadManager.shared.admit(
            kind: engine.kind, model: routed.upstreamModel, force: false, policy: policy) {
            EventLog.model("Couldn't serve \(engine.kind.token)/\(routed.upstreamModel) — insufficient memory",
                           seconds: Date().timeIntervalSince(admitStart), ok: false)
            return memoryErrorResponse(.serviceUnavailable, model: requested,
                                       estimatedSizeBytes: est, availableBytes: avail)
        }

        // Forward the original bytes untouched unless we must rewrite `model` to the engine-local
        // name (a qualified id) — re-encoding a bare-id body could drop/reorder keys or reformat numbers.
        let outData = routed.upstreamModel == requested ? data : bodyForUpstream(data, model: routed.upstreamModel)

        var urlString = engine.base.absoluteString + path
        if let q = request.uri.query, !q.isEmpty { urlString += "?" + q }
        guard let url = URL(string: urlString) else {
            return errorResponse(.badGateway, "Could not build upstream URL.")
        }

        var up = URLRequest(url: url)
        up.httpMethod = "POST"
        up.httpBody = outData
        up.timeoutInterval = 600                       // allow long-running generations
        up.setValue(request.headers[.contentType] ?? "application/json", forHTTPHeaderField: "Content-Type")
        if let accept = request.headers[.accept] { up.setValue(accept, forHTTPHeaderField: "Accept") }
        if !engine.key.isEmpty { up.setValue("Bearer \(engine.key)", forHTTPHeaderField: "Authorization") }

        // Stream upstream → client in network-sized chunks (see streamUpstream). nil head = the
        // connection failed before any response. Hand the in-flight slot to the stream's lifetime so
        // it's released only when the response finishes or the client disconnects (so the cap bounds
        // concurrent generations, not just admission).
        let releaseSlot: (@Sendable () -> Void)?
        if slotHeld {
            releaseSlot = { InFlightLimiter.shared.release() }
            slotHeld = false   // handed off to the stream's lifetime; the defer must not also release
        } else {
            releaseSlot = nil
        }
        let loadStart = Date()
        let (head, stream) = await streamUpstream(up, onComplete: releaseSlot)
        // The load has resolved (head = model resident & responding; nil = it failed) — release its
        // pending reservation so a finished load isn't double-counted or left lingering until the TTL.
        await LoadManager.shared.releaseReservation(kind: engine.kind, model: routed.upstreamModel)
        guard let head else { return errorResponse(.badGateway, "Upstream request failed.") }
        // If the model wasn't resident before this request, the engine just JIT-loaded it to serve the
        // request — record it and refresh discovery (the proxy path otherwise never logs on-demand
        // loads; explicit/UI loads log + invalidate themselves). Gate on a 2xx: a 4xx/5xx means the
        // load/serve failed, so it's neither a "loaded" event nor a discovery change — and invalidating
        // also stops a second rapid request from re-reading `wasLoaded` stale and double-logging.
        // Eviction is logged separately as "Auto-evicted", and manual "Unloaded".
        if !wasLoaded, (200..<300).contains(head.statusCode) {
            EventLog.model("\(engine.kind.token) loaded \(routed.upstreamModel)",
                           seconds: Date().timeIntervalSince(loadStart))
            await DiscoveryCache.shared.invalidate()
        }
        var headers = HTTPFields()
        headers[.contentType] = head.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        return Response(status: .init(code: head.statusCode),
                        headers: headers,
                        body: ResponseBody(asyncSequence: stream))
    }

    static let streamHighWater = 256 * 1024
    static let streamLowWater = 64 * 1024
    static let maxRequestBytes = 64 * 1024 * 1024   // forwarded-body collect cap (generous for multi-image vision)

    // Bridge URLSession's chunked delegate callbacks to a back-pressured body. Awaits the response
    // head (or nil if the connection failed before one), then streams Data chunks as the OS delivers
    // them — no per-byte iteration. FlowControl suspends the upstream task when the client falls
    // behind (bounding buffered memory) and resumes it as chunks are drained. Cancels upstream if the
    // client disconnects.
    static func streamUpstream(_ request: URLRequest, onComplete: (@Sendable () -> Void)? = nil) async -> (head: HTTPURLResponse?, body: BackpressuredBody) {
        let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()
        let flow = FlowControl(high: streamHighWater, low: streamLowWater)
        let head: HTTPURLResponse? = await withCheckedContinuation { (headCont: CheckedContinuation<HTTPURLResponse?, Never>) in
            let box = HeadResumeBox(headCont)
            let delegate = UpstreamStream(
                onResponse: { box.resume($0) },
                onChunk: { d in
                    ProxyStats.shared.addBytes(d.count)
                    flow.produced(d.count)
                    continuation.yield(ByteBuffer(bytes: d))
                },
                onFinish: { box.resume(nil); continuation.finish() }   // finish before a head → nil
            )
            let task = delegate.makeTask(request)
            flow.bind(onSuspend: { task.suspend() }, onResume: { task.resume() })
            continuation.onTermination = { _ in task.cancel(); onComplete?() }
            task.resume()   // bind back-pressure first, then start — so no chunk can arrive before the bind
        }
        return (head, BackpressuredBody(upstream: stream, flow: flow))
    }

    static func errorResponse(_ status: HTTPResponse.Status, _ message: String) -> Response {
        jsonErrorResponse(status, message: message, type: "invalid_request_error")
    }

    // OpenAI-style error object, with optional extra fields (e.g. memory numbers). Proper escaping
    // via JSONSerialization.
    static func jsonErrorResponse(_ status: HTTPResponse.Status, message: String, type: String,
                                  extra: [String: Any] = [:]) -> Response {
        var err: [String: Any] = ["message": message, "type": type]
        for (k, v) in extra { err[k] = v }
        let data = (try? JSONSerialization.data(withJSONObject: ["error": err]))
            ?? Data(#"{"error":{"message":"error","type":"server_error"}}"#.utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    static func jsonObjectResponse(_ obj: [String: Any]) -> Response {
        jsonResponse((try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8))
    }

    // MARK: native load / unload — POST /api/v1/models/{load,unload}

    // Body: { "model": "<qualified or bare id>", "force": <bool?> }. Load enforces the memory gate
    // (unless `force`); unload is never gated. Both are idempotent and return the updated catalog row.
    static func loadUnload(_ request: Request, load: Bool) async -> Response {
        // Refuse model control to anonymous LAN peers (network-exposed without a key) — they could
        // otherwise exhaust RAM or drive compute. The chat proxy stays open; only control is gated.
        guard adminAllowed(host: endpointHost, key: endpointKey) else {
            return errorResponse(.forbidden, "Model load/unload requires an API key when the server is bound to 0.0.0.0. Set one in Settings → Server.")
        }
        let body: ByteBuffer
        do { body = try await request.body.collect(upTo: 1024 * 1024) }
        catch { return errorResponse(.badRequest, "Could not read request body.") }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body.readableBytesView)) as? [String: Any],
              let requested = obj["model"] as? String, !requested.isEmpty else {
            return errorResponse(.badRequest, "Missing 'model' in request body.")
        }
        let force = (obj["force"] as? Bool) ?? false

        let states = await DiscoveryCache.shared.current()
        let index = buildIndex(states.map { (kind: $0.kind, models: $0.models.map(\.id)) })
        guard let (kind, localID) = resolve(requested, index: index),
              let row = states.first(where: { $0.kind == kind })?.models.first(where: { $0.id == localID }) else {
            return errorResponse(.notFound, "No loadable model '\(requested)'.")
        }

        let available = Int(SystemMemory.availableBytes)
        // Idempotent no-ops.
        if load == row.loaded { return jsonObjectResponse(nativeRow(row, kind: kind, availableBytes: available)) }
        let qualified = "\(kind.token)/\(localID)"
        // Admission gate (load only) — through the shared manager so the canLoad check isn't
        // duplicated. The explicit endpoint never auto-evicts (.refuseIfFull); `force` overrides.
        if load {
            // admit() logs the memory-math reasoning as an explanation; on refusal we additionally log
            // the event here and map it to the 409.
            let admitStart = Date()
            if case .insufficientMemory(let est, let avail) = await LoadManager.shared.admit(
                kind: kind, model: localID, force: force, policy: .refuseIfFull) {
                EventLog.model("Couldn't load \(qualified) — insufficient memory",
                               seconds: Date().timeIntervalSince(admitStart), ok: false)
                return memoryErrorResponse(model: requested, estimatedSizeBytes: est, availableBytes: avail)
            }
        }

        guard let client = EngineRegistry.live().first(where: { $0.kind == kind }) else {
            return errorResponse(.badGateway, "Engine for '\(requested)' is unavailable.")
        }
        let t0 = Date()
        let opError = load ? await client.load(localID) : await client.unload(localID)
        let secs = Date().timeIntervalSince(t0)
        if load { await LoadManager.shared.releaseReservation(kind: kind, model: localID) }   // load resolved
        if let opError {
            EventLog.model("Failed to \(load ? "load" : "unload") \(qualified)", detail: opError, seconds: secs, ok: false)
            // A non-controllable model (e.g. oMLX's MarkItDown) surfaces as the engine's "not found".
            let status: HTTPResponse.Status = isNotFound(opError) ? .notFound : .badGateway
            return errorResponse(status, opError)
        }
        EventLog.model("\(load ? "Loaded" : "Unloaded") \(qualified)", seconds: secs)
        await DiscoveryCache.shared.invalidate()   // so the next read reflects the new loaded state
        // Optimistic updated row — the engine confirmed the op, so we skip the discovery settle lag.
        let updated = ModelInfo(id: row.id, loaded: load, sizeBytes: row.sizeBytes,
                                contextLength: row.contextLength, estimatedSizeBytes: row.estimatedSizeBytes)
        return jsonObjectResponse(nativeRow(updated, kind: kind, availableBytes: Int(SystemMemory.availableBytes)))
    }

    // `status` is .conflict (409) for the explicit load endpoint and .serviceUnavailable (503) for
    // the proxy path that couldn't make room — both carry the same insufficient_memory error shape.
    static func memoryErrorResponse(_ status: HTTPResponse.Status = .conflict, model: String,
                                    estimatedSizeBytes: Int?, availableBytes: Int) -> Response {
        func gb(_ b: Int?) -> String { b.map { String(format: "%.1f GB", Double($0) / 1_073_741_824) } ?? "an unknown amount" }
        var extra: [String: Any] = ["available_bytes": availableBytes]
        if let est = estimatedSizeBytes { extra["estimated_size"] = est }
        return jsonErrorResponse(status,
                                 message: "\(model) needs ~\(gb(estimatedSizeBytes)) but only \(gb(availableBytes)) is free.",
                                 type: "insufficient_memory", extra: extra)
    }
}

// Requires `Authorization: Bearer <key>` when an endpoint API key is configured. Reads the key live
// per request (no restart needed on change); an empty key leaves the endpoint open.
struct APIKeyMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext

    func handle(_ request: Request, context: BasicRequestContext,
                next: (Request, BasicRequestContext) async throws -> Response) async throws -> Response {
        guard Proxy.isAuthorized(request.headers[.authorization], key: Proxy.endpointKey) else {
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let body = Data(#"{"error":{"message":"Invalid API key.","type":"invalid_request_error","code":"invalid_api_key"}}"#.utf8)
            return Response(status: .unauthorized, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: body)))
        }
        return try await next(request, context)
    }
}

// Short-lived cache over discoverAll() so bursts of model-list / forward requests don't each trigger
// a fresh 4-engine discovery. Concurrent refreshes coalesce onto one in-flight task. The single
// discovery source behind both model endpoints, routing, and (via ModelStore) the UI.
actor DiscoveryCache {
    static let shared = DiscoveryCache(discover: { await Proxy.discoverAll() })
    private let discover: @Sendable () async -> [EngineState]
    private let now: @Sendable () -> Date
    private var cached: [EngineState] = []
    private var lastBuilt = Date.distantPast
    private var generation = 0   // bumped by invalidate(); guards a stale in-flight result from re-caching
    private var inFlight: Task<[EngineState], Never>?
    private let ttl: TimeInterval

    // `discover` and `now` are injectable so the cache's coalescing/TTL-expiry can be unit-tested
    // without real I/O or wall-clock waits.
    init(discover: @escaping @Sendable () async -> [EngineState], ttl: TimeInterval = 2,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.discover = discover
        self.ttl = ttl
        self.now = now
    }

    func current() async -> [EngineState] {
        if now().timeIntervalSince(lastBuilt) <= ttl { return cached }
        if let inFlight { return await inFlight.value }
        let gen = generation                          // snapshot — an invalidate() during the await bumps it
        let task = Task { await self.discover() }
        inFlight = task
        let states = await task.value
        inFlight = nil
        // If an invalidate() landed while this discovery was in flight, the result reflects state from
        // *before* that change — don't let it re-stamp lastBuilt and mask the change until the TTL.
        // Leave lastBuilt stale so the next current() re-discovers; only cache an uninterrupted result.
        if generation == gen {
            cached = states
            lastBuilt = now()
        }
        return states
    }

    // Force the next `current()` to re-discover (e.g. right after a load/unload changes state). Bumps
    // the generation so a discovery already in flight can't re-cache the pre-change state.
    func invalidate() { lastBuilt = .distantPast; generation &+= 1 }
}

// URLSession delegate that bridges chunked response callbacks to closures, owning its session so the
// delegate retain is released when the task completes.
final class UpstreamStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onResponse: (HTTPURLResponse?) -> Void
    private let onChunk: (Data) -> Void
    private let onFinish: () -> Void
    private var session: URLSession?

    init(onResponse: @escaping (HTTPURLResponse?) -> Void,
         onChunk: @escaping (Data) -> Void,
         onFinish: @escaping () -> Void) {
        self.onResponse = onResponse
        self.onChunk = onChunk
        self.onFinish = onFinish
    }

    // Create the data task WITHOUT resuming, so the caller can wire back-pressure before any bytes
    // arrive (resuming here would let chunks land before FlowControl is bound — see streamUpstream).
    func makeTask(_ request: URLRequest) -> URLSessionDataTask {
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        return s.dataTask(with: request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        onResponse(response as? HTTPURLResponse)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onChunk(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onFinish()
        session.finishTasksAndInvalidate()   // drop the delegate retain
    }
}

// Resumes a head continuation exactly once (URLSession delegate callbacks arrive off-actor).
final class HeadResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<HTTPURLResponse?, Never>?
    init(_ c: CheckedContinuation<HTTPURLResponse?, Never>) { cont = c }
    func resume(_ value: HTTPURLResponse?) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: value)
    }
}

// Streaming back-pressure: tracks bytes produced upstream minus bytes drained downstream, and fires
// suspend/resume callbacks at high/low water marks so the upstream URLSession task is paused while
// the client is behind — bounding buffered memory instead of letting it grow unbounded. The
// suspend/resume edge is debounced (one suspend per high crossing, one resume per low crossing).
final class FlowControl: @unchecked Sendable {
    private let lock = NSLock()
    private var buffered = 0
    private var suspended = false
    private let high: Int
    private let low: Int
    private var onSuspend: (() -> Void)?
    private var onResume: (() -> Void)?

    init(high: Int, low: Int) { self.high = high; self.low = low }

    func bind(onSuspend: @escaping () -> Void, onResume: @escaping () -> Void) {
        lock.lock(); self.onSuspend = onSuspend; self.onResume = onResume; lock.unlock()
    }

    func produced(_ n: Int) {
        lock.lock()
        buffered += n
        let fire = !suspended && buffered >= high
        if fire { suspended = true }
        let cb = onSuspend
        lock.unlock()
        if fire { cb?() }
    }

    func consumed(_ n: Int) {
        lock.lock()
        buffered -= n
        let fire = suspended && buffered <= low
        if fire { suspended = false }
        let cb = onResume
        lock.unlock()
        if fire { cb?() }
    }
}

// A response body that decrements FlowControl as Hummingbird drains each chunk — the consumption
// signal that lets the upstream task be resumed once the client catches up.
struct BackpressuredBody: AsyncSequence, Sendable {
    typealias Element = ByteBuffer
    let upstream: AsyncStream<ByteBuffer>
    let flow: FlowControl

    func makeAsyncIterator() -> Iterator { Iterator(base: upstream.makeAsyncIterator(), flow: flow) }

    struct Iterator: AsyncIteratorProtocol {
        var base: AsyncStream<ByteBuffer>.Iterator
        let flow: FlowControl
        mutating func next() async -> ByteBuffer? {
            let chunk = await base.next()
            if let chunk { flow.consumed(chunk.readableBytes) }
            return chunk
        }
    }
}

// Request / byte counters surfaced in the Server pane's Statistics card.
final class ProxyStats: @unchecked Sendable {
    static let shared = ProxyStats()
    private let lock = NSLock()
    private var _requests = 0
    private var _bytes = 0

    func addRequest() { lock.lock(); _requests += 1; lock.unlock() }
    func addBytes(_ n: Int) { lock.lock(); _bytes += n; lock.unlock() }
    func reset()       { lock.lock(); _requests = 0; _bytes = 0; lock.unlock() }
    var requests: Int  { lock.lock(); defer { lock.unlock() }; return _requests }
    var bytes: Int     { lock.lock(); defer { lock.unlock() }; return _bytes }
}

// Bounds concurrent in-flight forwarded requests (enforced only on a network-exposed bind — see
// forward()). Caps the buffered-body + compute amplification an anonymous LAN peer could otherwise
// drive. NSLock-guarded (like ProxyStats) so acquire/release are synchronous — no Task needed at the
// call sites, including the streaming onComplete release.
final class InFlightLimiter: @unchecked Sendable {
    static let shared = InFlightLimiter()
    private let lock = NSLock()
    private var count = 0
    private let limit: Int
    init(limit: Int = 32) { self.limit = limit }

    // Take a slot, or false when the cap is already reached (caller should 503).
    func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count < limit else { return false }
        count += 1
        return true
    }
    func release() { lock.lock(); defer { lock.unlock() }; if count > 0 { count -= 1 } }
}

// Counts authorized requests that reach the router (added after the auth middleware).
struct CountingMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext
    func handle(_ request: Request, context: BasicRequestContext,
                next: (Request, BasicRequestContext) async throws -> Response) async throws -> Response {
        ProxyStats.shared.addRequest()
        return try await next(request, context)
    }
}
