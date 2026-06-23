import Testing
@testable import LMDeckCore

struct NetTests {
    @Test func portFallsBackWhenUnset() {
        #expect(Net.port(0, default: 5678) == 5678)
        #expect(Net.port(1234, default: 5678) == 1234)
    }

    @Test func boundPortClampsAndDefaults() {
        #expect(Net.boundPort(0, default: 5678) == 5678)    // unset → default
        #expect(Net.boundPort(1234, default: 5678) == 1234)
        #expect(Net.boundPort(70000, default: 5678) == 65535) // above range → clamped
        #expect(Net.boundPort(-5, default: 5678) == 1)        // below range → clamped to 1
    }

    @Test func hostDefaultsToLoopback() {
        #expect(Net.host("") == "127.0.0.1")
        #expect(Net.host("0.0.0.0") == "0.0.0.0")
        #expect(Net.host("192.168.1.10") == "192.168.1.10")
    }

    @Test func displayHostFriendlyLoopback() {
        #expect(Net.displayHost("127.0.0.1") == "localhost")
        #expect(Net.displayHost("0.0.0.0") == "0.0.0.0")
    }
}
