import SwiftUI

struct ModelsSettingsPane: View {
    @EnvironmentObject private var store: ModelStore
    @State private var ramAvail = 0.0
    @State private var ramTotal = 0.0
    @State private var ramAvailBytes = 0   // drives the per-model "fits now?" load gate
    @State private var search = ""
    @State private var onlyActive = false
    @FocusState private var searchFocused: Bool

    private var usedFraction: Double { ramTotal > 0 ? max(0, ramTotal - ramAvail) / ramTotal : 0 }

    // One row per (engine, model), flattened across every engine into a single list.
    private struct FlatModel: Identifiable {
        let engine: EngineState
        let model: ModelInfo
        var id: String { "\(engine.kind.token)/\(model.id)" }
    }

    private var allModels: [FlatModel] {
        store.engines.flatMap { eng in eng.models.map { FlatModel(engine: eng, model: $0) } }
    }

    // Filtered by the search field (model name or engine label) and the "Only active" toggle, then
    // sorted by name case-insensitively (ties broken by engine priority for a stable order).
    private var visibleModels: [FlatModel] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return allModels
            .filter { !onlyActive || $0.model.loaded }
            .filter { q.isEmpty
                || $0.model.id.localizedCaseInsensitiveContains(q)
                || $0.engine.kind.badgeLabel.localizedCaseInsensitiveContains(q) }
            .sorted {
                let c = $0.model.id.localizedCaseInsensitiveCompare($1.model.id)
                return c == .orderedSame ? $0.engine.kind.priority < $1.engine.kind.priority
                                         : c == .orderedAscending
            }
    }

    // Clickable search pill (tapping anywhere in it focuses the field — a plain TextField alone has a
    // tiny hit area in a Form row).
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search models", text: $search)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .focused($searchFocused)
                .frame(maxWidth: .infinity)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
    }

    var body: some View {
        VStack(spacing: 0) {
            // RAM — its own grouped card, sized to its content.
            Form {
                Section("RAM") {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Memory").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                            Spacer()
                            HStack(spacing: 0) {
                                Text(String(format: "%.1f GB free", ramAvail)).foregroundStyle(.primary)
                                Text(String(format: " / %.0f GB", ramTotal)).foregroundStyle(.tertiary)
                            }
                            .font(.system(size: 13)).monospacedDigit()
                        }
                        HStack(spacing: 8) {
                            RamBar(fraction: usedFraction)
                            Text("\(Int((usedFraction * 100).rounded()))%")
                                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                                .frame(width: 30, alignment: .trailing)
                        }
                        Text(String(format: "%.1f GB used · %.1f GB available",
                                    max(0, ramTotal - ramAvail), ramAvail))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            // Search + "Only active", between the two cards, out of any group.
            if !store.engines.isEmpty {
                HStack(spacing: 12) {
                    searchField
                    Toggle("Only active", isOn: $onlyActive).toggleStyle(.checkbox).fixedSize()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }

            // Models — its own grouped list; takes the remaining height and scrolls.
            Form {
                if store.engines.isEmpty {
                    Section { Text("No engines responding.").foregroundStyle(.secondary) }
                } else {
                    let models = visibleModels
                    let loadedCount = models.filter { $0.model.loaded }.count
                    Section {
                        if models.isEmpty {
                            Text(allModels.isEmpty ? "No models" : "No models match").foregroundStyle(.secondary)
                        } else {
                            ForEach(models) { fm in
                                let m = fm.model
                                let eng = fm.engine
                                // A loaded model can always be unloaded; an unloaded one can only be loaded
                                // if its predicted footprint fits the memory free right now.
                                let loadable = m.loaded || MemoryBudget.canLoad(
                                    estimatedSizeBytes: m.estimatedSizeBytes, availableBytes: ramAvailBytes)
                                ModelRow(name: m.id, engineKind: eng.kind, loaded: m.loaded, sizeBytes: m.sizeBytes,
                                         contextLength: m.contextLength,
                                         enabled: store.canControl(eng.name),
                                         loadable: loadable,
                                         busy: store.isBusy(engineName: eng.name, modelID: m.id),
                                         error: store.error(engineName: eng.name, modelID: m.id),
                                         pinned: store.isPinned(kind: eng.kind, modelID: m.id),
                                         onTogglePin: { store.togglePin(kind: eng.kind, modelID: m.id) }) {
                                    store.toggleLoad(engineName: eng.name, modelID: m.id)
                                }
                            }
                        }
                    } footer: {
                        Text("\(loadedCount) of \(allModels.count) loaded")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle("Models")
        .task {
            while !Task.isCancelled {
                let avail = SystemMemory.availableBytes
                ramAvailBytes = Int(avail)
                ramAvail = SystemMemory.gb(avail)
                ramTotal = SystemMemory.gb(SystemMemory.totalBytes)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

// A model row: pin · status dot · name · engine badge · ctx · size · Load/Unload.
private struct ModelRow: View {
    let name: String
    let engineKind: EngineKind
    let loaded: Bool
    let sizeBytes: Int?
    let contextLength: Int?
    let enabled: Bool
    let loadable: Bool      // false ⇒ won't fit in free memory right now (Load disabled)
    let busy: Bool
    let error: String?
    let pinned: Bool
    let onTogglePin: () -> Void
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PinButton(pinned: pinned, action: onTogglePin)
            StatusDot(loaded: loaded)
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
                .help(name)
            EngineBadge(kind: engineKind)
            Spacer(minLength: 10)
            if let ctx = contextLength {
                Text("\(Int((Double(ctx) / 1024).rounded()))K ctx")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
            }
            if let bytes = sizeBytes {
                Text(String(format: "%.1f GB", Double(bytes) / 1_073_741_824))
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
            if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .help(error)
            }
            ModelButton(loaded: loaded, enabled: enabled, loadable: loadable, busy: busy, action: action)
        }
        .padding(.vertical, 2)
    }
}

// A compact pill marking which engine owns a model in the unified list.
private struct EngineBadge: View {
    let kind: EngineKind
    var body: some View {
        Text(kind.badgeLabel)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

private extension EngineKind {
    var badgeLabel: String {
        switch self {
        case .ollama:    return "Ollama"
        case .omlx:      return "oMLX"
        case .lmstudio:  return "LM Studio"
        case .llamaswap: return "llama-swap"
        }
    }
}

// Loaded = filled green; unloaded = hollow outline.
private struct StatusDot: View {
    let loaded: Bool
    var body: some View {
        Group {
            if loaded {
                Circle().fill(Color(nsColor: .systemGreen))
            } else {
                Circle().strokeBorder(Color(nsColor: .quaternaryLabelColor), lineWidth: 1.3)
            }
        }
        .frame(width: 7, height: 7)
        .offset(y: 1)   // optically center the small dot against the row text
    }
}

// Fixed 64×24 button: bordered "Load", red "Unload".
private struct ModelButton: View {
    let loaded: Bool
    let enabled: Bool
    let loadable: Bool
    let busy: Bool
    let action: () -> Void

    // Load is gated by memory fit; Unload is always allowed. Plus the usual engine/busy gates.
    private var disabled: Bool { !enabled || busy || (!loaded && !loadable) }

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(loaded ? "Unload" : "Load").font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 56, height: 16)
        }
        .buttonStyle(.bordered)
        .tint(loaded ? Color(nsColor: .systemRed) : nil)
        .disabled(disabled)
        .help(!loaded && !loadable ? "Not enough free memory to load this model right now" : "")
    }
}

// Pin toggle: filled accent when pinned, hollow secondary otherwise. Pinned models are never
// auto-evicted by the load manager to make room for an incoming request.
private struct PinButton: View {
    let pinned: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 12))
                .foregroundStyle(pinned ? Color(nsColor: .controlAccentColor) : Color.secondary)
                .frame(width: 22, height: 24)
                .opacity(pinned || hover ? 1 : 0.5)
                .offset(y: 1)   // optically align the pin with the row text
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(pinned ? "Pinned — protected from automatic eviction" : "Pin to protect from automatic eviction")
    }
}

#if DEBUG
struct ModelsSettingsPane_Previews: PreviewProvider {
    static var previews: some View {
        ModelsSettingsPane()
            .environmentObject(ModelStore.preview)
            .frame(width: 640, height: 640)
    }
}
#endif
