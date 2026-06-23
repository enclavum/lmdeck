import SwiftUI
import AppKit

struct ServerSettingsPane: View {
    @EnvironmentObject private var server: ServerController
    @AppStorage(SettingsKeys.endpointPort) private var port = 5678
    @AppStorage(SettingsKeys.endpointHost) private var host = "127.0.0.1"
    @AppStorage(SettingsKeys.autoEvict) private var autoEvict = true
    @EnvironmentObject private var secrets: SecretsModel
    // Seed from the real system state so the toggle shows the right value on first render (no off→on
    // flip when the pane appears). Re-synced on appear too, for changes made outside the app.
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.statusTitle)
                        Text(subtitle).font(.system(size: 11))
                            .foregroundStyle(server.lastError != nil ? Color(nsColor: .systemRed) : .secondary)
                    }
                    Spacer(minLength: 10)
                    controls
                }
                .padding(.vertical, 4)
            }

            Section {
                // Driven by @State (not a live SMAppService read), so a re-render on focus change can't
                // flip it; we re-sync from the system only on appear and right after a toggle.
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { LaunchAtLogin.setEnabled($0); launchAtLogin = LaunchAtLogin.isEnabled }))
                    .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
            } header: {
                Text("Startup")
            } footer: {
                Text("Open LMDeck automatically when you log in, so the endpoint keeps running across restarts.")
            }

            Section {
                HStack {
                    Text("Host")
                    Spacer(minLength: 10)
                    Picker("", selection: $host) {
                        Text("Local (127.0.0.1)").tag("127.0.0.1")
                        Text("Network (0.0.0.0)").tag("0.0.0.0")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack {
                    Text("Port")
                    Spacer(minLength: 10)
                    TextField("", value: $port, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 12, design: .monospaced))
                        .compactField(width: 90)
                }
            } header: {
                Text("Endpoint")
            } footer: {
                Text("Other apps connect to http://localhost:\(Net.boundPort(port, default: 5678))/v1")
            }

            Section {
                HStack {
                    Text("API key")
                    Spacer(minLength: 10)
                    SecureField("", text: $secrets.endpointKey)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 12, design: .monospaced))
                        .compactField(width: 220)
                }
            } header: {
                Text("Security")
            } footer: {
                footerText(securityFooter)
            }

            Section {
                Toggle("Auto-evict models on requests", isOn: $autoEvict)
            } header: {
                Text("Memory")
            } footer: {
                footerText(memoryFooter)
            }

            Section("Statistics") {
                LabeledContent("Requests") {
                    Text("\(server.requestCount)").foregroundStyle(.secondary).monospacedDigit()
                }
                LabeledContent("Streamed from engines") {
                    Text(server.bytesFormatted).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Server")
    }

    // Footer that renders **bold** markdown (Memory/Security), falling back to plain text.
    private func footerText(_ s: String) -> Text {
        (try? AttributedString(markdown: s)).map(Text.init) ?? Text(s)
    }

    private var statusColor: Color {
        switch server.state {
        case .running:  return Color(nsColor: .systemGreen)
        case .starting: return Color(nsColor: .systemOrange)
        case .stopped:  return Color(nsColor: .tertiaryLabelColor)
        }
    }

    private var subtitle: String {
        if case .running(let h, _) = server.state {
            return h == "0.0.0.0"
                ? "Accepting API requests on your local network."
                : "Accepting local API requests."
        }
        if let err = server.lastError { return err }
        return "Start the server to accept requests."
    }

    private var memoryFooter: String {
        let base = autoEvict
            ? "When an **API request** is sent to a model that is not loaded, and the model won't fit memory, LMDeck will unload the least recently used **unpinned** model to make room."
            : "Off — when a model that's not loaded won't fit memory, the request is refused instead of unloading other models."
        return base + " **Only applies to requests; an explicit load is refused rather than evicting.**"
    }

    private var securityFooter: String {
        let key = secrets.endpointKey.trimmingCharacters(in: .whitespaces)
        if host == "0.0.0.0" && key.isEmpty {
            return "⚠️ Reachable on your network with no authentication — chat requests are open, but model load/unload is blocked until you set a key. Set one to require a Bearer token and re-enable control."
        }
        if key.isEmpty {
            return "Leave empty for no authentication. Set a key to require it on every request."
        }
        return "Clients must send Authorization: Bearer <your key> on every request."
    }

    @ViewBuilder private var controls: some View {
        switch server.state {
        case .stopped:
            Button { server.start() } label: { Label("Start", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(server.isBusy)
        case .starting, .running:
            Button { server.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                .disabled(server.isBusy)
            Button { server.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .tint(Color(nsColor: .systemRed))
                .disabled(server.isBusy)
        }
    }
}

#if DEBUG
struct ServerSettingsPane_Previews: PreviewProvider {
    static var previews: some View {
        ServerSettingsPane()
            .environmentObject(ServerController(previewState: .running(host: "127.0.0.1", port: 5678)))
            .environmentObject(SecretsModel())
            .frame(width: 640, height: 560)
    }
}
#endif
