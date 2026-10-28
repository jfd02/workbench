import Darwin
import Foundation

/// What a terminal is running right now.
///
/// libghostty hands us the pid of the pty's foreground process group; this
/// turns that into the command line that started it, which is how a tab knows
/// it is running Claude Code rather than a shell prompt.
enum ForegroundProcess {
    /// A process's executable path followed by its arguments, or an empty
    /// array when it can't be read — the process exited, or it belongs to
    /// another user.
    static func commandLine(of pid: pid_t) -> [String] {
        guard pid > 0 else { return [] }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else { return [] }
        buffer.removeLast(buffer.count - size)

        // Layout: argc, the executable path, padding NULs, then argc
        // NUL-terminated arguments.
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size

        func nextString() -> String? {
            guard index < buffer.count else { return nil }
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }

        guard let executable = nextString() else { return [] }
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < argc, let argument = nextString() {
            arguments.append(argument)
        }
        return [executable] + arguments
    }

    /// A coding agent Workbench knows how to pick back up.
    enum Agent: String {
        case claude
        case codex
    }

    static func agent(pid: pid_t) -> Agent? {
        agent(commandLine: commandLine(of: pid))
    }

    /// Which agent a command line is, if any.
    ///
    /// Only the executable and the first couple of arguments are considered,
    /// which covers the shapes they actually run as — a `claude` or `codex`
    /// binary, and `node .../@anthropic-ai/claude-code/cli.js` from an npm
    /// install — without matching an editor that happens to have been handed a
    /// file called `claude.md`.
    static func agent(commandLine: [String]) -> Agent? {
        for argument in commandLine.prefix(3) {
            let name = (argument as NSString).lastPathComponent
            if name == "claude" || name == "claude-code" { return .claude }
            if name == "codex" { return .codex }
            if argument.contains("@anthropic-ai/claude-code") { return .claude }
            if argument.contains("@openai/codex") { return .codex }
        }
        return nil
    }

    static func isClaude(pid: pid_t) -> Bool {
        agent(pid: pid) == .claude
    }

    static func isClaude(commandLine: [String]) -> Bool {
        agent(commandLine: commandLine) == .claude
    }
}
