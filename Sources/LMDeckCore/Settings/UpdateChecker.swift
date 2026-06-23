import Foundation

// Lightweight "is there a newer release?" check against the GitHub Releases API. It only *informs*
// and links — it never downloads or installs. The GitHub release is the earliest signal a new
// version exists; the Homebrew cask can lag it, so the About pane's call-to-action is the release
// page (always current), with `brew upgrade` mentioned as the eventual path.
enum UpdateChecker {
    static let repo = "enclavum/lmdeck"

    enum Result: Equatable {
        case upToDate
        case updateAvailable(version: String, url: URL)
        case failed   // couldn't reach GitHub, no releases yet, rate-limited, etc.
    }

    static func check(currentVersion: String) async -> Result {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return .failed }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("LMDeck", forHTTPHeaderField: "User-Agent")   // GitHub rejects requests without one
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            return .failed
        }
        let page = (obj["html_url"] as? String).flatMap { URL(string: $0) }
            ?? URL(string: "https://github.com/\(repo)/releases/latest")!
        return isNewer(tag, than: currentVersion) ? .updateAvailable(version: tag, url: page) : .upToDate
    }

    // Pure: is `latest` a newer semantic version than `current`? Tolerates a leading "v" and differing
    // component counts ("1.2" == "1.2.0"), and compares numerically (so 1.10 > 1.9, not lexically).
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(latest), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
