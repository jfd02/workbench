import Foundation

/// A coding agent that was running in a terminal, and enough to pick it back up.
///
/// The command line is replayed as it was recorded rather than rebuilt from the
/// agent's name. `claude` is usually reached through a shell alias — `clauded`
/// standing for `claude --dangerously-skip-permissions`, say — and only the
/// expansion reaches the process table, so replaying argv is the only way to
/// bring a session back with the flags it was started under. Synthesizing
/// `claude --resume` instead would quietly drop them, and turning permission
/// skipping on for every restored pane would be worse: it would apply to panes
/// that were deliberately started without it.
struct AgentSession: Codable, Equatable {
    /// `ForegroundProcess.Agent.rawValue`, kept as a string so a session
    /// written by a build that knows more agents than this one still decodes.
    var agent: String

    /// The session id the agent reported through its hook.
    var sessionID: String

    /// The command line that started it, with any resume flags taken out.
    var argv: [String]

    /// Where the agent keeps this session's transcript, when the hook said.
    /// Used to notice a session that has since been deleted.
    var transcript: String?

    var kind: ForegroundProcess.Agent? { ForegroundProcess.Agent(rawValue: agent) }

    /// Describe a live process, or nil when there is nothing resumable about it.
    ///
    /// `commandLine` is the argv `ForegroundProcess` read out of the kernel.
    init?(
        agent: ForegroundProcess.Agent,
        sessionID: String,
        commandLine: [String],
        transcript: String? = nil
    ) {
        guard !sessionID.isEmpty, !commandLine.isEmpty else { return nil }
        guard let argv = Self.stripped(commandLine, for: agent) else { return nil }

        self.agent = agent.rawValue
        self.sessionID = sessionID
        self.argv = argv
        self.transcript = transcript
    }

    /// Whether this is still worth typing out.
    ///
    /// A transcript we were told about and can no longer find means the session
    /// was deleted between quitting and reopening; resuming it would only put
    /// an error on the user's prompt. A session we were never told a path for
    /// is given the benefit of the doubt.
    var isResumable: Bool {
        guard kind != nil, !sessionID.isEmpty, !argv.isEmpty else { return false }
        guard let transcript else { return true }
        return FileManager.default.fileExists(atPath: transcript)
    }

    /// The command line to type back into a fresh shell, or nil when there
    /// isn't one worth typing.
    var resumeCommand: String? {
        guard isResumable, let kind else { return nil }

        let words: [String]
        switch kind {
        case .claude:
            // `--resume <id>` reads the same whether or not the recorded argv
            // already had flags of its own.
            words = argv + ["--resume", sessionID]
        case .codex:
            // Resuming is a subcommand rather than a flag, and it takes the
            // same options as a plain `codex`, so the recorded flags move
            // across it: `codex --search` comes back as
            // `codex resume --search <id>`.
            words = [argv[0], "resume"] + argv.dropFirst() + [sessionID]
        }
        return words.map(Self.shellQuoted).joined(separator: " ")
    }

    // MARK: - Recording

