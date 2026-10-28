import Foundation
import os

/// A command a repository asks Workbench to run once one of its worktrees is gone.
///
/// The repository names it in `.tabterm.json` at the top of its main checkout:
///
///     { "worktreeRemoved": "./prune.sh" }
///
/// It is for what a worktree leaves behind outside its folder that only the
/// repository knows about, such as databases, copies on another machine, or
/// devices it reserved. The worktree no longer exists, so the command runs in
/// the main checkout, through `/bin/sh -c`, with the removed paths in
/// `TABTERM_REMOVED_WORKTREES`, one per line. Nothing waits for it; a failure
/// is logged.
enum RemovedWorktreeCommand {
    static let fileName = ".tabterm.json"

    private static let logger = Logger(subsystem: "com.tabterm.TabTerm", category: "worktrees")

    private struct Config: Decodable {
        let worktreeRemoved: String?
    }

    /// Run the repository's command for the worktrees that have been removed,
    /// in the background. A path that still exists on disk is skipped.
    static func run(forRemovedWorktrees worktreePaths: [String], checkoutPath: String?) {
        let removed = worktreePaths.filter { !FileManager.default.fileExists(atPath: $0) }
        guard !removed.isEmpty, let checkoutPath else { return }

        DispatchQueue.global(qos: .utility).async {
            guard let command = command(in: checkoutPath) else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = URL(fileURLWithPath: checkoutPath)
            var environment = ProcessInfo.processInfo.environment
            environment["TABTERM_REMOVED_WORKTREES"] = removed.joined(separator: "\n")
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                guard process.terminationStatus != 0 else { return }
                logger.error("""
                    \(command, privacy: .public) in \(checkoutPath, privacy: .public) \
                    exited with \(process.terminationStatus)
                    """)
            }
            do {
                try process.run()
            } catch {
                logger.error("""
                    couldn't run \(command, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
    }

    /// The command the checkout's `.tabterm.json` names, if it names one.
    private static func command(in checkoutPath: String) -> String? {
        let url = URL(fileURLWithPath: checkoutPath).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let config = try? JSONDecoder().decode(Config.self, from: data) else {
            logger.warning("\(url.path, privacy: .public) isn't the JSON Workbench expects")
            return nil
        }
        return config.worktreeRemoved.flatMap { $0.isEmpty ? nil : $0 }
    }
}
