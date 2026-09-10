import Foundation

/// Registers TabTerm's status hook with Claude Code.
///
/// Claude Code will run a command of our choosing at the edges of a turn, and
/// that is the only way to know what it is doing without reading the screen.
/// The hooks live in `~/.claude/settings.json` rather than in a per-project
/// file so a worktree needs no setup, and every entry we write names our own
/// script — which is how they are found again to be updated or removed, and
/// why the rest of the file, including the user's own hooks, is left alone.
///
/// The script is a no-op outside TabTerm: it exits immediately unless the
/// terminal it runs in exported `TABTERM_AGENT_ID`, so a `claude` started from
/// any other terminal behaves exactly as it did before.
enum ClaudeHooks {
    static let scriptName = "tabterm-agent-hook.sh"

    /// Header comment, so the script says what it is to anyone who finds it.
    static let marker = "# TabTerm agent status hook v1"

    /// `~/Library/Application Support/TabTerm/hooks/tabterm-agent-hook.sh`
    static let scriptURL: URL = AppSupport.directory
        .appendingPathComponent("hooks", isDirectory: true)
        .appendingPathComponent(scriptName)

    static let settingsURL: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("settings.json")

    /// One hook event, and the matcher it needs to be narrowed with.
    struct Registration {
        let event: String
        let matcher: String?
    }

    /// The events that mark the edges of a turn.
    ///
    /// `PostToolUse` is the odd one out: it isn't a state change on its own,
    /// but it is what fires after the user answers a permission prompt, so it
    /// is the only signal that a blocked agent has been unblocked.
    ///
    /// `Notification` is narrowed to the two types that mean Claude has stopped
    /// and is waiting. `idle_prompt` is deliberately left out — it fires a
    /// minute after a turn ends, which `Stop` has already reported.
    static let registrations: [Registration] = [
        Registration(event: "SessionStart", matcher: nil),
        Registration(event: "SessionEnd", matcher: nil),
        Registration(event: "UserPromptSubmit", matcher: nil),
        Registration(event: "PostToolUse", matcher: "*"),
        Registration(event: "PostToolUseFailure", matcher: "*"),
        Registration(event: "PermissionRequest", matcher: "*"),
        Registration(event: "PermissionDenied", matcher: "*"),
        Registration(event: "Notification", matcher: "permission_prompt|elicitation_dialog"),
        Registration(event: "Stop", matcher: nil),
        Registration(event: "StopFailure", matcher: nil),
    ]

    // MARK: - Installing

    /// Write the script and merge the hook entries. Safe to call on every
    /// launch: nothing is written when nothing changed.
    static func install() {
        do {
            try writeScript()
            try updateSettings(install: true)
        } catch {
            Ghostty.logger.warning(
                "could not register Claude hooks: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Take our entries back out, leaving everything else as it was. Never
    /// creates the settings file — teardown shouldn't write config that wasn't
    /// there.
    static func remove() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        try? updateSettings(install: false)
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

    private static func updateSettings(install: Bool) throws {
        let existing = read() ?? [:]
        let updated = install
            ? settings(byAdding: existing, scriptPath: scriptURL.path)
            : settings(byRemoving: existing, scriptPath: scriptURL.path)

        let data = try JSONSerialization.data(
            withJSONObject: updated,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        // Don't rewrite an unchanged file: the mtime is what tells Claude Code
        // to reload its settings mid-session.
        if let current = try? Data(contentsOf: settingsURL), current == data { return }

        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    private static func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return object as? [String: Any]
    }

    // MARK: - Merging
    //
    // Kept as plain functions over the decoded JSON so the self-test can run
    // them against fixtures rather than the user's real settings file.

    /// The shell Claude Code runs for one event.
    ///
    /// The event name is passed as an argument rather than read back out of the
    /// payload on stdin: the script would otherwise have to find
    /// `hook_event_name` in JSON that can contain a whole assistant message,
    /// with nothing but grep to do it with.
    static func command(scriptPath: String, event: String) -> String {
        let quoted = shellQuoted(scriptPath)
        // `|| true` so a hook that can't run never surfaces as an error in the
        // user's session — a missing dot is not worth interrupting them for.
        return "[ -x \(quoted) ] && \(quoted) \(event) || true"
    }

    static func settings(byAdding existing: [String: Any], scriptPath: String) -> [String: Any] {
        var settings = existing
        var hooks = stripped(existing["hooks"] as? [String: Any] ?? [:], scriptPath: scriptPath)

        for registration in registrations {
            // A shape we don't understand is left exactly as it is rather than
            // replaced with ours.
            if let present = hooks[registration.event], !(present is [[String: Any]]) { continue }

            var entry: [String: Any] = [
                "hooks": [
                    [
                        "type": "command",
                        "command": command(scriptPath: scriptPath, event: registration.event),
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

    static func settings(byRemoving existing: [String: Any], scriptPath: String) -> [String: Any] {
        var settings = existing
        guard let hooks = existing["hooks"] as? [String: Any] else { return settings }

        let remaining = stripped(hooks, scriptPath: scriptPath)
        if remaining.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = remaining
        }
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
    # Reports what Claude Code is doing to the TabTerm window that started it.
    # Registered in ~/.claude/settings.json by TabTerm; remove those entries and
    # this file to uninstall.

    EVENT="$1"
    [ -n "$EVENT" ] || exit 0

    # Hook config is global, so this also fires in sessions started outside
    # TabTerm, and in ones left behind by an old install. Only a TabTerm
    # terminal exports these, and without them there is nowhere to report to.
    [ -n "$TABTERM_AGENT_ID" ] || exit 0
    [ -n "$TABTERM_AGENT_DIR" ] || exit 0

    INPUT=$(cat)

    # Claude Code sets agent_id only inside a subagent. A subagent's tool calls
    # must not drive the terminal's status: the main loop already reports that
    # the terminal is busy, and a subagent finishing is not the turn ending.
    if printf '%s' "$INPUT" | grep -qE '"agent_id"[[:space:]]*:[[:space:]]*"'; then
      exit 0
    fi

    mkdir -p "$TABTERM_AGENT_DIR" 2>/dev/null || exit 0

    TARGET="$TABTERM_AGENT_DIR/$TABTERM_AGENT_ID.json"
    TEMP="$TARGET.$$"

    # Written then renamed: the app re-reads these when the directory changes,
    # and must never catch one half-written.
    printf '{"event":"%s","at":%s}\\n' "$EVENT" "$(date +%s)" > "$TEMP" 2>/dev/null || exit 0
    mv -f "$TEMP" "$TARGET" 2>/dev/null || rm -f "$TEMP" 2>/dev/null

    exit 0

    """
}
