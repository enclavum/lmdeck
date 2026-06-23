import Testing
import Foundation
@testable import LMDeckCore

struct EngineAutoConfigTests {
    @Test func portFromListenParsesAndValidates() {
        #expect(EngineConfigReader.port(fromListen: ":8080") == 8080)
        #expect(EngineConfigReader.port(fromListen: "0.0.0.0:11434") == 11434)
        #expect(EngineConfigReader.port(fromListen: "8000") == 8000)
        #expect(EngineConfigReader.port(fromListen: "localhost: 1234 ") == 1234)   // trimmed
        #expect(EngineConfigReader.port(fromListen: "0") == nil)        // out of 1...65535
        #expect(EngineConfigReader.port(fromListen: "70000") == nil)
        #expect(EngineConfigReader.port(fromListen: "nope") == nil)
    }

    @Test func valueAfterFlagExtractsNextArg() {
        let args = ["/opt/homebrew/bin/llama-swap", "--config", "/x.yaml", "--listen", ":8080", "--api-key", "sk-1"]
        #expect(EngineConfigReader.value(after: "--listen", in: args) == ":8080")
        #expect(EngineConfigReader.value(after: "--api-key", in: args) == "sk-1")
        #expect(EngineConfigReader.value(after: "--config", in: args) == "/x.yaml")
        #expect(EngineConfigReader.value(after: "--missing", in: args) == nil)
        #expect(EngineConfigReader.value(after: "--api-key", in: ["--api-key"]) == nil)   // no following arg
    }

    @Test func firstYAMLListItemReadsFirstLiteralSkippingMacros() throws {
        let yaml = """
        healthCheckTimeout: 900
        apiKeys:
          # a comment
          - "${env.API_KEY_1}"
          - "sk-literal-key"
          - "sk-second"
        models:
          foo: {}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lmdeck-test-\(UUID()).yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(EngineConfigReader.firstYAMLListItem(under: "apiKeys", inFileAt: url.path) == "sk-literal-key")
        #expect(EngineConfigReader.firstYAMLListItem(under: "missing", inFileAt: url.path) == nil)
    }
}
