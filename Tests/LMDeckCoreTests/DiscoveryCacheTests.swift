import Testing
import Foundation
@testable import LMDeckCore

struct DiscoveryCacheTests {
    private actor Counter {
        private(set) var n = 0
        func bump() { n += 1 }
        func get() -> Int { n }
    }
    // Injectable clock so the TTL-expiry branch is testable without real waits.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t = Date(timeIntervalSince1970: 1000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
    }

    @Test func cachesWithinTTLAndReDiscoversOnInvalidate() async {
        let counter = Counter()
        let cache = DiscoveryCache(discover: { await counter.bump(); return [] }, ttl: 60)
        _ = await cache.current()
        _ = await cache.current()
        #expect(await counter.get() == 1)        // second call served from cache
        await cache.invalidate()
        _ = await cache.current()
        #expect(await counter.get() == 2)        // invalidate forces a re-discover
    }

    @Test func coalescesConcurrentRefreshes() async {
        let counter = Counter()
        let cache = DiscoveryCache(discover: {
            await counter.bump()
            try? await Task.sleep(nanoseconds: 50_000_000)   // hold the in-flight window open
            return []
        }, ttl: 60)
        async let a = cache.current()
        async let b = cache.current()
        _ = await a; _ = await b
        #expect(await counter.get() == 1)        // both shared a single in-flight discovery
    }

    @Test func reDiscoversAfterTTLExpires() async {
        let counter = Counter()
        let clock = Clock()
        let cache = DiscoveryCache(discover: { await counter.bump(); return [] }, ttl: 10, now: { clock.now() })
        _ = await cache.current()
        #expect(await counter.get() == 1)
        clock.advance(5)                         // still within the 10s TTL → served from cache
        _ = await cache.current()
        #expect(await counter.get() == 1)
        clock.advance(20)                        // now past the TTL → re-discover
        _ = await cache.current()
        #expect(await counter.get() == 2)
    }

    @Test func invalidateDuringDiscoveryForcesRebuild() async {
        // Regression (functional-review #3): an invalidate() that lands while a discovery is in flight
        // must not be lost. The in-flight result reflects pre-change state, so the next current() has to
        // re-discover rather than serve that stale result for the whole TTL. Simulated deterministically
        // by having the first discovery invalidate the cache mid-flight.
        final class Box: @unchecked Sendable { var cache: DiscoveryCache? }
        let box = Box()
        let counter = Counter()
        let cache = DiscoveryCache(discover: {
            let first = await counter.get() == 0
            await counter.bump()
            if first { await box.cache?.invalidate() }   // an invalidate lands during this in-flight build
            return []
        }, ttl: 60)
        box.cache = cache
        _ = await cache.current()        // 1st discovery invalidates itself mid-flight → result not cached
        _ = await cache.current()        // must re-discover (the invalidate wasn't masked by a re-stamp)
        #expect(await counter.get() == 2)
    }
}
