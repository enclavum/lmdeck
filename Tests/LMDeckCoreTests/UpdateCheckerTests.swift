import Testing
@testable import LMDeckCore

struct UpdateCheckerTests {
    @Test func isNewerComparesSemanticVersionsNumerically() {
        #expect(UpdateChecker.isNewer("1.2.0", than: "1.1.0"))
        #expect(UpdateChecker.isNewer("v1.2.0", than: "1.1.9"))   // tolerates a leading "v"
        #expect(UpdateChecker.isNewer("1.10.0", than: "1.9.0"))   // numeric, not lexical (10 > 9)
        #expect(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
        #expect(UpdateChecker.isNewer("1.2.1", than: "1.2"))      // 1.2.1 > 1.2(.0)
    }

    @Test func isNewerFalseForSameOrOlder() {
        #expect(!UpdateChecker.isNewer("1.2.0", than: "1.2.0"))   // equal
        #expect(!UpdateChecker.isNewer("1.2", than: "1.2.0"))     // 1.2 == 1.2.0
        #expect(!UpdateChecker.isNewer("1.1.0", than: "1.2.0"))   // older
        #expect(!UpdateChecker.isNewer("v1.0.0", than: "v1.0.0"))
    }
}
