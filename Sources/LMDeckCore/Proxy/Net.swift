import Foundation

// Pure helpers for normalizing endpoint host/port values — no I/O, unit-tested.
enum Net {
    /// A configured port, falling back to `def` when unset (0).
    static func port(_ raw: Int, default def: Int) -> Int { raw == 0 ? def : raw }

    /// Clamp to a valid TCP port (1...65535), applying `def` when unset.
    static func boundPort(_ raw: Int, default def: Int) -> UInt16 {
        UInt16(min(65535, max(1, port(raw, default: def))))
    }

    /// Bind host, defaulting empty to loopback.
    static func host(_ raw: String) -> String { raw.isEmpty ? "127.0.0.1" : raw }

    /// Friendly display host: loopback reads as "localhost"; everything else as-is.
    static func displayHost(_ h: String) -> String { h == "127.0.0.1" ? "localhost" : h }
}
