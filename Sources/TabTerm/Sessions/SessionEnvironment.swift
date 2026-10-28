import Foundation
import GhosttyKit

/// How a session's shell is started: what to exec, with which arguments and
/// environment, and where.
struct SpawnPlan: Equatable {
    var path: String
    var arguments: [String]
    var environment: [String: String]
    var directory: String?
}

/// Builds a session's shell the way Ghostty would have built it.
///
/// Before sessions, libghostty spawned every pane's shell itself. Now Workbench
/// does, and the pane's Ghostty surface runs the attach process instead — so
/// everything Ghostty used to do for the shell has to be done here, or the
/// shell notices the difference:
///
/// - **The environment.** Ghostty gives its child `TERM=xterm-ghostty`,
///   `TERMINFO`, `COLORTERM`, `TERM_PROGRAM`, `GHOSTTY_RESOURCES_DIR`,
///   `GHOSTTY_SHELL_FEATURES`, your config's `env` entries and so on. The
///   attach process is that child, so it forwards the environment it was given
///   and the shell starts from exactly that.
/// - **Shell integration.** Ghostty only injects it when the command it runs is
///   a shell, and the attach process isn't one. It is what reports the current
///   directory — which resume and "new tab in the same folder" depend on — so
///   it is injected here instead, the same way: `ZDOTDIR` for zsh, `ENV` and
///   `--posix` for bash, `XDG_DATA_DIRS` for fish and elvish.
/// - **A login shell through `login(1)`.** On macOS Ghostty runs
///   `/usr/bin/login -flp $USER /bin/bash --noprofile --norc -c "exec -l <shell>"`,
///   which is what makes every terminal a login shell with hushlogin honoured.
///   Mirrored exactly.
enum SessionEnvironment {
    /// Variables that describe the attach process rather than a new shell.
    private static let transient: Set<String> = ["_", "SHLVL", "PWD", "OLDPWD"]

