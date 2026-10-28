import Foundation

/// Registers Workbench's status hook with the coding agents it knows about.
///
/// Claude Code and codex will both run a command of our choosing at the edges
/// of a turn, and that is the only way to know what they are doing — and which
/// session they are in — without reading the screen. The hooks live in the
/// user's home directory rather than in a per-project file so a worktree needs
/// no setup, and every entry we write names our own script — which is how they
/// are found again to be updated or removed, and why the rest of each file,
/// including the user's own hooks, is left alone.
///
/// The script is a no-op outside Workbench: it exits immediately unless the
/// terminal it runs in exported `TABTERM_AGENT_ID`, so an agent started from
/// any other terminal behaves exactly as it did before.
enum AgentHooks {
    static let scriptName = "tabterm-agent-hook.sh"

    /// Header comment, so the script says what it is to anyone who finds it.
    static let marker = "# Workbench agent status hook v3"

    /// `~/Library/Application Support/TabTerm/hooks/tabterm-agent-hook.sh`
    static let scriptURL: URL = AppSupport.directory
        .appendingPathComponent("hooks", isDirectory: true)
        .appendingPathComponent(scriptName)

    /// One agent's hook configuration, and what it understands.
    ///
    /// Both files are shaped the same — a top-level `hooks` object keyed by
    /// event name — so one set of merge functions serves both.
    struct Target {
        let agent: ForegroundProcess.Agent
        let settingsURL: URL
        /// The events this agent actually has. Ours are a superset: codex has
        /// no `Notification` or `StopFailure`, and writing an event it doesn't
        /// know risks it rejecting the whole file.
        let events: Set<String>
    }

    static let targets: [Target] = [
        Target(
            agent: .claude,
            settingsURL: home(".claude", "settings.json"),
            events: [
                "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                "PostToolUseFailure", "PermissionRequest", "PermissionDenied",
                "Notification", "Stop", "StopFailure", "PreCompact", "PostCompact",
                "Elicitation", "ElicitationResult",
            ]
        ),
        Target(
            agent: .codex,
            settingsURL: home(".codex", "hooks.json"),
            events: [
                "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                "PermissionRequest", "Stop", "Interrupt", "PreCompact", "PostCompact",
            ]
        ),
    ]

    private static func home(_ directory: String, _ file: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(file)
    }

    /// One hook event, and the matcher it needs to be narrowed with.
    struct Registration {
        let event: String
        let matcher: String?
    }

    /// The events that mark the edges of a turn.
    ///
    /// Tool and compaction events repair missed starts; tool results and
    /// elicitation responses clear a permission/question state once answered.
    ///
    /// `Notification` is narrowed to the two types that mean Claude has stopped
    /// and is waiting. `idle_prompt` repairs a missed Stop silently instead of
    /// turning an idle reminder into a new permission prompt or completion.
    static let registrations: [Registration] = [
        Registration(event: "SessionStart", matcher: nil),
        Registration(event: "SessionEnd", matcher: nil),
        Registration(event: "UserPromptSubmit", matcher: nil),
        Registration(event: "PreToolUse", matcher: "*"),
        Registration(event: "PostToolUse", matcher: "*"),
        Registration(event: "PostToolUseFailure", matcher: "*"),
        Registration(event: "PermissionRequest", matcher: "*"),
        Registration(event: "PermissionDenied", matcher: "*"),
        Registration(event: "Notification", matcher: "permission_prompt|elicitation_dialog|idle_prompt"),
        Registration(event: "PreCompact", matcher: nil),
        Registration(event: "PostCompact", matcher: nil),
        Registration(event: "Elicitation", matcher: "*"),
        Registration(event: "ElicitationResult", matcher: "*"),
        Registration(event: "Interrupt", matcher: nil),
        Registration(event: "Stop", matcher: nil),
        Registration(event: "StopFailure", matcher: nil),
    ]

