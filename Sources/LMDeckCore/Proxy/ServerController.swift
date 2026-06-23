import Foundation
import Hummingbird

// LMDeck's local HTTP server (Hummingbird). Serves one OpenAI-compatible /v1 endpoint:
// aggregated GET /v1/models now; the model-routing streaming forwarder comes next.
//
// Start / Stop / Restart are atomic from the UI's view: `isBusy` is set when one begins
// and cleared after it completes plus a short cool-down, so the UI disables every button
// until then. Restart chains through the run-task's completion (no port race).
@MainActor
public final class ServerController: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running(host: String, port: UInt16)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var isBusy = false
    @Published private(set) var requestCount = 0
    @Published private(set) var bytesIn = 0
    // Last start/bind failure (e.g. "port 5678 in use"), surfaced in the Server pane; cleared on a
    // new start or a successful bind.
    @Published private(set) var lastError: String?

    private var serverTask: Task<Void, Never>?
    private var pendingRestart = false
    // Activity log: when the current start/stop/restart began, and which verb to report when it
    // settles (reaches running, or stops).
    private var actionStart: Date?
    private var actionVerb: String?
    // Activity-log sink — injectable so unit tests don't write to the real log file.
    private let logEvent: @Sendable (String, TimeInterval, Bool) -> Void
    // Bumped on each beginServe; markRunning/serverEnded ignore callbacks from a superseded task,
    // so a late "server is running" hop can't flip a stopped/restarted server back to .running.
    private var generation = 0
    // A separate token for the busy/cooldown window (stop() deliberately doesn't bump `generation`,
    // which is tied to the serve task): bumped whenever a user action takes the busy flag, so a stale
    // cooldown timer from a prior action can't clear isBusy after a newer action has set it.
    private var busyGeneration = 0
    private static let cooldownNanos: UInt64 = 100_000_000   // 100ms

#if DEBUG
    // Test seam: replaces the real Hummingbird serve. Receives the "now running" callback to invoke
    // when bound, and should run until its task is cancelled. Lets unit tests drive the state machine
    // without binding a real port.
    var serveOverride: ((@escaping @Sendable () -> Void) async -> Void)?
#endif

    public init(logEvent: @escaping @Sendable (String, TimeInterval, Bool) -> Void = { EventLog.server($0, seconds: $1, ok: $2) }) {
        self.logEvent = logEvent
        // Start the local server automatically when the app launches.
        Task { @MainActor in self.start() }
        // Surface the proxy's request/byte counters in the Statistics card.
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Only mirror the counters while running; idle slower when stopped so a windowless
                // background daemon isn't waking every second to re-read values that can't change.
                if case .running = self.state {
                    let r = ProxyStats.shared.requests, b = ProxyStats.shared.bytes
                    if r != self.requestCount { self.requestCount = r }
                    if b != self.bytesIn { self.bytesIn = b }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

#if DEBUG
    /// Inert instance for SwiftUI previews — no server bind, no auto-start/poll.
    init(previewState: State) { self.logEvent = { _, _, _ in }; self.state = previewState }
#endif

    var statusTitle: String {
        switch state {
        case .stopped:               return "Server is stopped"
        case .starting:              return "Server is starting…"
        case .running(let h, let p): return "Server is running on \(Net.displayHost(h)):\(p)"
        }
    }

    var menuStatus: String {
        switch state {
        case .stopped:        return "Server stopped"
        case .starting:       return "Server: starting…"
        case .running:        return "Server running"
        }
    }

    var bytesFormatted: String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(bytesIn))
    }

    private var configuredPort: UInt16 {
        Net.boundPort(UserDefaults.standard.integer(forKey: SettingsKeys.endpointPort), default: 5678)
    }

    private var configuredHost: String {
        Net.host(UserDefaults.standard.string(forKey: SettingsKeys.endpointHost) ?? "")
    }

    func toggle() {
        switch state {
        case .stopped:           start()
        case .running, .starting: stop()
        }
    }

    func start() {
        guard !isBusy, case .stopped = state else { return }
        isBusy = true
        state = .starting
        lastError = nil
        actionStart = Date(); actionVerb = "started"
        ProxyStats.shared.reset()      // fresh stats per server session
        beginServe()
    }

    // Stop also cancels a stuck/slow *start* (a failing bind sits in .starting), so the UI is never
    // stranded, and preempts the post-start cooldown — a deliberate Stop in that 100 ms window isn't
    // dropped. (Cancelling an already-cancelled task is harmless, so a repeated Stop is a no-op.)
    func stop() {
        switch state {
        case .stopped:            return
        case .running, .starting:
            isBusy = true; busyGeneration &+= 1
            pendingRestart = false
            actionStart = Date(); actionVerb = "stopped"
            if let t = serverTask {
                t.cancel()         // runService returns → serverEnded → stopped
            } else {
                state = .stopped
                logServerSettled(ok: true)
                finishBusy()
            }
        }
    }

    func restart() {
        switch state {
        case .stopped:            start()
        case .running where isBusy: return
        case .running, .starting:
            isBusy = true; busyGeneration &+= 1
            pendingRestart = true
            state = .starting
            actionStart = Date(); actionVerb = "restarted"
            if let t = serverTask {
                t.cancel()         // serverEnded sees pendingRestart → fresh server
            } else {
                pendingRestart = false
                beginServe()
            }
        }
    }

    private func beginServe() {
        generation &+= 1
        let gen = generation
        let port = configuredPort
        let bindHost = configuredHost
        let onRunning: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.markRunning(gen: gen, host: bindHost, port: port) }
        }
