import Testing
@testable import LMDeckCore

// The running/stopped transitions hop through detached @MainActor tasks, so tests poll for the
// expected state (with a generous timeout) rather than assuming synchronous transitions. A serve
// override stands in for the real Hummingbird bind.
@MainActor
struct ServerControllerTests {

    private func wait(_ sc: ServerController, _ cond: @escaping (ServerController.State) -> Bool) async -> Bool {
        for _ in 0..<200 {                       // up to ~2s
            if cond(sc.state) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond(sc.state)
    }
    private func isRunning(_ s: ServerController.State) -> Bool { if case .running = s { return true }; return false }
    private func isStarting(_ s: ServerController.State) -> Bool { if case .starting = s { return true }; return false }
    private func isStopped(_ s: ServerController.State) -> Bool { if case .stopped = s { return true }; return false }

    @Test func startReachesRunningThenStopReachesStopped() async {
        let sc = ServerController(previewState: .stopped)
        sc.serveOverride = { onRunning in
            onRunning()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        sc.start()
        #expect(await wait(sc, isRunning))
        sc.stop()                    // stop preempts the post-start cooldown (no waiting for isBusy)
        #expect(await wait(sc, isStopped))
    }

    // C1: a serve that never signals "running" (a stuck/failing bind) must still be stoppable.
    @Test func stopCancelsAStuckStart() async {
        let sc = ServerController(previewState: .stopped)
        sc.serveOverride = { _ in while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) } }
        sc.start()
        #expect(await wait(sc, isStarting))
        sc.stop()
        #expect(await wait(sc, isStopped))
    }

    // C2: a "now running" callback from a superseded start must not flip a stopped server back.
    @Test func staleMarkRunningIsIgnoredAfterStop() async {
        let sc = ServerController(previewState: .stopped)
        sc.serveOverride = { onRunning in
            try? await Task.sleep(nanoseconds: 50_000_000)   // signal running only after we've stopped
            onRunning()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        sc.start()
        #expect(await wait(sc, isStarting))
        sc.stop()
        #expect(await wait(sc, isStopped))
        try? await Task.sleep(nanoseconds: 120_000_000)      // let the delayed callback fire
        #expect(isStopped(sc.state))                         // must remain stopped
    }
}
