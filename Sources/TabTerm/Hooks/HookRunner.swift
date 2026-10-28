import Foundation
import Darwin
import os

/// Versioned public payload. Optional fields are omitted when they don't apply.
struct HookEvent: Codable {
    var schemaVersion = 1
    var id = UUID().uuidString
    var event: String
    var timestamp = ISO8601DateFormatter().string(from: Date())
    var repositoryPath: String?
    var worktreePath: String?
    var branch: String?
    var workspaceID: String?
    var terminalID: String?
    var agent: String?
    var agentSessionID: String?

    var workingDirectory: String {
        if event != "worktree.removed", let worktreePath { return worktreePath }
        return repositoryPath ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
}

struct HookCommand: Decodable {
    let command: String
    let timeoutSeconds: Double

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let command = try? value.decode(String.self) {
            self.command = command
            timeoutSeconds = 60
        } else {
            struct Options: Decodable {
                var command: String
                var timeoutSeconds: Double?
            }
            let options = try value.decode(Options.self)
            command = options.command
            timeoutSeconds = options.timeoutSeconds ?? 60
        }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              timeoutSeconds.isFinite, (0.1...3600).contains(timeoutSeconds) else {
            throw DecodingError.dataCorruptedError(in: value,
                debugDescription: "Hooks need a command and a timeoutSeconds between 0.1 and 3600")
        }
    }
}

/// Runs serially off the UI thread. Failures never cancel the originating action
/// or subsequent hooks. Configuration is re-read for each delivered event.
final class HookRunner {
    private let queue = DispatchQueue(label: "com.tabterm.user-hooks", qos: .utility)
    private let globalConfig: URL?
    private let logDirectory: URL
    private let logger = Logger(subsystem: "com.tabterm.TabTerm", category: "hooks")

    init(globalConfig: URL?, logDirectory: URL) {
        self.globalConfig = globalConfig
        self.logDirectory = logDirectory
    }

    func emit(_ event: HookEvent) {
        queue.async { self.deliver(event) }
    }

    /// A barrier for tests and callers that explicitly need delivery to finish.
    func flush() { queue.sync {} }

    private func deliver(_ event: HookEvent) {
        var configs = [URL]()
        if let globalConfig { configs.append(globalConfig) }
        if let repository = event.repositoryPath {
            configs.append(URL(fileURLWithPath: repository).appendingPathComponent(".tabterm.json"))
        }
        for config in configs {
            for hook in commands(in: config, event: event) { run(hook, event: event) }
        }
    }

    private func commands(in url: URL, event: HookEvent) -> [HookCommand] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            // Ignore unrelated top-level settings, including the legacy hook.
            struct Config: Decodable { var hooks: [String: [HookCommand]]? }
            let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
            return (config.hooks?[event.event] ?? []) + (config.hooks?["*"] ?? [])
        } catch {
            log("\(event.event) config \(url.path): \(error.localizedDescription)")
            return []
        }
    }

    private func run(_ hook: HookCommand, event: HookEvent) {
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workbench-hook-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: inputURL) }
        do {
            var payload = try JSONEncoder().encode(event)
            payload.append(0x0a)
            try payload.write(to: inputURL, options: .atomic)
            let input = try FileHandle(forReadingFrom: inputURL)
            defer { try? input.close() }
            let output = HookOutput()
            defer { output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", hook.command]
            process.currentDirectoryURL = URL(fileURLWithPath: event.workingDirectory)
            var env = ProcessInfo.processInfo.environment
            // A Finder-launched app may have a minimal PATH.
            env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin"
            env["WORKBENCH_EVENT"] = event.event
            env["WORKBENCH_EVENT_ID"] = event.id
            env["WORKBENCH_REPOSITORY_PATH"] = event.repositoryPath ?? ""
            env["WORKBENCH_WORKTREE_PATH"] = event.worktreePath ?? ""
            env["WORKBENCH_BRANCH"] = event.branch ?? ""
            env["WORKBENCH_WORKSPACE_ID"] = event.workspaceID ?? ""
            env["WORKBENCH_TERMINAL_ID"] = event.terminalID ?? ""
            env["WORKBENCH_AGENT"] = event.agent ?? ""
            env["WORKBENCH_AGENT_SESSION_ID"] = event.agentSessionID ?? ""
            process.environment = env
            process.standardInput = input
            process.standardOutput = output.pipe
            process.standardError = output.pipe
            try process.run()
            let pid = process.processIdentifier
            // Foundation starts a separate process group on macOS. Check it
            // before ever signalling a group, so the app cannot kill its own.
            let ownsGroup = getpgid(pid) == pid
            try? output.pipe.fileHandleForWriting.close()
            let deadline = ProcessInfo.processInfo.systemUptime + hook.timeoutSeconds
            var timedOut = false
            while process.isRunning {
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    timedOut = true
                    kill(ownsGroup ? -pid : pid, SIGKILL)
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            process.waitUntilExit()
            let captured = output.close()
            let result = timedOut ? "timed out after \(hook.timeoutSeconds)s" : "exit \(process.terminationStatus)"
            log("\(event.event) [\(event.id)] \(hook.command): \(result)\n\(captured)")
        } catch {
            log("\(event.event) [\(event.id)] couldn't run \(hook.command): \(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let url = logDirectory.appendingPathComponent("hooks.log")
            let old = logDirectory.appendingPathComponent("hooks.previous.log")
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 1_048_576 {
                try? FileManager.default.removeItem(at: old)
                try FileManager.default.moveItem(at: url, to: old)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8))
        } catch {
            logger.error("Couldn't write hook log: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Drain noisy commands without holding unbounded output or waiting for a
/// detached grandchild to close stdout. Keep the first 64 KiB for diagnostics.
private final class HookOutput {
    let pipe = Pipe()
    private let lock = NSLock()
    private var data = Data()
    private var closed = false
    private var truncated = false

    init() {
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if !self.closed { self.drain() }
        }
    }

    private func drain() {
        var bytes = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<16 {
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            let kept = min(count, 65_536 - data.count)
            data.append(contentsOf: bytes.prefix(kept))
            if kept < count { truncated = true }
        }
    }

    @discardableResult
    func close() -> String {
        lock.lock()
        defer { lock.unlock() }
        if !closed {
            drain()
            closed = true
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        return String(decoding: data, as: UTF8.self) + (truncated ? "\n[output truncated]" : "")
    }
}