#if DEBUG
        if let serveOverride {
            serverTask = Task { [weak self] in
                await serveOverride(onRunning)
                await MainActor.run { self?.serverEnded(gen: gen) }
            }
            return
        }
#endif
        let router = Proxy.router()
        serverTask = Task { [weak self] in
            // Binding can briefly lose a port race (e.g. relaunch before the previous instance
            // frees the port). Retry a few times before giving up so startup is reliable.
            var attempt = 0
            var bindError: String?
            while !Task.isCancelled {
                let app = Application(
                    router: router,
                    configuration: .init(address: .hostname(bindHost, port: Int(port))),
                    onServerRunning: { _ in onRunning() }
                )
                do {
                    try await app.runService()
                    bindError = nil                  // bound (and later shut down) cleanly
                    break                            // clean shutdown (Stop/Restart cancelled it)
                } catch {
                    if Task.isCancelled { break }
                    attempt += 1
                    bindError = error.localizedDescription
                    if attempt >= 6 { break }         // ~1.25s of retries, then give up → stopped
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            let err = bindError
            await MainActor.run { self?.serverEnded(gen: gen, error: err) }
        }
    }

    // Ignore a running-confirmation from a superseded start, or one that raced past a stop.
    @MainActor private func markRunning(gen: Int, host: String, port: UInt16) {
        guard gen == generation, case .starting = state else { return }
        state = .running(host: host, port: port)
        lastError = nil
        logServerSettled(ok: true)
        finishBusy()
    }

    @MainActor private func serverEnded(gen: Int, error: String? = nil) {
        guard gen == generation else { return }   // a newer start/restart owns the state now
        serverTask = nil
        if pendingRestart {
            pendingRestart = false
            state = .starting
            beginServe()
        } else {
            if let error { lastError = "Couldn't start on port \(configuredPort): \(error)" }
            state = .stopped
            logServerSettled(ok: actionVerb == "stopped")   // "stopped" vs. a start that never bound
            finishBusy()
        }
    }

    // Emit one activity-log entry for the start/stop/restart that just settled, with elapsed time.
    private func logServerSettled(ok: Bool) {
        guard let verb = actionVerb, let start = actionStart else { return }
        let title = (!ok && verb != "stopped") ? "Server failed to start" : "Server \(verb)"
        logEvent(title, Date().timeIntervalSince(start), ok)
        actionVerb = nil; actionStart = nil
    }

    // End the busy window after a short cool-down so the buttons can't be re-hit instantly.
    private func finishBusy() {
        let bg = busyGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.cooldownNanos)
            guard bg == self.busyGeneration else { return }   // a newer action owns the busy window now
            self.isBusy = false
        }
    }
}
