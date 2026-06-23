import SwiftUI

enum SettingsSection: String, Hashable {
    case server, models, engines, logs, about
}

@MainActor
public final class UIState: ObservableObject {
    @Published var settingsSection: SettingsSection = .server
    public init() {}
}
