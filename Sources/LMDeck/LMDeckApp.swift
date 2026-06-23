import SwiftUI
import AppKit
import LMDeckCore

// LMDeck — a native macOS menu-bar control plane for local LLM engines.
// UI + logic live in the LMDeckCore library (so SwiftUI previews work); this is just @main.

@main
struct LMDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var server = ServerController()
    @StateObject private var store = ModelStore()
    @StateObject private var ui = UIState()
    @StateObject private var secrets: SecretsModel

    // Optional CLI flag: `open LMDeck.app --args --settings` opens Settings on launch.
    private let openSettingsAtLaunch = CommandLine.arguments.contains("--settings")

    init() {
        LMDeckDefaults.register()
        // Move any plaintext keys into the Keychain (signed release) before anything reads them.
        SecretStore.shared.migrateLegacySecrets()
        _secrets = StateObject(wrappedValue: SecretsModel())
        // First-run engine auto-detect at launch (the server auto-starts here too), so it runs even
        // if the user never opens Settings. Idempotent — guarded by the enginesAutoDetected flag.
        Task { await ModelStore.autoDetectEnginesIfNeeded() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(server: server, ui: ui)
        } label: {
            MenuBarLabel(openOnLaunch: openSettingsAtLaunch, ui: ui, server: server)
        }
        .menuBarExtraStyle(.window)   // custom popover panel (RAM + loaded models at a glance)

        Window("", id: "settings") {
            SettingsView()
                .environmentObject(server)
                .environmentObject(store)
                .environmentObject(ui)
                .environmentObject(EventLog.shared)
                .environmentObject(secrets)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 860, height: 580)
        .windowResizability(.contentSize)
    }
}

// Minimal app delegate, just for the termination hook: record the server stopping when the app quits.
// The menu-bar process otherwise dies without logging a stop (unlike Start, which logs on launch), so
// the activity log filled with "Server started" and almost no "Server stopped".
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `make run` (and any `kill -TERM`) sends SIGTERM, whose default disposition terminates the
        // process *without* running applicationWillTerminate — so the "Server stopped" event would be
        // lost (the symptom: lots of "Server started", almost no stops). Catch SIGTERM and shut down
        // the same way: log the stop synchronously, then exit. (SIGKILL/`-9` stays uncatchable.)
        signal(SIGTERM, SIG_IGN)   // disable the default terminate so the dispatch source handles it
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler {
            MainActor.assumeIsolated { EventLog.shared.recordServerStoppedAtExit() }
            exit(0)
        }
        src.resume()
        sigtermSource = src
    }

    func applicationWillTerminate(_ notification: Notification) {
        EventLog.shared.recordServerStoppedAtExit()
    }
}
