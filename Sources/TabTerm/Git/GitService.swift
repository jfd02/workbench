import Foundation

/// One entry from `git worktree list`.
struct GitWorktree: Equatable {
    var path: String
    /// Branch short name, or nil when the worktree is detached.
    var branch: String?
    var isMain: Bool
    var isLocked: Bool

    var displayName: String {
        branch ?? URL(fileURLWithPath: path).lastPathComponent
    }
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
        var locked = false

        func flush() {
            guard let path else { return }
            result.append(
                GitWorktree(
                    path: path,
                    branch: branch,
                    // git always lists the main working tree first.
                    isMain: result.isEmpty,
                    isLocked: locked
                )
            )
            branch = nil
            locked = false
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
            } else if line == "locked" || line.hasPrefix("locked ") {
                locked = true
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

    /// Create a worktree. When `createBranch` is true the branch is created from
    /// `startPoint` (or the current HEAD), otherwise an existing branch is used.
    static func addWorktree(
        repositoryPath: String,
        path: String,
        branch: String,
        createBranch: Bool,
        startPoint: String? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var arguments = ["worktree", "add"]
        if createBranch {
            arguments += ["-b", branch, path]
            if let startPoint, !startPoint.isEmpty { arguments.append(startPoint) }
        } else {
            arguments += [path, branch]
        }
        try run(arguments, in: repositoryPath)
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
}
