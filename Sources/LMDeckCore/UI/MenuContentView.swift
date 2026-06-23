import SwiftUI
import AppKit

// The menu-bar popover (.window style): the product's at-a-glance view — free RAM + everything
// loaded across all engines — plus server controls. It reads DiscoveryCache directly (not the
// Settings-scoped ModelStore), so the panel is live even when the Settings window is closed; the
// poll runs only while the panel is open (started on appear, cancelled on disappear).
public struct MenuContentView: View {
    @ObservedObject var server: ServerController
    @ObservedObject var ui: UIState
    @Environment(\.openWindow) private var openWindow

    @State private var engines: [EngineState] = []
    @State private var ramAvail: Double = 0
    @State private var ramTotal: Double = 0
    @State private var poll: Task<Void, Never>?
    private let live: Bool   // false → static preview/screenshot data; skip the live poll

    public init(server: ServerController, ui: UIState) {
        self._server = ObservedObject(wrappedValue: server)
        self._ui = ObservedObject(wrappedValue: ui)
        self.live = true
    }

    // Static-data initializer for SwiftUI previews / deterministic static rendering: seeds the panel
    // and skips the live poll.
    init(server: ServerController, ui: UIState, engines: [EngineState], ramAvail: Double, ramTotal: Double) {
        self._server = ObservedObject(wrappedValue: server)
        self._ui = ObservedObject(wrappedValue: ui)
        self._engines = State(initialValue: engines)
        self._ramAvail = State(initialValue: ramAvail)
        self._ramTotal = State(initialValue: ramTotal)
        self.live = false
    }

    private var usedFraction: Double { ramTotal > 0 ? max(0, ramTotal - ramAvail) / ramTotal : 0 }
    private var rows: [MenuModelRow] { MenuSummary.loadedRows(engines) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            memorySection
            Divider()
            loadedSection
            Divider()
            actionRow
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { if live { startPoll() } }
        .onDisappear { poll?.cancel(); poll = nil }
    }

    // MARK: sections

    private var header: some View {
        HStack(spacing: 8) {
            Text("LMDeck").font(.system(size: 13))
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                    .offset(y: 1)   // optically center the small dot against the text
                Text(endpointLabel)
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 0) {
                    Text(String(format: "%.1f GB free", ramAvail)).foregroundStyle(.primary)
                    Text(String(format: " / %.0f GB", ramTotal)).foregroundStyle(.tertiary)
                }
                .font(.system(size: 12)).monospacedDigit()
            }
            HStack(spacing: 8) {
                RamBar(fraction: usedFraction)
                Text("\(Int((usedFraction * 100).rounded()))%")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }

    private var loadedSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            if rows.isEmpty {
                Text("No models loaded")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 1)
            } else {
                Text("LOADED · \(rows.count)")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
                if rows.count > 6 {
                    // Cap the panel height once the list gets long; scroll the rest.
                    ScrollView { rowList }.frame(height: 196)
                } else {
                    rowList
                }
            }
        }
    }

    private var rowList: some View {
        VStack(spacing: 8) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Circle().fill(Color(nsColor: .systemGreen)).frame(width: 7, height: 7)
                        .offset(y: 1)   // match the header dot's optical centering
                    Text(row.model)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    HStack(spacing: 3) {   // engine label + size sit close together
                        Text(row.engine).font(.system(size: 11)).foregroundStyle(.tertiary)
                        if let bytes = row.sizeBytes {
                            Text(String(format: "%.1f GB", Double(bytes) / 1_073_741_824))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                .contentShape(Rectangle())
                .help(row.model)   // full model name on hover (the label truncates)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            MenuIconButton(symbol: "gearshape", help: "Settings") { open(.server) }
            Spacer()
            MenuIconButton(symbol: "power", help: "Quit LMDeck") { NSApplication.shared.terminate(nil) }
        }
    }

    // MARK: derived state

    private var endpointLabel: String {
        switch server.state {
        case .running(let host, let port): return "\(displayHost(host)):\(port)"
        case .starting:                    return "Starting…"
        case .stopped:                     return "Stopped"
        }
    }

    // Show loopback as "localhost"; a network-exposed bind (0.0.0.0 / a routable IP) shows verbatim.
    private func displayHost(_ host: String) -> String {
        Proxy.isLoopbackHost(host) ? "localhost" : host
    }

    private var statusColor: Color {
        switch server.state {
        case .running:  return Color(nsColor: .systemGreen)
        case .starting: return Color(nsColor: .systemOrange)
        case .stopped:  return Color(nsColor: .tertiaryLabelColor)
        }
    }

    // Live refresh while the panel is open: RAM + a fresh discovery (shared cache) every 2s.
    private func startPoll() {
        poll?.cancel()
        poll = Task { @MainActor in
            while !Task.isCancelled {
                let avail = SystemMemory.availableBytes
                ramAvail = SystemMemory.gb(avail)
                ramTotal = SystemMemory.gb(SystemMemory.totalBytes)
                engines = await DiscoveryCache.shared.current()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func open(_ section: SettingsSection) {
        ui.settingsSection = section
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

// One loaded model in the menu: which engine owns it and its on-disk size. `model` is the engine-
// local id; `id` qualifies it so the same model loaded under two engines stays distinct in the list.
struct MenuModelRow: Identifiable, Equatable {
    let model: String
    let engine: String
    let kind: EngineKind
    let sizeBytes: Int?
    var id: String { "\(kind.token)/\(model)" }
}

// Pure (unit-tested): flatten the loaded models across every engine, largest first (unknown size
// last), so the menu shows what's actually resident — biggest memory tenants on top.
enum MenuSummary {
    static func loadedRows(_ states: [EngineState]) -> [MenuModelRow] {
        let rows = states.flatMap { state in
            state.models.filter(\.loaded).map {
                MenuModelRow(model: $0.id, engine: state.name, kind: state.kind, sizeBytes: $0.sizeBytes)
            }
        }
        return rows.sorted { a, b in
            let sa = a.sizeBytes ?? -1, sb = b.sizeBytes ?? -1   // unknown sizes sort last
            return sa == sb ? a.model < b.model : sa > sb
        }
    }
}

// A compact, borderless icon button for the panel's action row (Settings / Quit).
private struct MenuIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hover ? Color.primary.opacity(0.08) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// Menu-bar icon. The glyph reflects the server state (dot = running, no dot = stopped). Also handles
// the optional `--settings` launch flag: an agent app suppresses windows at launch, so we open
// Settings explicitly here (the label is the only view that renders at launch) and activate it.
public struct MenuBarLabel: View {
    let openOnLaunch: Bool
    @ObservedObject var ui: UIState
    @ObservedObject var server: ServerController
    @Environment(\.openWindow) private var openWindow
    @State private var handled = false

    public init(openOnLaunch: Bool, ui: UIState, server: ServerController) {
        self.openOnLaunch = openOnLaunch
        self._ui = ObservedObject(wrappedValue: ui)
        self._server = ObservedObject(wrappedValue: server)
    }

    private var isStopped: Bool { if case .stopped = server.state { return true }; return false }

    public var body: some View {
        Image(nsImage: isStopped ? MenuBarIcon.stopped : MenuBarIcon.running)
            .onAppear {
                guard openOnLaunch, !handled else { return }
                handled = true
                DispatchQueue.main.async {
                    ui.settingsSection = .server
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}
