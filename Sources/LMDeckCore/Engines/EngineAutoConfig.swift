import Foundation
import Darwin

// Best-effort, read-only engine auto-detection for Settings → Engines → "Auto configure".
// Each engine's port + API key are read from sources already on the machine — the engine's own
// settings file, this app's environment, or the engine's launch arguments (via the kernel process
// table) — *never* by launching a CLI. A nil field means "couldn't determine it" (left untouched).
struct DetectedEngineConfig: Sendable {
    var port: Int?
    var apiKey: String?
}

// Pure-ish readers shared by the per-engine `detectConfig()` methods. The parsing bits are pure
// (unit-tested); the file/process reads are best-effort and return nil on any failure.
enum EngineConfigReader {
    // Parse a JSON object at a path under the user's home (e.g. ".omlx/settings.json").
    static func homeJSON(_ relativePath: String) -> [String: Any]? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    // The port from a "host:port", ":port", or bare "port" string; nil if not a valid 1–65535 port.
    static func port(fromListen s: String) -> Int? {
        let tail = s.split(separator: ":").last.map(String.init) ?? s
        guard let p = Int(tail.trimmingCharacters(in: .whitespaces)), (1...65535).contains(p) else { return nil }
        return p
    }

    // The argument after `flag` in an argv list (e.g. value(after: "--listen", in: ["--listen", ":8080"]) → ":8080").
    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].isEmpty else { return nil }
        return args[i + 1]
    }

    // Best-effort: the first literal item of a top-level YAML list `key:` in a file (skips `${…}`
    // env-macro entries). A small line parser — not a full YAML parser — enough for llama-swap's
    // `apiKeys:` block list.
    static func firstYAMLListItem(under key: String, inFileAt path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var inSection = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inSection {
                if line.hasPrefix("\(key):") { inSection = true }
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("- ") {
                let v = String(trimmed.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !v.isEmpty && !v.contains("${") { return v }   // skip env-macro entries
                continue
            }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }   // a new top-level key → section ended
        }
        return nil
    }

    // argv of the first running process whose executable path contains `execContains`, read from the
    // kernel process table (sysctl KERN_PROCARGS2) — not by shelling out to `ps`. Same-user only.
    static func processArgs(execContains: String) -> [String]? {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 16)
        let written = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
        }
        guard written > 0 else { return nil }
        let n = min(Int(written) / MemoryLayout<pid_t>.size, pids.count)
        for k in 0..<n where pids[k] > 0 {
            var pathBuf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE (4 × MAXPATHLEN)
            guard proc_pidpath(pids[k], &pathBuf, UInt32(pathBuf.count)) > 0,
                  String(cString: pathBuf).contains(execContains) else { continue }
            if let args = argv(ofPID: pids[k]) { return args }
        }
        return nil
    }

    // Parse argv out of KERN_PROCARGS2: [Int32 argc][exec path\0][\0 padding][arg\0 × argc][env…].
    private static func argv(ofPID pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buf, &size, nil, 0) == 0 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }   // skip the exec path
        while i < size && buf[i] == 0 { i += 1 }   // skip the null padding after it
        var args: [String] = []
        var cur: [UInt8] = []
        while i < size && args.count < argc {
            let b = buf[i]; i += 1
            if b == 0 { args.append(String(decoding: cur, as: UTF8.self)); cur.removeAll(keepingCapacity: true) }
            else { cur.append(b) }
        }
        return args.isEmpty ? nil : args
    }
}

// The action behind the "Auto configure" button. Reads each engine's config and writes the detected
// port (UserDefaults) + API key (through the live SecretsModel, so the fields update) — overwriting
// existing values. Fields it can't detect are left as-is. Button-triggered only (never at launch).
enum EngineAutoConfig {
    static func detect(_ kind: EngineKind) -> DetectedEngineConfig {
        switch kind {
        case .ollama:    return OllamaEngine.detectConfig()
        case .omlx:      return OmlxEngine.detectConfig()
        case .lmstudio:  return LMStudioEngine.detectConfig()
        case .llamaswap: return LlamaSwapEngine.detectConfig()
        }
    }

    @MainActor static func apply(to secrets: SecretsModel) async {
        // Detection (file + process reads) off the main thread; settings writes back on the main actor.
        let detected = await Task.detached(priority: .userInitiated) {
            EngineKind.allCases.map { ($0, detect($0)) }
        }.value
        for (kind, d) in detected {
            if let port = d.port { UserDefaults.standard.set(port, forKey: kind.portKey) }
            guard let key = d.apiKey, !key.isEmpty else { continue }
            switch kind {
            case .omlx:      secrets.omlxKey = key
            case .lmstudio:  secrets.lmstudioKey = key
            case .llamaswap: secrets.llamaswapKey = key
            case .ollama:    break   // local Ollama has no API key
            }
        }
    }
}
