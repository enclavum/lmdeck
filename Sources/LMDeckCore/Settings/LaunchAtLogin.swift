import Foundation
import ServiceManagement

// Launch LMDeck when the user logs in, via `SMAppService.mainApp` — a "login item" under
// System Settings → General → Login Items → "Open at Login". This route lists the app by NAME;
// only background agents/daemons ("Allow in the Background") surface the signing identity's
// developer name. Opt-in (default off) — registering happens only when the user enables the toggle,
// per Apple's review guidance.
public enum LaunchAtLogin {
    // Registered as a login item. `.requiresApproval` (user must approve in Login Items) still counts
    // as "on" — the registration succeeded, it's just awaiting approval.
    public static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    // Returns true on success. On failure (e.g. an unsigned/relocated dev build) the toggle's
    // computed binding re-reads `isEnabled` and reverts, so the UI stays truthful.
    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            return false
        }
    }
}
