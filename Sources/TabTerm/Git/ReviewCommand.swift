import Foundation

/// Bounded, noninteractive commands for the review panel. Call off the main thread.
/// Files drain both streams independently, avoiding a full stderr pipe blocking stdout.
enum ReviewCommand {
    static func run(_ executable: URL, _ arguments: [String], in directory: String,
                    timeout: TimeInterval = 20, limit: Int = 4 * 1024 * 1024) throws -> Data {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-review-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stdout = temporary.appendingPathComponent("out")
        let stderr = temporary.appendingPathComponent("err")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let out = try FileHandle(forWritingTo: stdout)
        let err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["GIT_LITERAL_PATHSPECS"] = "1"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_PAGER"] = "cat"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
            throw GitError.commandFailed("Request timed out. Try Refresh.")
        }
        guard process.terminationStatus == 0 else {
            let handle = try FileHandle(forReadingFrom: stderr)
            defer { try? handle.close() }
            let message = String(decoding: try handle.read(upToCount: 4096) ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(message.isEmpty ? "Command failed (\(process.terminationStatus))." : message)
        }
        let handle = try FileHandle(forReadingFrom: stdout)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw GitError.commandFailed("Result is too large to display. Open this worktree in your editor.")
        }
        return data
    }

    static func git(_ arguments: [String], in directory: String, limit: Int = 4 * 1024 * 1024) throws -> String {
        guard let git = GitService.executableURL else { throw GitError.gitNotFound }
        return String(decoding: try run(git, arguments, in: directory, limit: limit), as: UTF8.self)
    }
}
