import AppKit

/// Where a branch's pull request has got to.
enum PullRequestState: String, Codable {
    case draft
    case open
    case merged
    case closed

    /// GitHub's own colors, so the dot means what it does on the website.
    var color: NSColor {
        switch self {
        case .open: return NSColor(srgbRed: 0.24, green: 0.72, blue: 0.31, alpha: 1)
        case .merged: return NSColor(srgbRed: 0.64, green: 0.44, blue: 0.97, alpha: 1)
        case .closed: return NSColor(srgbRed: 0.97, green: 0.32, blue: 0.29, alpha: 1)
        case .draft: return .secondaryLabelColor
        }
    }

    var label: String {
        switch self {
        case .draft: return "draft"
        case .open: return "open"
        case .merged: return "merged"
        case .closed: return "closed"
        }
    }
}

/// One branch's pull request.
struct PullRequestInfo: Equatable {
    var number: Int
    var state: PullRequestState

    var summary: String {
        "PR #\(number) — \(state.label)"
    }
}

/// Reads pull request state through the `gh` CLI.
///
/// `gh` is used rather than the REST API because it already holds the user's
/// credentials; without it, or on a repository with no GitHub remote, branches
/// simply have no state and the sidebar shows no dot.
enum PullRequestService {
    /// Cached per repository path, with when it was fetched.
    private static var cache: [String: (fetched: Date, byBranch: [String: PullRequestInfo])] = [:]
    private static var inFlight: Set<String> = []
    private static let queue = DispatchQueue(label: "com.tabterm.pr", qos: .utility)

    /// How long a fetch is reused before going back to the network.
    static let freshness: TimeInterval = 120

    static let executableURL: URL? = {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }()

    static var isAvailable: Bool { executableURL != nil }

    /// What we already know for a repository, without waiting on the network.
    static func cached(for repositoryPath: String) -> [String: PullRequestInfo] {
        cache[repositoryPath]?.byBranch ?? [:]
    }

    /// Fetch unless a recent result is already cached.
    ///
    /// `completion` runs on the main queue, and only when something changed, so
    /// callers can reload their view unconditionally.
    static func refresh(
        repositoryPath: String,
        force: Bool = false,
        completion: @escaping ([String: PullRequestInfo]) -> Void
    ) {
        guard isAvailable else { return }

        if !force, let entry = cache[repositoryPath],
           Date().timeIntervalSince(entry.fetched) < freshness {
            return
        }
        // One request per repository at a time.
        guard !inFlight.contains(repositoryPath) else { return }
        inFlight.insert(repositoryPath)

        queue.async {
            let result = load(repositoryPath: repositoryPath)
            DispatchQueue.main.async {
                inFlight.remove(repositoryPath)
                guard let result else { return }

                let changed = cache[repositoryPath]?.byBranch != result
                cache[repositoryPath] = (Date(), result)
                if changed { completion(result) }
            }
        }
    }

    /// Blocking call to `gh`. Returns nil when it isn't usable here — no GitHub
    /// remote, not authenticated — which is different from "no pull requests".
    private static func load(repositoryPath: String) -> [String: PullRequestInfo]? {
        guard let executableURL else { return nil }

        struct Row: Decodable {
            var number: Int
            var headRefName: String
            var state: String
            var isDraft: Bool
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "pr", "list",
            "--state", "all",
            "--limit", "100",
            "--json", "number,headRefName,state,isDraft",
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: repositoryPath)

        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }

        var byBranch: [String: PullRequestInfo] = [:]
        for row in rows {
            let state: PullRequestState
            switch row.state.uppercased() {
            case "MERGED": state = .merged
            case "CLOSED": state = .closed
            default: state = row.isDraft ? .draft : .open
            }

            // A branch can have several PRs over time; an open one is the
            // interesting one, otherwise keep the highest-numbered (latest).
            if let existing = byBranch[row.headRefName] {
                let existingIsLive = existing.state == .open || existing.state == .draft
                let newIsLive = state == .open || state == .draft
                if existingIsLive && !newIsLive { continue }
                if !newIsLive && row.number < existing.number { continue }
            }
            byBranch[row.headRefName] = PullRequestInfo(number: row.number, state: state)
        }
        return byBranch
    }

    /// Drop everything, so the self-test isn't affected by real repositories.
    static func resetForTesting() {
        cache.removeAll()
        inFlight.removeAll()
    }

    /// Seed the cache directly, for tests that shouldn't hit the network.
    static func seedForTesting(repositoryPath: String, branches: [String: PullRequestInfo]) {
        cache[repositoryPath] = (Date(), branches)
    }
}
