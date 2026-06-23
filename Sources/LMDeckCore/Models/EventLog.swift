import Foundation
import os

// A durable activity log of model + server events. Each entry records the local time it happened and
// how long the operation took, so a user can see e.g. "Auto-evicted llama3:latest — 0.4 s" after the
// fact — including across relaunches. Backed by a capped JSON file in Application Support and mirrored
// to the unified log (Console.app / `log stream --predicate 'subsystem == "com.enclavum.lmdeck"'`).

// One logged event — a model load/unload/eviction or a server transition.
public struct ActivityEvent: Identifiable, Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable { case model, server }

    public let id: UUID
    public let at: Date               // when it happened (shown in local time, to the second)
    public let category: Category
    public let title: String
    public let detail: String?
    public let duration: TimeInterval // seconds the operation took
    public let ok: Bool               // false = failure (shown in red)

    // SI second symbol, one decimal — e.g. "12.3 s".
    public var durationText: String { String(format: "%.1f s", duration) }

    // One monospaced log line: "<local timestamp>  <title[ — detail]>  (<duration>)".
    public var line: String {
        let body = detail.map { "\(title) — \($0)" } ?? title
        return "\(Self.lineFormatter.string(from: at))  \(body) (\(durationText))"
    }

    private static let lineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"   // local time, to the second (DateFormatter uses the local zone)
        return f
    }()
}

@MainActor
public final class EventLog: ObservableObject {
    public static let shared = EventLog()

    @Published public private(set) var events: [ActivityEvent] = []

    private static let maxEvents = 500
    private nonisolated static let logger = Logger(subsystem: "com.enclavum.lmdeck", category: "activity")
    private var flushTask: Task<Void, Never>?

    private init() {
        if let url = Self.fileURL, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([ActivityEvent].self, from: data) {
            events = Array(decoded.suffix(Self.maxEvents))
        }
    }

    // Nonisolated entry points — callable from any context (the LoadManager actor, the proxy,
    // ServerController). The unified-log mirror happens immediately; the published list + file write
    // hop to the main actor.
    public nonisolated static func model(_ title: String, detail: String? = nil,
                                         seconds: TimeInterval, ok: Bool = true) {
        record(ActivityEvent(id: UUID(), at: Date(), category: .model,
                             title: title, detail: detail, duration: seconds, ok: ok))
    }

    public nonisolated static func server(_ title: String, seconds: TimeInterval, ok: Bool = true) {
        record(ActivityEvent(id: UUID(), at: Date(), category: .server,
                             title: title, detail: nil, duration: seconds, ok: ok))
    }

    private nonisolated static func record(_ e: ActivityEvent) {
        logger.log("\(e.category.rawValue, privacy: .public) \(e.title, privacy: .public)\(e.ok ? "" : " (failed)", privacy: .public) — \(e.durationText, privacy: .public)")
        Task { @MainActor in shared.append(e) }
    }

    private func append(_ e: ActivityEvent) {
        events.append(e)
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        scheduleFlush()
    }

    // Coalesce a burst of events (e.g. several auto-evictions at once) into one debounced disk write
    // instead of re-encoding + writing the whole array per event on the main actor. The in-memory
    // append + @Published update above is what the UI needs synchronously; the file is eventually
    // consistent (the os.Logger mirror is the immediate, durable record).
    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    public func clear() {
        flushTask?.cancel()
        events.removeAll()
        if let url = Self.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    // Log the server stopping at app exit and persist *synchronously* — the normal async append + 1s
    // debounced write wouldn't run before the process terminates, so the stop would be lost (leaving
    // many "Server started" with no matching "Server stopped"). Call from applicationWillTerminate.
    public func recordServerStoppedAtExit() {
        events.append(ActivityEvent(id: UUID(), at: Date(), category: .server,
                                    title: "Server stopped (app quit)", detail: nil, duration: 0, ok: true))
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        flushTask?.cancel()
        persist()
    }

    private func persist() {
        guard let url = Self.fileURL else { return }
        if let data = try? JSONEncoder().encode(events) { try? data.write(to: url, options: .atomic) }
    }

    // ~/Library/Application Support/LMDeck/activity.json
    private nonisolated static var fileURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        let appDir = dir.appendingPathComponent("LMDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("activity.json")
    }
}

#if DEBUG
extension EventLog {
    /// Sample log for SwiftUI previews (not persisted).
    static var preview: EventLog {
        let log = EventLog()
        log.events = [
            ActivityEvent(id: UUID(), at: Date().addingTimeInterval(-95), category: .server,
                          title: "Server started", detail: nil, duration: 0.1, ok: true),
            ActivityEvent(id: UUID(), at: Date().addingTimeInterval(-60), category: .model,
                          title: "Loaded ollama/qwen2.5:7b", detail: nil, duration: 3.4, ok: true),
            ActivityEvent(id: UUID(), at: Date().addingTimeInterval(-12), category: .model,
                          title: "Auto-evicted omlx/Mistral-Nemo-Instruct-2407-4bit",
                          detail: "to load ollama/llama3.3:latest", duration: 0.4, ok: true),
            ActivityEvent(id: UUID(), at: Date().addingTimeInterval(-4), category: .model,
                          title: "Failed to load lmstudio/some-big-model", detail: "insufficient memory",
                          duration: 0.0, ok: false),
        ]
        return log
    }
}
#endif
