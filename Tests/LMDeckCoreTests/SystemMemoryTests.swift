import Testing
@testable import LMDeckCore

struct SystemMemoryTests {
    @Test func gbConversion() {
        #expect(abs(SystemMemory.gb(1_073_741_824) - 1.0) < 0.0001)
        #expect(SystemMemory.gb(0) == 0.0)
        #expect(abs(SystemMemory.gb(16 * 1_073_741_824) - 16.0) < 0.0001)
    }
}