    /// The registrations one agent can actually take.
    static func registrations(for target: Target) -> [Registration] {
        registrations.filter { target.events.contains($0.event) }
    }

    // MARK: - Installing

    /// Write the script and merge the hook entries into every agent's file.
    /// Safe to call on every launch: nothing is written when nothing changed.
    static func install() {
        do {
            try writeScript()
        } catch {
            Ghostty.logger.warning(
                "could not write the agent hook: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        for target in targets {
            // Don't conjure a config directory for an agent the user doesn't
            // have. If they install one later, the next launch picks it up.
            guard FileManager.default.fileExists(
                atPath: target.settingsURL.deletingLastPathComponent().path
            ) else { continue }

            do {
                try updateSettings(target)
            } catch {
                Ghostty.logger.warning(
                    """
                    could not register \(target.agent.rawValue, privacy: .public) hooks: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
    }

    private static func writeScript() throws {
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let existing = try? String(contentsOf: scriptURL, encoding: .utf8)
        if existing != script {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
    }

    private static func updateSettings(_ target: Target) throws {
        let existing = read(target.settingsURL) ?? [:]
        let updated = settings(byAdding: existing, scriptPath: scriptURL.path, target: target)

        let data = try JSONSerialization.data(
            withJSONObject: updated,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        // Don't rewrite an unchanged file: the mtime is what tells an agent to
        // reload its settings mid-session.
        if let current = try? Data(contentsOf: target.settingsURL), current == data { return }

        try FileManager.default.createDirectory(
            at: target.settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: target.settingsURL, options: .atomic)
    }

    private static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return object as? [String: Any]
    }

    // MARK: - Merging
    //
    // Kept as plain functions over the decoded JSON so the self-test can run
    // them against fixtures rather than the user's real settings file.

    /// The shell an agent runs for one event.
    ///
    /// The event name and the agent are passed as arguments rather than read
    /// back out of the payload on stdin. The two agents don't name themselves
    /// in the payload, and the registration already knows both values.
    static func command(
        scriptPath: String,
        event: String,
        agent: ForegroundProcess.Agent
    ) -> String {
        let quoted = shellQuoted(scriptPath)
        // `|| true` so a hook that can't run never surfaces as an error in the
        // user's session — a missing dot is not worth interrupting them for.
        return "[ -x \(quoted) ] && \(quoted) \(event) \(agent.rawValue) || true"
    }

    static func settings(
        byAdding existing: [String: Any],
        scriptPath: String,
        target: Target
    ) -> [String: Any] {
        var settings = existing
        var hooks = stripped(existing["hooks"] as? [String: Any] ?? [:], scriptPath: scriptPath)

        for registration in registrations(for: target) {
            // A shape we don't understand is left exactly as it is rather than
            // replaced with ours.
            if let present = hooks[registration.event], !(present is [[String: Any]]) { continue }

            var entry: [String: Any] = [
                "hooks": [
                    [
                        "type": "command",
                        "command": command(
                            scriptPath: scriptPath,
                            event: registration.event,
                            agent: target.agent
                        ),
                    ]
                ]
            ]
            if let matcher = registration.matcher { entry["matcher"] = matcher }

            var entries = hooks[registration.event] as? [[String: Any]] ?? []
            entries.append(entry)
            hooks[registration.event] = entries
        }

        settings["hooks"] = hooks
        return settings
    }

    /// Drop every command that runs our script, keeping everything around it.
    ///
    /// Matched on the script's file name rather than its full path, so entries
    /// left behind by an install that lived somewhere else are reaped too.
    private static func stripped(
        _ hooks: [String: Any],
        scriptPath: String
    ) -> [String: Any] {
        let name = (scriptPath as NSString).lastPathComponent
        var result: [String: Any] = [:]

        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else {
                result[event] = value
                continue
            }

            var kept: [[String: Any]] = []
            for var entry in entries {
                guard let commands = entry["hooks"] as? [[String: Any]] else {
                    kept.append(entry)
                    continue
                }
                let others = commands.filter { command in
                    !((command["command"] as? String)?.contains(name) ?? false)
                }
                if others.count == commands.count {
                    kept.append(entry)
                } else if !others.isEmpty {
                    // An entry the user had added their own command to keeps it.
                    entry["hooks"] = others
                    kept.append(entry)
                }
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - The script

    static let script = """
    #!/bin/bash
    \(marker)
    #
    # Reports what the coding agent in this terminal is doing, and which session
    # it is in, to the Workbench window that started it. Registered in
    # ~/.claude/settings.json and ~/.codex/hooks.json by Workbench; remove those
    # entries and this file to uninstall.

    EVENT="$1"
    AGENT="$2"
    [ -n "$EVENT" ] || exit 0

    # Hook config is global, so this also fires in sessions started outside
    # Workbench, and in ones left behind by an old install. Only a Workbench
    # terminal exports these, and without them there is nowhere to report to.
    [ -n "$TABTERM_AGENT_ID" ] || exit 0
    [ -n "$TABTERM_AGENT_DIR" ] || exit 0

    # Claude Code pipes the payload in; codex has passed it as an argument in
    # some versions. Reading stdin only when it isn't a terminal is what keeps
    # this from blocking forever on an agent that passes neither.
    INPUT=""
    if [ ! -t 0 ]; then INPUT=$(cat); fi
    if [ -z "$INPUT" ]; then
      for arg in "$@"; do
        case "$arg" in "{"*) INPUT="$arg" ;; esac
      done
    fi

    # Read top-level JSON fields, not lookalikes inside tool arguments or text.
    # plutil ships with macOS and preserves escaped paths and Unicode.
    field() {
      printf '%s' "$INPUT" | /usr/bin/plutil -extract "$1" raw -expect string -o - - 2>/dev/null
    }

    # Claude Code sets agent_id only inside a subagent. A subagent's tool calls
    # must not drive the terminal's status: the main loop already reports that
    # the terminal is busy, and a subagent finishing is not the turn ending.
    # Codex carries agent_id on every payload, so the same test can't be used
    # there; its subagent events are simply never registered.
    if [ "$AGENT" = "claude" ] \\
      && [ -n "$(field agent_id)" ]; then
      exit 0
    fi

    SESSION=$(field session_id)
    TRANSCRIPT=$(field transcript_path)
    TURN=$(field turn_id)
    if [ "$EVENT" = "Notification" ] && [ "$(field notification_type)" = "idle_prompt" ]; then
      EVENT="IdlePrompt"
    fi

    mkdir -p "$TABTERM_AGENT_DIR" 2>/dev/null || exit 0

    TARGET="$TABTERM_AGENT_DIR/$TABTERM_AGENT_ID.json"
    TEMP="$TARGET.$$"

    # Written then renamed: the app re-reads these when the directory changes,
    # and must never catch one half-written.
    {
      /usr/bin/plutil -create xml1 "$TEMP" &&
      /usr/bin/plutil -insert event -string "$EVENT" "$TEMP" &&
      /usr/bin/plutil -insert at -integer "$(date +%s)" "$TEMP" &&
      /usr/bin/plutil -insert agent -string "$AGENT" "$TEMP" &&
      /usr/bin/plutil -insert session -string "$SESSION" "$TEMP" &&
      /usr/bin/plutil -insert transcript -string "$TRANSCRIPT" "$TEMP" &&
      /usr/bin/plutil -insert turn -string "$TURN" "$TEMP" &&
      /usr/bin/plutil -convert json "$TEMP"
    } >/dev/null 2>&1 || { rm -f "$TEMP"; exit 0; }
    mv -f "$TEMP" "$TARGET" 2>/dev/null || rm -f "$TEMP" 2>/dev/null

    exit 0

    """
}
