import Foundation

/// One entry from `git worktree list`.
struct GitWorktree: Equatable {
    var path: String
    /// Branch short name, or nil when the worktree is detached.
    var branch: String?
    var isMain: Bool
}

enum GitError: LocalizedError {
    case gitNotFound
    case notARepository(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .gitNotFound:
            return "Couldn't find git. Install the Xcode command line tools or Homebrew git."
        case .notARepository(let path):
            return "\(path) isn't a git repository."
        case .commandFailed(let message):
            return message
        }
    }
}

/// A branch the new-worktree sheet can check out.
struct BranchChoice: Equatable {
    /// Local branch name the worktree will be on.
    var name: String
    /// "origin/foo" when this only exists on a remote; a local branch is
    /// created from it, tracking it.
    var remoteRef: String?

    var remoteName: String? {
        guard let remoteRef else { return nil }
        return String(remoteRef.dropLast(name.count + 1))
    }
}

/// Thin wrapper over the `git` CLI.
///
/// The app bundle doesn't inherit a login shell's PATH, so the binary is looked
/// up in the usual locations rather than resolved via the environment.
enum GitService {
    static let executableURL: URL? = {
        let candidates = [
            "/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }()

    @discardableResult
    static func run(_ arguments: [String], in directory: String) throws -> String {
        guard let executableURL else { throw GitError.gitNotFound }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        // Keep git from opening editors, prompting for credentials, or paging.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_PAGER"] = "cat"
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            throw GitError.commandFailed(error.localizedDescription)
        }

        // Read before waiting so a large output can't fill the pipe and deadlock.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(
                message.isEmpty ? "git \(arguments.joined(separator: " ")) failed" : message
            )
        }
        return stdout
    }

    /// The top level of the working tree containing `path`, if any.
    static func repositoryRoot(at path: String) -> String? {
        guard let root = try? run(["rev-parse", "--show-toplevel"], in: path) else { return nil }
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Every worktree attached to the repository, main checkout first.
    static func worktrees(for repositoryPath: String) throws -> [GitWorktree] {
        let output = try run(["worktree", "list", "--porcelain"], in: repositoryPath)

        var result: [GitWorktree] = []
        var path: String?
        var branch: String?

        func flush() {
            guard let path else { return }
            result.append(
                GitWorktree(
                    path: path,
                    branch: branch,
                    // git always lists the main working tree first.
                    isMain: result.isEmpty
                )
            )
            branch = nil
        }

        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                // "branch refs/heads/feature/x" -> "feature/x"
                let ref = String(line.dropFirst("branch ".count))
                branch = ref.hasPrefix("refs/heads/")
                    ? String(ref.dropFirst("refs/heads/".count))
                    : ref
            }
        }
        flush()

        return result
    }

    /// Local branch names, most recently used first.
    static func branches(for repositoryPath: String) throws -> [String] {
        let output = try run(
            ["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/heads"],
            in: repositoryPath
        )
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Branches already checked out somewhere, which git won't let you reuse.
    static func checkedOutBranches(for repositoryPath: String) -> Set<String> {
        let trees = (try? worktrees(for: repositoryPath)) ?? []
        return Set(trees.compactMap(\.branch))
    }

    /// Branches a new worktree could check out: unused local branches, then
    /// remote branches with no local counterpart. Each group most recent first.
    static func branchChoices(for repositoryPath: String) -> [BranchChoice] {
        let local = (try? branches(for: repositoryPath)) ?? []
        let checkedOut = checkedOutBranches(for: repositoryPath)
        var choices = local
            .filter { !checkedOut.contains($0) }
            .map { BranchChoice(name: $0, remoteRef: nil) }

        // lstrip=2 gives "origin/feature/x", lstrip=3 gives "feature/x".
        let output = (try? run(
            ["for-each-ref", "--format=%(refname:lstrip=2)%09%(refname:lstrip=3)",
             "--sort=-committerdate", "refs/remotes"],
            in: repositoryPath
        )) ?? ""
        // A remote branch that already has a local one (used or not) is that
        // branch; and the same name on two remotes shows once.
        var seen = Set(local)
        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2, !parts[1].isEmpty, parts[1] != "HEAD",
                  seen.insert(parts[1]).inserted
            else { continue }
            choices.append(BranchChoice(name: parts[1], remoteRef: parts[0]))
        }
        return choices
    }

    /// Update every remote's branches, dropping ones deleted upstream.
    static func fetchAll(repositoryPath: String) throws {
        try run(["fetch", "--all", "--prune", "--quiet"], in: repositoryPath)
    }

    /// Default location for a new worktree: a sibling `<repo>-worktrees` folder.
    static func defaultWorktreePath(repositoryPath: String, branch: String) -> String {
        let repoURL = URL(fileURLWithPath: repositoryPath)
        let container = repoURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(repoURL.lastPathComponent)-worktrees", isDirectory: true)
        // Branch names can contain slashes, which would nest directories.
        let folder = branch.replacingOccurrences(of: "/", with: "-")
        return container.appendingPathComponent(folder, isDirectory: true).path
    }

    /// Fetch `origin` and return its default branch (e.g. "origin/master"), so new
    /// branches start from what's on the remote rather than a stale local HEAD.
    /// nil when there's no origin or it can't be reached.
    static func freshRemoteBase(for repositoryPath: String) -> String? {
        let remotes = (try? run(["remote"], in: repositoryPath)) ?? ""
        guard remotes.components(separatedBy: .newlines).contains("origin"),
              (try? run(["fetch", "--quiet", "origin"], in: repositoryPath)) != nil
        else { return nil }

        if let head = try? run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repositoryPath) {
            let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        // origin/HEAD isn't set when the repo wasn't cloned; guess the usual names.
        return ["origin/master", "origin/main"].first { ref in
            (try? run(["rev-parse", "--verify", "--quiet", ref], in: repositoryPath)) != nil
        }
    }

    /// Create a worktree. When `createBranch` is true the branch is created from
    /// `startPoint`, or else from a freshly fetched origin default branch (falling
    /// back to the current HEAD). Otherwise an existing branch is used.
    static func addWorktree(
        repositoryPath: String,
        path: String,
        branch: String,
        createBranch: Bool,
        startPoint: String? = nil,
        track: Bool = false
    ) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var arguments = ["worktree", "add"]
        if createBranch {
            if let startPoint, !startPoint.isEmpty {
                if track { arguments.append("--track") }
                arguments += ["-b", branch, path, startPoint]
            } else if let remoteBase = freshRemoteBase(for: repositoryPath) {
                // --no-track so the new branch doesn't treat origin/master as its upstream.
                arguments += ["--no-track", "-b", branch, path, remoteBase]
            } else {
                arguments += ["-b", branch, path]
            }
        } else {
            arguments += [path, branch]
        }
        try run(arguments, in: repositoryPath)
    }

    /// The worktree a bare branch name asks for, for a client that can't be
    /// shown the sheet. It decides what the sheet's two modes decide between:
    /// a local branch is checked out, one that only exists on a remote gets a
    /// local branch tracking it, and any other name is a new branch.
    ///
    /// Remotes are fetched first unless the branch is already here — the
    /// sheet does the same when it opens — so a branch pushed a minute ago is
    /// found on its remote rather than created again from scratch.
    static func worktreeRequest(repositoryPath: String, branch: String) -> NewWorktreeRequest {
        let path = defaultWorktreePath(repositoryPath: repositoryPath, branch: branch)
        if ((try? branches(for: repositoryPath)) ?? []).contains(branch) {
            return NewWorktreeRequest(branch: branch, path: path, createBranch: false, startPoint: nil)
        }

        try? fetchAll(repositoryPath: repositoryPath)
        let remote = branchChoices(for: repositoryPath).first { $0.name == branch }?.remoteRef
        return NewWorktreeRequest(
            branch: branch, path: path, createBranch: true,
            startPoint: remote, trackStartPoint: remote != nil)
    }

    static func removeWorktree(
        repositoryPath: String,
        path: String,
        force: Bool = false
    ) throws {
        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(path)
        try run(arguments, in: repositoryPath)
    }

    /// Forget worktrees whose folders have been deleted.
    static func pruneWorktrees(repositoryPath: String) throws {
        try run(["worktree", "prune"], in: repositoryPath)
    }

    /// The shared `.git` directory, which is the same for every worktree.
    static func commonDirectory(for repositoryPath: String) -> String? {
        guard let output = try? run(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            in: repositoryPath
        ) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
