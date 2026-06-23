import Testing
import Foundation
@testable import LMDeckCore

// Per-engine enable/disable plumbing: the enum's enabledKey must line up with the registered
// SettingsKeys (a token rename would silently break the switch), and the registry must honour it.
struct EngineRegistryTests {

    @Test func enabledKeyMatchesSettingsKeys() {
        let expected: [EngineKind: String] = [
            .ollama: SettingsKeys.ollamaEnabled,
            .omlx: SettingsKeys.omlxEnabled,
            .lmstudio: SettingsKeys.lmstudioEnabled,
            .llamaswap: SettingsKeys.llamaswapEnabled,
        ]
        for kind in EngineKind.allCases {
            #expect(kind.enabledKey == expected[kind])
        }
    }

    // A disabled engine drops out of configs()/live() but stays in allConfigs()/allClients()
    // (so first-run auto-detect can still probe everything).
    @Test func disabledEngineExcludedFromLiveButNotAll() {
        let defaults = UserDefaults.standard
        let key = EngineKind.llamaswap.enabledKey
        let saved = defaults.object(forKey: key)
        defer { saved == nil ? defaults.removeObject(forKey: key) : defaults.set(saved, forKey: key) }

        defaults.set(true, forKey: key)
        #expect(EngineRegistry.configs().contains { $0.kind == .llamaswap })

        defaults.set(false, forKey: key)
        #expect(!EngineRegistry.configs().contains { $0.kind == .llamaswap })
        #expect(EngineRegistry.allConfigs().contains { $0.kind == .llamaswap })
    }
}
