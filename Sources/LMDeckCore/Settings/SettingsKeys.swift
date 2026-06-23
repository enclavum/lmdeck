import Foundation

// Shared UserDefaults keys (read by ModelStore / ServerController / Proxy, written by @AppStorage).
enum SettingsKeys {
    // engines
    static let ollamaPort = "ollamaPort"
    static let ollamaKey = "ollamaKey"
    static let omlxPort = "omlxPort"
    static let omlxKey = "omlxKey"
    static let lmstudioPort = "lmstudioPort"
    static let lmstudioKey = "lmstudioKey"
    static let llamaswapPort = "llamaswapPort"
    static let llamaswapKey = "llamaswapKey"
    // per-engine enable/disable (seeded once by first-run auto-detect)
    static let ollamaEnabled = "ollamaEnabled"
    static let omlxEnabled = "omlxEnabled"
    static let lmstudioEnabled = "lmstudioEnabled"
    static let llamaswapEnabled = "llamaswapEnabled"
    static let enginesAutoDetected = "enginesAutoDetected"
    // server
    static let endpointPort = "endpointPort"
    static let endpointHost = "endpointHost"
    static let endpointKey = "endpointKey"
    static let refreshInterval = "refreshInterval"
    // memory / load manager
    static let autoEvict = "autoEvict"        // silently evict LRU-unpinned models to fit API requests
    static let pinnedModels = "pinnedModels"  // [String] of qualified ids the user protects from eviction
    // updates
    static let autoCheckUpdates = "autoCheckUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"
}

// Registers the app's UserDefaults defaults (called from @main at launch).
public enum LMDeckDefaults {
    public static func register() {
        UserDefaults.standard.register(defaults: [
            SettingsKeys.ollamaPort: 11434,
            SettingsKeys.omlxPort: 8000,
            SettingsKeys.lmstudioPort: 1234,
            SettingsKeys.llamaswapPort: 8080,
            SettingsKeys.endpointPort: 5678,
            SettingsKeys.endpointHost: "127.0.0.1",
            SettingsKeys.refreshInterval: 5,
            SettingsKeys.autoEvict: true,
            SettingsKeys.ollamaEnabled: true,
            SettingsKeys.omlxEnabled: true,
            SettingsKeys.lmstudioEnabled: true,
            SettingsKeys.llamaswapEnabled: true,
            SettingsKeys.autoCheckUpdates: true,
            // AppKit's initial hover delay for `.help` tooltips, in ms (default is ~2–3s, too long).
            // App-wide, so it covers both the Settings window and the menu-bar popup.
            "NSInitialToolTipDelay": 1000
        ])
    }
}