    /// Markers Claude Code exports to its own subprocesses. Workbench inherits
    /// them when it's launched from a Claude Code session, and a `claude` run
    /// in a shell that has them thinks it's nested and stops saving transcripts.
    private static let claudeCodeSession: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_PID", "CLAUDE_EFFORT",
    ]

    static func plan(
        command: String?,
        directory: String?,
        ghosttyEnvironment: [String: String]?,
        extra: [String: String]
    ) -> SpawnPlan {
        var environment = ghosttyEnvironment ?? fallbackEnvironment()
        for key in transient.union(claudeCodeSession) { environment.removeValue(forKey: key) }
        for (key, value) in extra { environment[key] = value }

        let account = Account.current
        let shellCommand: String
        if let command {
            shellCommand = command
            // A command that is itself a shell gets integration too, as it
            // would in Ghostty; anything else runs as given.
            if let first = command.split(separator: " ").first {
                injectIntegration(
                    shellPath: String(first),
                    environment: &environment,
                    home: account.home,
                    commandMode: true
                )
            }
        } else {
            let shell = account.shell
            let extraArguments = injectIntegration(
                shellPath: shell,
                environment: &environment,
                home: account.home
            )
            shellCommand = ([shell] + extraArguments).map(AgentSession.shellQuoted).joined(separator: " ")
        }

        let workingDirectory = directory.flatMap { path -> String? in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue ? path : nil
        } ?? account.home

        guard let user = account.name, FileManager.default.isExecutableFile(atPath: "/usr/bin/login") else {
            // No account to log in as: run the shell directly, as a login shell.
            return SpawnPlan(
                path: "/bin/sh",
                arguments: ["-sh", "-c", "exec -l \(shellCommand)"],
                environment: environment,
                directory: workingDirectory
            )
        }

        var arguments = ["login"]
        if account.hushLogin { arguments.append("-q") }
        arguments += ["-flp", user, "/bin/bash", "--noprofile", "--norc", "-c", "exec -l \(shellCommand)"]
        return SpawnPlan(
            path: "/usr/bin/login",
            arguments: arguments,
            environment: environment,
            directory: workingDirectory
        )
    }

    // MARK: - Shell integration

    /// Set up Ghostty's shell integration for `shellPath`, returning any
    /// arguments the shell needs added. Mirrors `shell_integration.zig`.
    @discardableResult
    private static func injectIntegration(
        shellPath: String,
        environment: inout [String: String],
        home: String,
        commandMode: Bool = false
    ) -> [String] {
        let mode = GhosttyApp.shared.shellIntegrationMode ?? "detect"
        guard mode != "none",
              let resources = environment["GHOSTTY_RESOURCES_DIR"] ?? bundledResourcesDirectory
        else { return [] }

        let integration = "\(resources)/shell-integration"
        // `shell-integration = zsh` and friends force a shell; `detect` goes
        // by the executable's name, as Ghostty does.
        let shell = mode == "detect" ? (shellPath as NSString).lastPathComponent : mode

        switch shell {
        case "zsh":
            guard FileManager.default.fileExists(atPath: "\(integration)/zsh") else { return [] }
            if let existing = environment["ZDOTDIR"] {
                environment["GHOSTTY_ZSH_ZDOTDIR"] = existing
            }
            environment["ZDOTDIR"] = "\(integration)/zsh"
            return []

        case "bash":
            // Apple's /bin/bash 3.2 has the ENV startup path patched out, so
            // Ghostty leaves it alone and so do we. A command line that runs
            // its own script isn't interactive either.
            guard shellPath != "/bin/bash", !commandMode else { return [] }
            let script = "\(integration)/bash/ghostty.bash"
            guard FileManager.default.fileExists(atPath: script) else { return [] }
            if let existing = environment["ENV"] {
                environment["GHOSTTY_BASH_ENV"] = existing
            }
            environment["ENV"] = script
            environment["GHOSTTY_BASH_INJECT"] = "1"
            if environment["HISTFILE"] == nil {
                environment["HISTFILE"] = "\(home)/.bash_history"
                environment["GHOSTTY_BASH_UNEXPORT_HISTFILE"] = "1"
            }
            return ["--posix"]

        case "fish", "elvish":
            guard FileManager.default.fileExists(atPath: integration) else { return [] }
            environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] = integration
            let existing = environment["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
            environment["XDG_DATA_DIRS"] = existing.isEmpty ? integration : "\(integration):\(existing)"
            return []

        default:
            return []
        }
    }

    // MARK: - Without Ghostty's environment

    /// `Contents/Resources/ghostty` inside the app bundle.
    static var bundledResourcesDirectory: String? {
        let path = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/ghostty").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// What Ghostty would have added, for a session started before any pane
    /// attached to it — which shouldn't happen, but a shell with a sensible
    /// environment beats one with none.
    static func fallbackEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        let terminfo = resources.appendingPathComponent("terminfo").path
        if FileManager.default.fileExists(atPath: terminfo + "/78/xterm-ghostty") {
            environment["TERM"] = "xterm-ghostty"
            environment["TERMINFO"] = terminfo
        } else {
            environment["TERM"] = "xterm-256color"
        }
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "ghostty"
        if let ghostty = bundledResourcesDirectory {
            environment["GHOSTTY_RESOURCES_DIR"] = ghostty
        }
        environment["GHOSTTY_SHELL_FEATURES"] = "cursor:blink,path,title"
        return environment
    }

    // MARK: - The account

    struct Account {
        var name: String?
        var home: String
        var shell: String
        /// `~/.hushlogin` exists, so login(1) should stay quiet.
        var hushLogin: Bool

        static var current: Account {
            var name: String?
            var home = NSHomeDirectory()
            var shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            if let entry = getpwuid(getuid()) {
                name = String(cString: entry.pointee.pw_name)
                home = String(cString: entry.pointee.pw_dir)
                let loginShell = String(cString: entry.pointee.pw_shell)
                if !loginShell.isEmpty { shell = loginShell }
            }
            let hush = FileManager.default.fileExists(atPath: "\(home)/.hushlogin")
            return Account(name: name, home: home, shell: shell, hushLogin: hush)
        }
    }
}
