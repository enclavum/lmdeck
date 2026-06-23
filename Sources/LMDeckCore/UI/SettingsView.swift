import SwiftUI
import AppKit

// Native macOS settings window: a NavigationSplitView (system sidebar + grouped detail panes),
// styled like System Settings — it tracks light/dark + the accent colour automatically, has a sidebar
// search field that searches the actual settings (not just tab names), and colourful section icons.
// The sidebar selection is bound to UIState.settingsSection so the menu-bar popup's deep-links work.
public struct SettingsView: View {
    @EnvironmentObject private var ui: UIState
    @EnvironmentObject private var store: ModelStore
    @State private var search = ""
    // Back/forward history of visited panes (like System Settings' navigation arrows).
    @State private var history: [SettingsSection] = []
    @State private var historyIndex = -1
    @State private var navigatingViaHistory = false

    public init() {}

    private struct NavItem: Identifiable {
        let section: SettingsSection, title: String, symbol: String, color: Color
        var id: SettingsSection { section }
    }
    // Two groups → a visual separator between Engines and Logs.
    private let topItems: [NavItem] = [
        .init(section: .server,  title: "Server",  symbol: "server.rack",      color: .blue),
        .init(section: .models,  title: "Models",  symbol: "cube.transparent", color: .purple),
        .init(section: .engines, title: "Engines", symbol: "gearshape.2",      color: Color(red: 52.0 / 255, green: 203.0 / 255, blue: 88.0 / 255)),   // #34cb58
    ]
    private let bottomItems: [NavItem] = [
        .init(section: .logs,  title: "Logs",  symbol: "text.alignleft", color: .gray),
        .init(section: .about, title: "About", symbol: "info.circle",    color: Color(nsColor: .systemGray)),
    ]

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 215, ideal: 230, max: 260)
        } detail: {
            detail
                .padding(.top, -20)   // tighten the gap below the toolbar on every pane
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button { goBack() } label: { Image(systemName: "chevron.backward") }
                            .disabled(!canGoBack).help("Back")
                        Button { goForward() } label: { Image(systemName: "chevron.forward") }
                            .disabled(!canGoForward).help("Forward")
                    }
                }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task { await store.start() }
        .onChange(of: ui.settingsSection) { _, new in recordHistory(new) }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            setDockIcon()
            DispatchQueue.main.async {
                guard let w = NSApp.keyWindow else { return }
                w.makeFirstResponder(nil)            // don't auto-focus the first field
                w.titlebarSeparatorStyle = .none     // no intermittent hairline under the toolbar title
            }
            if history.isEmpty { history = [ui.settingsSection]; historyIndex = 0 }
        }
        .onDisappear {
            store.stop()   // stop polling discovery while the Settings window is closed
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: sidebar

    @ViewBuilder private var sidebar: some View {
        List(selection: selection) {
            if isSearching {
                searchResults
            } else {
                Section { ForEach(topItems) { navRow($0) } }
                Section { ForEach(bottomItems) { navRow($0) } }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .toolbar(removing: .sidebarToggle)
    }

    private func navRow(_ item: NavItem) -> some View {
        Label { Text(item.title) } icon: { SidebarIcon(symbol: item.symbol, color: item.color) }
            .tag(item.section)
    }

    @ViewBuilder private var searchResults: some View {
        let hits = results
        if hits.isEmpty {
            Text("No results").foregroundStyle(.secondary)
        } else {
            Section("Results") {
                ForEach(hits) { entry in
                    Button {
                        ui.settingsSection = entry.pane
                        search = ""
                    } label: {
                        HStack(spacing: 9) {
                            SidebarIcon(symbol: icon(for: entry.pane), color: color(for: entry.pane))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title).foregroundStyle(.primary)
                                Text(paneTitle(entry.pane))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // List single-selection wants an optional binding; settingsSection is non-optional (the popup sets
    // it directly), so bridge the two and ignore a nil (deselect can't happen in this fixed list).
    private var selection: Binding<SettingsSection?> {
        Binding(get: { ui.settingsSection }, set: { if let v = $0 { ui.settingsSection = v } })
    }

    // MARK: back/forward history

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex < history.count - 1 }

    private func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        navigatingViaHistory = true
        ui.settingsSection = history[historyIndex]
    }
    private func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        navigatingViaHistory = true
        ui.settingsSection = history[historyIndex]
    }
    // Record a user navigation (sidebar / search). Back/forward set navigatingViaHistory so their own
    // section change isn't re-recorded; re-selecting the current pane is a no-op.
    private func recordHistory(_ new: SettingsSection) {
        if navigatingViaHistory { navigatingViaHistory = false; return }
        if historyIndex >= 0, historyIndex < history.count, history[historyIndex] == new { return }
        if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
        history.append(new)
        historyIndex = history.count - 1
    }

    // MARK: settings search index

    private struct SettingEntry: Identifiable {
        let id = UUID()
        let pane: SettingsSection
        let title: String
        let keywords: [String]
    }

    // Curated index so search finds the actual settings, not just tab names. Selecting a result jumps
    // to the owning pane.
    private let index: [SettingEntry] = [
        .init(pane: .server,  title: "Launch at login",      keywords: ["startup", "login", "open at login", "autostart"]),
        .init(pane: .server,  title: "Endpoint host",        keywords: ["host", "network", "0.0.0.0", "local", "127.0.0.1", "bind"]),
        .init(pane: .server,  title: "Endpoint port",        keywords: ["port", "5678", "endpoint"]),
        .init(pane: .server,  title: "API key",              keywords: ["api key", "token", "auth", "security", "bearer"]),
        .init(pane: .server,  title: "Auto-evict models",    keywords: ["auto-evict", "eviction", "memory", "unload", "lru"]),
        .init(pane: .models,  title: "Pinned models",        keywords: ["pin", "pinned", "keep loaded", "models"]),
        .init(pane: .engines, title: "Ollama",               keywords: ["ollama", "engine", "port", "enable"]),
        .init(pane: .engines, title: "oMLX",                 keywords: ["omlx", "mlx", "engine", "port", "api key", "enable"]),
        .init(pane: .engines, title: "LM Studio",            keywords: ["lm studio", "lmstudio", "engine", "port", "api key", "enable"]),
        .init(pane: .engines, title: "llama-swap",           keywords: ["llama-swap", "llamaswap", "engine", "port", "api key", "enable"]),
        .init(pane: .engines, title: "Auto-configure engines", keywords: ["auto configure", "autoconfigure", "detect", "port", "api key"]),
        .init(pane: .about,   title: "Check for updates",    keywords: ["update", "updates", "version", "check"]),
    ]

    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    private var results: [SettingEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return index.filter { e in
            e.title.localizedCaseInsensitiveContains(q) || e.keywords.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    private func paneTitle(_ s: SettingsSection) -> String {
        (topItems + bottomItems).first { $0.section == s }?.title ?? ""
    }
    private func icon(for s: SettingsSection) -> String {
        (topItems + bottomItems).first { $0.section == s }?.symbol ?? "gearshape"
    }
    private func color(for s: SettingsSection) -> Color {
        (topItems + bottomItems).first { $0.section == s }?.color ?? .gray
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        switch ui.settingsSection {
        case .server:  ServerSettingsPane()
        case .models:  ModelsSettingsPane()
        case .engines: EnginesSettingsPane()
        case .logs:    LogsSettingsPane()
        case .about:   AboutSettingsPane()
        }
    }

    // A menu-bar (LSUIElement) app flipped to .regular shows a generic placeholder in the Dock unless
    // we set the icon explicitly. Use the grey-background Dock artwork — this changes only the Dock
    // icon; the bundle/Finder icon and the menu-bar glyph are unaffected.
    private func setDockIcon() {
        if let img = DockIcon.image {
            NSApp.applicationIconImage = img
        }
    }
}

// System-Settings-style sidebar icon: a white SF Symbol on a small rounded, colour-filled square.
private struct SidebarIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(ServerController(previewState: .running(host: "127.0.0.1", port: 5678)))
            .environmentObject(ModelStore.preview)
            .environmentObject(UIState())
            .environmentObject(EventLog.preview)
            .environmentObject(SecretsModel())
            .frame(width: 860, height: 580)
    }
}
#endif
