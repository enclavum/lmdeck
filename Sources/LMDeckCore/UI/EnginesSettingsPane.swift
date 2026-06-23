import SwiftUI

struct EnginesSettingsPane: View {
    @AppStorage(SettingsKeys.ollamaPort) private var ollamaPort = 11434
    @AppStorage(SettingsKeys.omlxPort) private var omlxPort = 8000
    @AppStorage(SettingsKeys.lmstudioPort) private var lmsPort = 1234
    @AppStorage(SettingsKeys.llamaswapPort) private var lsPort = 8080
    // Per-engine on/off. A disabled engine is dropped from discovery and the proxy entirely
    // (EngineRegistry.live filters on these); seeded once by first-run auto-detect.
    @AppStorage(SettingsKeys.ollamaEnabled) private var ollamaEnabled = true
    @AppStorage(SettingsKeys.omlxEnabled) private var omlxEnabled = true
    @AppStorage(SettingsKeys.lmstudioEnabled) private var lmstudioEnabled = true
    @AppStorage(SettingsKeys.llamaswapEnabled) private var llamaswapEnabled = true
    @EnvironmentObject private var store: ModelStore
    @EnvironmentObject private var secrets: SecretsModel
    @State private var autoConfiguring = false
    @State private var showAutoConfigDone = false
    @State private var autoConfigResult: [EngineKind] = []

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-configure")
                        Text("Detect each engine's port and API key from its settings, this app's environment, or its launch arguments.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button(autoConfiguring ? "Configuring…" : "Auto configure") { runAutoConfigure() }
                        .buttonStyle(.borderedProminent)
                        .disabled(autoConfiguring)
                }
                .padding(.vertical, 2)
            }

            engineSection("Ollama", .ollama, enabled: $ollamaEnabled) {
                portRow($ollamaPort)
            }
            engineSection("oMLX", .omlx, enabled: $omlxEnabled) {
                portRow($omlxPort)
                keyRow($secrets.omlxKey, kind: .omlx)
            }
            engineSection("LM Studio", .lmstudio, enabled: $lmstudioEnabled) {
                portRow($lmsPort)
                keyRow($secrets.lmstudioKey, kind: .lmstudio)
            }
            engineSection("llama-swap", .llamaswap, enabled: $llamaswapEnabled) {
                portRow($lsPort)
                keyRow($secrets.llamaswapKey, kind: .llamaswap)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Engines")
        .alert("Auto-configure complete", isPresented: $showAutoConfigDone) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(autoConfigMessage)
        }
    }

    // One Section per engine: header = name + reachability dot; an Enabled switch, then the (dimmed
    // when off) port/key rows. Toggling Enabled triggers an immediate re-discover so the rest of the
    // UI and the status dot reflect the change without waiting for the next poll.
    @ViewBuilder private func engineSection<C: View>(
        _ name: String, _ kind: EngineKind, enabled: Binding<Bool>, @ViewBuilder _ config: () -> C
    ) -> some View {
        Section {
            Toggle("Enabled", isOn: Binding(get: { enabled.wrappedValue },
                                            set: { enabled.wrappedValue = $0; Task { await store.refreshNow() } }))
            Group { config() }
                .disabled(!enabled.wrappedValue)
        } header: {
            HStack(spacing: 6) {
                Text(name)
                statusDot(kind)
            }
        }
    }

    // Best-effort, read-only detection of each engine's port + API key from its settings file / this
    // app's env / its launch args (see EngineAutoConfig). Overwrites the current values; runs only on
    // click, re-probes so the dots update, then confirms with an alert.
    private func runAutoConfigure() {
        autoConfiguring = true
        let before = store.engineStatus
        Task {
            await EngineAutoConfig.apply(to: secrets)
            await store.refreshNow()
            // Report which engines went green (became reachable) as a result of this run.
            autoConfigResult = EngineKind.allCases.filter { store.engineStatus[$0] == .ok && before[$0] != .ok }
            autoConfiguring = false
            showAutoConfigDone = true
        }
    }

    private var autoConfigMessage: String {
        guard !autoConfigResult.isEmpty else {
            return "No new engines became reachable. Make sure the engines you want are running, then run it again."
        }
        let names = autoConfigResult.map(displayName).joined(separator: ", ")
        return "Detected settings and connected: \(names)."
    }

    private func displayName(_ kind: EngineKind) -> String {
        switch kind {
        case .ollama:    return "Ollama"
        case .omlx:      return "oMLX"
        case .lmstudio:  return "LM Studio"
        case .llamaswap: return "llama-swap"
        }
    }

    private func portRow(_ value: Binding<Int>) -> some View {
        HStack {
            Text("Port")
            Spacer(minLength: 10)
            TextField("", value: value, format: .number.grouping(.never))
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, design: .monospaced))
                .compactField(width: 90)
        }
    }

    private func keyRow(_ value: Binding<String>, kind: EngineKind) -> some View {
        HStack {
            Text("API key")
            Spacer(minLength: 10)
            // Red sign when the engine answered but rejected this key (401/403).
            if store.engineStatus[kind] == .unauthorized {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .help("This engine rejected the API key. Check the key and try again.")
            }
            SecureField("", text: value)
                .compactField(width: 200)
        }
    }

    private func statusDot(_ kind: EngineKind) -> AnyView {
        AnyView(EngineStatusDot(status: store.engineStatus[kind]))
    }
}

// Next to an engine name: green check when reachable, red dot when it rejected the key, gray dot when
// unreachable. Nothing when the engine is disabled (no status to show).
private struct EngineStatusDot: View {
    let status: EngineStatus?
    var body: some View {
        if let status {
            Image(systemName: status == .ok ? "checkmark.circle.fill" : "circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(color(status))
                .help(help(status))
        }
    }

    private func color(_ s: EngineStatus) -> Color {
        switch s {
        case .ok:           return Color(nsColor: .systemGreen)
        case .unauthorized: return Color(nsColor: .systemRed)
        case .unreachable:  return Color(nsColor: .quaternaryLabelColor)
        }
    }
    private func help(_ s: EngineStatus) -> String {
        switch s {
        case .ok:           return "Reachable"
        case .unauthorized: return "API key rejected"
        case .unreachable:  return "Not reachable"
        }
    }
}

#if DEBUG
struct EnginesSettingsPane_Previews: PreviewProvider {
    static var previews: some View {
        EnginesSettingsPane()
            .environmentObject(ModelStore.preview)
            .environmentObject(SecretsModel())
            .frame(width: 640, height: 620)
    }
}
#endif
