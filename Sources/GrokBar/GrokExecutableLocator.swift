import Foundation

struct GrokExecutableLocator: Sendable {
    enum LocatorError: Error, LocalizedError {
        case notFound

        var errorDescription: String? {
            "Install the Grok CLI and sign in with grok login"
        }
    }

    func locate() throws -> URL {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let home = fileManager.homeDirectoryForCurrentUser

        var candidates: [URL] = []
        if let configured = environment["GROK_PATH"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }

        candidates += (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "grok") }

        candidates += [
            URL(fileURLWithPath: "/opt/homebrew/bin/grok"),
            URL(fileURLWithPath: "/usr/local/bin/grok"),
            home.appending(path: ".local/bin/grok"),
            home.appending(path: ".grok/bin/grok"),
            home.appending(path: ".volta/bin/grok"),
            home.appending(path: ".nvm/current/bin/grok")
        ]

        // nvm only creates `current` when a shell has linked it. The installed binaries live under versions/node.
        candidates += executables(
            beneath: home.appending(path: ".nvm/versions/node"),
            suffix: "bin/grok"
        )

        candidates += executables(
            beneath: home.appending(path: ".local/share/fnm/node-versions"),
            suffix: "installation/bin/grok"
        )
        candidates += executables(
            beneath: home.appending(path: ".local/state/fnm_multishells"),
            suffix: "bin/grok"
        )

        var seen = Set<String>()
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        throw LocatorError.notFound
    }

    private func executables(beneath root: URL, suffix: String) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .sorted { lhs, rhs in
                let lhsDate = try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let rhsDate = try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (lhsDate ?? .distantPast) > (rhsDate ?? .distantPast)
            }
            .map { $0.appending(path: suffix) }
    }
}
