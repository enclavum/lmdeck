import SwiftUI
import AppKit

struct AboutSettingsPane: View {
    @AppStorage(SettingsKeys.autoCheckUpdates) private var autoCheck = true
    @AppStorage(SettingsKeys.lastUpdateCheck) private var lastCheck = 0.0
    @State private var checking = false
    @State private var updateResult: UpdateChecker.Result?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    AppIconBadge(size: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LMDeck").font(.system(size: 18, weight: .bold)).tracking(-0.18)
                        Text("Version \(appVersion)")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("Copyright © 2026 The LMDeck Authors · Apache License 2.0")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Section {
                HStack(spacing: 11) {
                    updateIcon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(updateTitle)
                        Text(updateSubtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 10)
                    if case let .some(.updateAvailable(_, url)) = updateResult {
                        Button("View Release") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Check Now") { checkNow() }
                        .disabled(checking)
                }
                .padding(.vertical, 4)
                .onAppear { maybeAutoCheck() }

                Toggle("Automatically Check for Updates", isOn: $autoCheck)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private var lastCheckedText: String {
        guard lastCheck > 0 else { return "never" }
        return Date(timeIntervalSince1970: lastCheck).formatted(date: .abbreviated, time: .shortened)
    }

    private func checkNow() {
        guard !checking else { return }
        checking = true
        let version = appVersion
        Task { @MainActor in
            let result = await UpdateChecker.check(currentVersion: version)
            updateResult = result
            // Don't stamp the time on a transient failure (network blip, rate-limit) — otherwise
            // maybeAutoCheck() would suppress the daily auto-check for 24h after a momentary failure.
            if case .failed = result {} else { lastCheck = Date().timeIntervalSince1970 }
            checking = false
        }
    }

    // Auto-check at most once a day when the About pane appears (if the toggle is on).
    private func maybeAutoCheck() {
        guard autoCheck, !checking, updateResult == nil else { return }
        if Date().timeIntervalSince1970 - lastCheck > 24 * 3600 { checkNow() }
    }

    @ViewBuilder private var updateIcon: some View {
        if checking {
            ProgressView().controlSize(.small).frame(width: 18, height: 18)
        } else {
            switch updateResult {
            case .some(.updateAvailable):
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 18))
                    .foregroundStyle(Color(nsColor: .controlAccentColor))
            case .some(.failed):
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 18))
                    .foregroundStyle(Color(nsColor: .systemOrange))
            case .some(.upToDate):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                    .foregroundStyle(Color(nsColor: .systemGreen))
            case .none:
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var updateTitle: String {
        if checking { return "Checking for updates…" }
        switch updateResult {
        case .some(.updateAvailable(let v, _)): return "Update available: \(v)"
        case .some(.failed):                    return "Couldn't check for updates"
        case .some(.upToDate):                  return "LMDeck is up to date"
        case .none:                             return "LMDeck \(appVersion)"
        }
    }

    private var updateSubtitle: String {
        if case .some(.updateAvailable) = updateResult {
            return "Download from the release page, or run brew upgrade --cask lmdeck once Homebrew updates."
        }
        return "Last checked: \(lastCheckedText)"
    }
}

#if DEBUG
struct AboutSettingsPane_Previews: PreviewProvider {
    static var previews: some View {
        AboutSettingsPane()
            .frame(width: 640, height: 380)
    }
}
#endif
