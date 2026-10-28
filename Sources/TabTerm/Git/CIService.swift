import Foundation

enum CheckState: String {
    case failed = "Failed", pending = "Running", unknown = "Unknown", passed = "Passed", skipped = "Skipped"

    var symbol: String {
        switch self {
        case .failed: return "xmark.circle.fill"
        case .pending: return "clock.fill"
        case .unknown: return "questionmark.circle"
        case .passed: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }
}

struct CICheck: Equatable {
    var name: String
    var state: CheckState
    var detail: String
    var url: URL?
}

struct CISnapshot: Equatable {
    var checks: [CICheck]

    var state: CheckState? {
        guard !checks.isEmpty else { return nil }
        for state in [CheckState.failed, .pending, .unknown, .passed, .skipped] {
            if checks.contains(where: { $0.state == state }) { return state }
        }
        return nil
    }

    var summary: String {
        guard let state else { return "No checks" }
        let count = checks.filter { $0.state == state }.count
        switch state {
        case .failed: return "\(count) failed"
        case .pending: return "\(count) running"
        case .unknown: return "\(count) unknown"
        case .passed: return "Checks passed"
        case .skipped: return "Checks skipped"
        }
    }
}

enum CIService {
    /// Query the exact local commit, never a branch's potentially older successful run.
    /// Include legacy commit statuses (external CI) as well as GitHub check runs.
    static func load(at directory: String, head: String) throws -> CISnapshot {
        guard let gh = PullRequestService.executableURL else {
            throw GitError.commandFailed("Install GitHub CLI (gh), then run gh auth login to see CI checks.")
        }
        // PR rollups also include checks associated with GitHub's test merge.
        // Only use them when the PR head matches the local commit exactly.
        if let data = try? ReviewCommand.run(gh, ["pr", "view", "--json", "headRefOid,statusCheckRollup"], in: directory, timeout: 15),
           let snapshot = try? decodePullRequest(data, matching: head) {
            return snapshot
        }
        let base = "repos/{owner}/{repo}/commits/\(head)"
        func fetch(_ suffix: String) throws -> Data {
            try ReviewCommand.run(gh, ["api", base + suffix, "--paginate", "--slurp"], in: directory, timeout: 25)
        }
        let runs = try fetch("/check-runs?per_page=100&filter=latest")
        let statuses = try fetch("/status?per_page=100")
        return try decode(runs: runs, statuses: statuses)
    }

    static func decodePullRequest(_ data: Data, matching head: String) throws -> CISnapshot? {
        struct Check: Decodable {
            var name: String?
            var context: String?
            var status: String?
            var conclusion: String?
            var state: String?
            var description: String?
            var detailsUrl: String?
            var targetUrl: String?
        }
        struct PR: Decodable { var headRefOid: String; var statusCheckRollup: [Check]? }
        let pr = try JSONDecoder().decode(PR.self, from: data)
        guard pr.headRefOid == head else { return nil }
        let checks = (pr.statusCheckRollup ?? []).map { check in
            let isLegacy = check.context != nil
            let status = check.status?.lowercased() ?? "completed"
            let conclusion = (isLegacy ? check.state : check.conclusion)?.lowercased()
            let state = isLegacy && conclusion == "pending" ? CheckState.pending : checkState(status: status, conclusion: conclusion)
            return CICheck(name: check.name ?? check.context ?? "Unnamed check", state: state,
                           detail: check.description ?? (conclusion ?? status).replacingOccurrences(of: "_", with: " "),
                           url: webURL(check.detailsUrl) ?? webURL(check.targetUrl))
        }
        return sorted(checks)
    }

    private static func checkState(status: String, conclusion: String?) -> CheckState {
        if status != "completed" {
            return ["queued", "in_progress", "waiting", "pending", "requested"].contains(status) ? .pending : .unknown
        }
        switch conclusion {
        case "success": return .passed
        case "neutral", "skipped": return .skipped
        case "failure", "error", "cancelled", "timed_out", "action_required", "stale", "startup_failure": return .failed
        default: return .unknown
        }
    }

    static func decode(runs: Data, statuses: Data) throws -> CISnapshot {
        struct Run: Decodable {
            var name: String
            var status: String
            var conclusion: String?
            var html_url: String?
            var details_url: String?
        }
        struct RunsPage: Decodable { var check_runs: [Run] }
        struct Status: Decodable {
            var context: String
            var state: String
            var description: String?
            var target_url: String?
        }
        struct StatusPage: Decodable { var statuses: [Status] }
        let decoder = JSONDecoder()
        var checks = try decoder.decode([RunsPage].self, from: runs).flatMap(\.check_runs).map { run in
            let state = checkState(status: run.status, conclusion: run.conclusion)
            return CICheck(name: run.name, state: state,
                           detail: (run.conclusion ?? run.status).replacingOccurrences(of: "_", with: " "),
                           url: webURL(run.html_url) ?? webURL(run.details_url))
        }
        // GitHub returns the latest legacy status per context. Deduplicate page overlap.
        var seen = Set<String>()
        for status in try decoder.decode([StatusPage].self, from: statuses).flatMap(\.statuses) {
            guard seen.insert(status.context).inserted else { continue }
            let state: CheckState
            switch status.state {
            case "success": state = .passed
            case "pending": state = .pending
            case "failure", "error": state = .failed
            default: state = .unknown
            }
            checks.append(CICheck(name: status.context, state: state,
                                  detail: status.description ?? status.state, url: webURL(status.target_url)))
        }
        return sorted(checks)
    }

    private static func sorted(_ input: [CICheck]) -> CISnapshot {
        var checks = input
        let order: [CheckState] = [.failed, .pending, .unknown, .passed, .skipped]
        checks.sort {
            if $0.state != $1.state { return order.firstIndex(of: $0.state)! < order.firstIndex(of: $1.state)! }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return CISnapshot(checks: checks)
    }

    static func webURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
}