    /// The command line to remember, with anything that resumes a session taken
    /// out — otherwise a pane restored twice accumulates `--resume` flags.
    ///
    /// Returns nil when the command line isn't one to come back to:
    ///
    /// - A prompt on it. `claude "fix the tests"` is an instruction that has
    ///   already been given; replaying it would hand the agent the same job a
    ///   second time, unasked, in whatever permission mode it was started in.
    ///   Rather than try to strip it — and risk being wrong about what is a
    ///   prompt and what is a flag's value — the pane is left as a plain shell.
    /// - A codex subcommand other than `resume`. `codex exec` is a one-shot
    ///   run, not a session.
    static func stripped(_ commandLine: [String], for agent: ForegroundProcess.Agent) -> [String]? {
        guard let executable = commandLine.first else { return nil }
        var rest = Array(commandLine.dropFirst())

        // argv[1] repeating the executable is how the kernel reports argv[0];
        // it isn't an argument.
        if rest.first.map({ ($0 as NSString).lastPathComponent })
            == (executable as NSString).lastPathComponent {
            rest.removeFirst()
        }

        let takesValue = Self.valueFlags[agent] ?? []
        var kept: [String] = []
        var index = rest.startIndex
        var namedItself = false
        var sawSubcommand = false

        while index < rest.endIndex {
            let argument = rest[index]
            index += 1

            guard argument.hasPrefix("-") else {
                // A bare word. An agent run through a runtime — `node
                // .../claude-code/cli.js` — names itself in an argument rather
                // than in the executable, and that word is part of how it is
                // started, not something it was asked to do.
                if !namedItself, ForegroundProcess.agent(commandLine: [argument]) == agent {
                    namedItself = true
                    kept.append(argument)
                    continue
                }
                // For codex the next one is the subcommand.
                if agent == .codex, !sawSubcommand {
                    sawSubcommand = true
                    guard argument == "resume" else { return nil }
                    // Any session id after it belongs to the run before this one.
                    if index < rest.endIndex, !rest[index].hasPrefix("-") { index += 1 }
                    continue
                }
                // Anything else is a prompt, and not ours to send again.
                return nil
            }

            if Self.resumeFlags[agent]?.contains(argument) == true {
                // Both `--resume` and `--continue` take an optional id.
                if index < rest.endIndex, !rest[index].hasPrefix("-") { index += 1 }
                continue
            }
            if argument.hasPrefix("--resume=") { continue }

            kept.append(argument)

            // A flag's value is not a prompt, so carry it across with the flag.
            if takesValue.contains(argument), index < rest.endIndex, !rest[index].hasPrefix("-") {
                kept.append(rest[index])
                index += 1
            }
        }
        return [executable] + kept
    }

    /// Flags that resume a session, which the recorded command line has to lose
    /// so that restoring a pane twice doesn't stack them up.
    private static let resumeFlags: [ForegroundProcess.Agent: Set<String>] = [
        .claude: ["-r", "--resume", "-c", "--continue"],
        .codex: ["--last"],
    ]

    /// Flags whose value is the next argument.
    ///
    /// This is what tells `--model opus` from a prompt. Being out of date here
    /// is safe in the one direction that matters: an unknown flag's value reads
    /// as a prompt, and a pane with a prompt in it is simply not resumed. A
    /// prompt is never mistaken for a flag's value. Flags whose value is
    /// optional are deliberately left out for the same reason.
    private static let valueFlags: [ForegroundProcess.Agent: Set<String>] = [
        .claude: [
            "--add-dir", "--agent", "--agents", "--append-system-prompt", "--autocompact",
            "--betas", "--debug-file", "--effort", "--environment", "--fallback-model",
            "--file", "--input-format", "--json-schema", "--max-budget-usd", "--mcp-config",
            "--model", "-n", "--name", "--output-format", "--permission-mode",
            "--permission-prompts", "--plugin-dir", "--plugin-url", "--session-id",
            "--setting-sources", "--settings", "--system-prompt", "--system-prompt-snapshot",
            "--tools",
        ],
        .codex: [
            "-a", "--ask-for-approval", "--add-dir", "-C", "--cd", "-c", "--config",
            "--disable", "--enable", "-i", "--image", "--local-provider", "-m", "--model",
            "-p", "--profile", "--remote", "--remote-auth-token-env", "-s", "--sandbox",
        ],
    ]

    // MARK: - Quoting

    /// Characters that survive a shell unquoted. Anything else — a space in a
    /// path, most obviously — gets single quotes.
    private static let safe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:=@%+,-"
    )

    static func shellQuoted(_ word: String) -> String {
        guard !word.isEmpty else { return "''" }
        guard word.rangeOfCharacter(from: safe.inverted) != nil else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
