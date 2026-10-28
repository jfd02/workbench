# Workbench

Formerly TabTerm. The app and CLI are now `Workbench.app` and `workbench`;
`tabterm` remains available as a CLI alias. Existing Mac data paths and bundle ID,
`tabterm://` pairing links, `.tabterm.json`, and `TABTERM_*` environment variables
retain their names for compatibility. Internal source folders and modules also
keep their original names.

A native macOS app with a sidebar of git repositories on the left and a tab bar
on top. Each tab is a **real Ghostty terminal**, via libghostty.

**Every worktree gets its own set of tabs.** Pick a worktree in the sidebar and
the tab bar swaps to that worktree's terminals; switch away and they
keep running, so you can leave a build going in one branch while you work in
another. Terminals start at the worktree's directory. Claude Code and Codex
activity appears on both worktree rows and tabs — amber while working, red when
waiting for you. See [Agent status](#agent-status).

The `+` sits right after the last tab and opens a terminal straight away, as
does `⌘T` — there's nothing to pick, so nothing asks. A new tab starts in the
focused terminal's directory, never outside the worktree the workspace is for.

A terminal running Claude Code shows a Claude mark instead of the terminal
symbol, so a background tab still says what's happening in it. See
[Icons](#icons) for where that comes from.

Closing only asks when there's something to lose. A terminal sitting at a prompt
just closes; one with a process still running warns that it'll be killed. A
shell that exits on its own closes silently too.

Unselected tabs show the `⌘1`…`⌘9` that reaches them, swapping to a close button
on hover.

**Every terminal is also on your iPhone.** Pair the Workbench iPhone app once and
it shows the same sidebar, with the same agent dots, and opens any terminal as
it is right now — the same shell, the same Claude session, live. Put the phone
down and the Mac picks up where you left off. It reaches the Mac over Tailscale,
so it works from anywhere as long as the Mac is on. See
[On your iPhone](#on-your-iphone).

**And in another Mac's terminal.** `workbench ls` and `workbench attach <worktree>`
on a second Mac open the same terminals in whatever terminal you already use
there, with a key to switch between them. See
[From another Mac](#from-another-mac).

## What "real Ghostty" means here

This is not a terminal emulator that looks like Ghostty — it links
`libghostty` itself, the same core that ships inside Ghostty.app:

- Ghostty's Metal renderer draws into an `NSView` we hand it.
- It reads **your** config (`~/.config/ghostty/config` and the
  `com.mitchellh.ghostty` support directory), so fonts, themes, padding, and
  keybinds match the Ghostty you already run.
- `$TERM` is `xterm-ghostty`, resolved from the terminfo bundled into the app.

The one thing libghostty doesn't own is the shell. That runs in a session
Workbench holds, and the pane's surface is a view of it — which is what lets a
phone show the same terminal. See [Sessions](#sessions).

## Build

Requires macOS 14 or later and a Swift toolchain. The iPhone app requires iOS 17
or later and Xcode; regenerating its project also requires XcodeGen.

```sh
./scripts/build-ghostty.sh   # first checkout: build libghostty (requires Zig; see below)
./scripts/bundle.sh          # builds + assembles build/Workbench.app
open build/Workbench.app
```

`swift build` alone produces the binary but **not** a runnable app: libghostty
finds its terminfo and shell-integration by walking up from the executable to
`Contents/Resources`, so it must run from the bundle.

The iPhone app is an Xcode project generated from `iOS/project.yml`:

```sh
cd iOS && xcodegen generate   # after changing project.yml
open TabTermMobile.xcodeproj  # then run on your phone
```

The project ships with no signing team and a generic
`com.tabterm.TabTermMobile` bundle identifier. For a device build, choose your
own team in Xcode's Signing & Capabilities settings and a bundle identifier
registered to that team (update the test target's identifier too). For command
line builds, pass `DEVELOPMENT_TEAM=YOUR_TEAM_ID`. Keep personal signing settings
out of commits. SwiftTerm uses a build plugin, so the first build in Xcode asks
you to trust it; from the command line pass `-skipPackagePluginValidation`.

### Sharing it with another Mac

```sh
./scripts/package.sh          # build/Workbench-<version>-<stamp>.zip
```

The bundle is self-contained — libghostty is linked in statically and terminfo,
shell integration and themes are inside it, so nothing has to be installed on
the other machine. The script refuses to package a build that links anything
outside `/usr/lib` and `/System`, since that wouldn't exist over there.

Two things to know:

- **Apple Silicon only.** The default build is native-arch. For an Intel Mac,
  rebuild libghostty with `-Dxcframework-target=universal` (a long build) and
  package again; `package.sh` prints the architectures it found.
- **First launch is blocked.** The app is signed ad-hoc, not with a Developer ID,
  so Gatekeeper stops a double-click on a machine it was copied to. Right-click →
  **Open** → **Open**, once, and it's trusted from then on. Equivalently:
  `xattr -dr com.apple.quarantine /Applications/Workbench.app`.

### Updating without losing your data

Everything you accumulate — repositories, worktrees, saved tabs,
window frame — lives in `~/Library/Application Support/TabTerm/tabterm.sqlite`,
outside the bundle. **Replacing `Workbench.app` keeps all of it.** Quit the app,
drop the new one over the old, reopen.

Schema changes ride along: `DatabaseMigrator` runs any migrations the new build
adds the first time it launches, so an older database is upgraded in place.

The one direction that doesn't work is backwards — an older build opening a
database a newer one has migrated. If you want a way back, copy the `.sqlite`
file somewhere before updating.

### Rebuilding libghostty

`Frameworks/GhosttyKit.xcframework` is generated locally and excluded from Git.
Build it before bundling a fresh checkout. `Resources/{terminfo,ghostty}` are
checked in; the same script refreshes them from Ghostty source:

```sh
./scripts/build-ghostty.sh              # clones ghostty into build/ghostty-src
./scripts/build-ghostty.sh /path/to/ghostty
```

This needs `zig` matching `minimum_zig_version` in the Ghostty checkout's
`build.zig.zon`, and `xcodebuild`. The script builds the whole terminal core.

## Layout

| Path | What |
| --- | --- |
| `Sources/TabTerm/Ghostty/` | libghostty surfaces, input, clipboard, and callbacks |
| `Sources/TabTerm/Tabs/` | Workspaces, tabs, split trees, and foreground processes |
| `Sources/TabTerm/UI/` | Sidebar, tab strip, split containers, and Changes/CI panel |
| `Sources/TabTerm/Git/` | Worktrees, filesystem watching, pull requests, diffs, CI, and cleanup |
| `Sources/TabTerm/Agents/` | Claude Code and Codex status, recovery, resume, and completion sounds |
| `Sources/TabTerm/Hooks/` | User hook events, command execution, and logs |
| `Sources/TabTerm/Storage/` | SQLite schema, repositories, and saved layouts |
| `Sources/TabTerm/Sessions/` | Shell sessions and local socket attachment |
| `Sources/CTabTermPTY/` | PTY creation and shell spawning |
| `Sources/TabTerm/Remote/` | Remote connections, pairing, and push notifications |
| `Sources/TabTerm/MainWindowController.swift` | Workspace selection, panes, and remote snapshots |
| `TabTermKit/` | Shared protocol and terminal bookkeeping; see [PROTOCOL.md](TabTermKit/PROTOCOL.md) |
| `iOS/` | SwiftUI iPhone app with SwiftTerm rendering |
| `CLI/` | Remote `workbench` client; depends only on `TabTermKit` |
| `Tests/WorkbenchTests/` | User hook and Changes/CI tests |
| `examples/hooks/` | Example user hook scripts |

## Repositories and worktrees

**Add Repository…** at the bottom of the sidebar takes any folder inside a git
repository and stores its top level. Its worktrees are read straight from
`git worktree list`, so the main checkout shows up alongside the others.
Workbench watches for worktrees added or removed outside the app and refreshes
the sidebar automatically.

To add a worktree, click the **New Worktree** row at the end of the
repository's list (the same thing sits in the context menu as
**New Worktree…**). It asks for a branch (new, or an existing one that
isn't checked out anywhere else) and then runs `git worktree add`.
New worktrees go in a sibling folder, so the repo directory stays clean and needs
no `.gitignore` entry:

```
~/code/
├── myapp/                  ← the repository
└── myapp-worktrees/
    ├── feature-auth/
    └── bugfix-123/
```

Slashes in branch names are flattened (`feature/auth` → `feature-auth`) so a
branch can't nest directories.

Right-click a worktree for **Remove Worktree…**. It asks first — naming the
directory it will delete and noting the branch is kept — and only then runs
`git worktree remove`. If git refuses because the tree is dirty, a second sheet
offers the forced removal and says what would be lost. On the repository's main
checkout the item is shown but greyed, with a tooltip explaining that git can't
remove a main working tree; **Remove from Sidebar** is what you want there, and
it only forgets the repository — nothing on disk is touched.

Once git stops listing a worktree, whether it was removed here or by an agent in
a terminal, Workbench also deletes the build folders Xcode and MobileBuildMCP
(formerly XcodeBuildMCP) kept for it under `~/Library/Developer`. They live
outside the worktree, so removing it doesn't touch them, and an iOS checkout's
can run to tens of gigabytes.

A repository can leave other things behind that only it knows about —
databases, a copy on a test machine, a simulator it reserved — so it can name a
command for Workbench to run at the same moment, in `.tabterm.json` at the top of
its main checkout:

```json
{ "worktreeRemoved": "./prune.sh" }
```

The worktree is already gone, so the command runs in the main checkout, through
`/bin/sh -c`, with the removed paths in `TABTERM_REMOVED_WORKTREES`, one per
line. Nothing waits for it; its output is dropped and a non-zero exit is logged
under the `worktrees` category. It runs without asking, so add only
repositories whose scripts you would run yourself.

### User hooks

Workbench can run your scripts when a worktree appears or disappears, you switch
workspaces, or an agent needs attention. Use them to prepare a development
environment, record activity, notify another tool, or clean up resources.

Add a `hooks` object to `.tabterm.json` in the repository's **main checkout**:

```json
{
  "hooks": {
    "worktree.created": [
      { "command": "sh \"$WORKBENCH_REPOSITORY_PATH/scripts/setup-worktree.sh\"", "timeoutSeconds": 300 }
    ],
    "agent.finished": [
      "osascript \"$WORKBENCH_REPOSITORY_PATH/examples/hooks/notify-agent.applescript\""
    ],
    "*": [
      "sh \"$WORKBENCH_REPOSITORY_PATH/examples/hooks/record-event.sh\""
    ]
  }
}
```

Supply your own `scripts/setup-worktree.sh`; the two scripts under
[`examples/hooks`](examples/hooks) are working examples included in this repo.
Commands are shell strings, and each event takes an array so multiple tools can
subscribe. A command object can set `timeoutSeconds` (default 60, range 0.1–3600).
`*` subscribes to every event. Unknown event names are ignored.

For personal hooks across all repositories, put the same `hooks` object in
`~/Library/Application Support/TabTerm/hooks.json`. With `TABTERM_DATA_DIR`, this
file lives in that directory instead. Global commands run first, then repository
commands; within each file, the named event runs before `*`, in array order.
Files are re-read for each event, so edits need no restart. An invalid config
file is logged and skipped; the other file still runs. Both config locations
contain executable code and run with your user permissions, like the existing
`worktreeRemoved` command.

| Event | When it fires | Command's working directory |
| --- | --- | --- |
| `worktree.created` | A new linked worktree is discovered in an already registered repository, including changes made outside Workbench | New worktree |
| `worktree.removed` | A known linked worktree leaves git's list and its directory is gone | Main checkout |
| `workspace.selected` | The Mac changes workspace, including restoring a worktree at launch or following the phone | Selected worktree, or home directory for Home |
| `agent.working` | An agent's reported state changes to working | Agent's worktree, or home directory for Home |
| `agent.blocked` | An agent's reported state changes to waiting for input | Agent's worktree, or home directory for Home |
| `agent.finished` | An agent reports a new completed turn | Agent's worktree, or home directory for Home |

Registering a repository establishes a baseline: it does not run creation hooks
for existing worktrees. Refreshing the same list, selecting the current workspace,
or rereading the same agent report does not repeat an event. Agent events follow
the Claude/Codex hook reports, including background panes; acknowledging a dot
does not emit an event. Worktree events are sent after the database commits.
Removing a repository from the sidebar does not emit removal events.

Each command receives one JSON object on **stdin**, followed by a newline:

```json
{
  "schemaVersion": 1,
  "id": "B9523C82-5CDE-486F-B338-5B44DF1AA84E",
  "event": "agent.finished",
  "timestamp": "2026-10-27T19:40:00Z",
  "repositoryPath": "/Users/me/code/myapp",
  "worktreePath": "/Users/me/code/myapp-worktrees/feature-auth",
  "branch": "feature/auth",
  "workspaceID": "worktree:12",
  "terminalID": "831C950C-2715-44BC-B0EE-9575DAB9C766",
  "agent": "claude",
  "agentSessionID": "the-agent-session-id"
}
```

`schemaVersion`, `id`, `event`, and `timestamp` are always present; other fields
are omitted when unavailable. The timestamp is when Workbench observed the
event. The event ID is shared by every command receiving that event. `terminalID`
identifies the pane's terminal session; `agentSessionID` is the agent's own ID.
Consumers should tolerate additional fields in future versions.

Shell scripts can also use `WORKBENCH_EVENT`, `WORKBENCH_EVENT_ID`,
`WORKBENCH_REPOSITORY_PATH`, `WORKBENCH_WORKTREE_PATH`, `WORKBENCH_BRANCH`,
`WORKBENCH_WORKSPACE_ID`, `WORKBENCH_TERMINAL_ID`, `WORKBENCH_AGENT`, and
`WORKBENCH_AGENT_SESSION_ID`. Unavailable values are empty strings. Quote these
variables when using them as shell arguments. Commands run through `/bin/sh -c`
without loading your interactive shell configuration; the app's PATH is extended
with `/opt/homebrew/bin` and `/usr/local/bin`.

Hooks run serially in a background queue and never hold up the interface. A
creation hook is asynchronous: opening a terminal does **not** wait for setup to
finish. A failing or timed-out command is logged and the next command runs; a
timeout kills the command's process group. Scripts should finish their work
before exiting rather than leave detached children running. Delivery is best
effort while Workbench is running, with no durable queue or automatic retries.

Combined stdout/stderr and exit status are recorded in
`~/Library/Application Support/TabTerm/logs/hooks.log` (under `TABTERM_DATA_DIR`
when set). Output is capped at 64 KiB per command; the log rotates after 1 MiB
and keeps one previous file. The existing top-level `worktreeRemoved` command
continues to run independently with `TABTERM_REMOVED_WORKTREES`; migrating it to
`hooks` is optional. Avoid configuring the same cleanup in both places.

### Branch state

When [`gh`](https://cli.github.com) is installed and signed in, a worktree whose
branch has a pull request has its **branch icon tinted** in GitHub's own colours:
green for open, purple for merged, red for closed, grey for a draft. Hovering
gives the number and state. Branches with no pull request keep the normal accent
tint, as do repositories with no GitHub remote or when `gh` isn't available — the
feature is additive and never blocks the sidebar.

State is read with `gh pr list` once per repository rather than once per branch,
cached for two minutes, and fetched off the main thread. **Refresh Pull
Requests** in a repository's context menu forces a re-check. The cache is
in-memory only: pull request state is live data, and a stale colour after a
relaunch would be worse than a moment with no colour.

### Changes and CI

The **Changes** and **CI** buttons below the tab strip open a resizable review
panel for the selected worktree. Click the same button again or the panel's
close button to close it, or use **View → Show Changes** (`⇧⌘G`) and **View → Show CI Checks** (`⇧⌘I`). Home
has no repository, so these controls are disabled there.

Changes groups **conflicts, staged, unstaged, and untracked files**. Filter by
filename or path (including a renamed file's original path), then use the arrow
keys to move through files. Select a file to see its diff, or a text preview for
an untracked file. The diff shows added and removed line counts; use the up/down
buttons or `⌥↑` / `⌥↓` to jump between changes. Toggle line wrapping for long
lines, or copy the original diff with the copy button. Background refreshes
preserve the selected file, text selection, and scroll position. A file with
both staged and unstaged edits appears in both categories, with a separate diff
for each. Renames retain their original path. Binary files are identified without trying
to render their contents, and large previews are bounded. **Reveal in Finder**
opens the selected file's location. This panel is read-only; staging, committing,
and resolving conflicts remain in your terminal or editor.

CI uses your existing **GitHub CLI (`gh`) authentication**. It shows individual
checks, their status, and **Open Check Logs** links. When the current branch has
a pull request whose head matches the local commit, it uses that PR's check
rollup, including checks against GitHub's test merge. Otherwise it requests
check runs and external CI commit statuses for the exact local HEAD. Checks
apply to that commit, **not uncommitted edits**. A newer local commit never
inherits an older commit's green status. Unpushed commits, missing authentication,
network failures, and repositories without checks are shown explicitly rather
than appearing successful.

While the window is visible, local changes refresh every five seconds and CI
every thirty seconds; changing HEAD triggers a fresh CI lookup. The panel's
refresh button requests both immediately. Summaries remain visible below the
tabs even when the panel is collapsed. Late responses from a previous worktree
or commit are discarded. GitHub is the supported CI source; external providers
appear when they publish checks or commit statuses to GitHub.

### Agent status

A worktree running Claude Code or Codex carries a **dot on the right of its row**: amber
and slowly pulsing while the agent is working, red when it has stopped and wants
you — either a permission prompt it can't get past, or a turn that finished and
is waiting for your next instruction. A worktree with nothing running has no
dot at all, so the sidebar looks exactly as it did before you started anything.

The sidebar dot shows the most demanding state
across every terminal in that workspace, so one prompt waiting for an answer is
never hidden behind another pane's progress. Fold a repository away and its
header takes over its worktrees' dots, so collapsing a section never quietly
hides an agent. Each tab also shows its panes' combined status, with a red tint
and outline when it needs attention. Selecting a tab in the active window clears
its finished indicators; hidden tabs keep theirs, even in the current worktree.
A dot that means "answer me" stays lit until the agent
itself moves on, because looking at a prompt isn't answering it.

The selected tab has an accent underline, outline, and bolder title so it stays
distinct from tabs with pending notifications. When an agent finishes a turn,
Workbench plays a completion sound, including in the selected tab. Choose it from
**Workbench → Agent Completion Sound**: the fourteen macOS sounds (Glass by
default), **None**, or **Choose Custom Sound…**. Selecting a sound previews it;
**Preview Sound** plays it again. Custom audio is validated and copied into
Workbench's `sounds/` directory, so moving the original doesn't break it. A failed
import leaves the previous selection intact. The setting survives relaunch.
Sound needs neither phone pairing nor notification permission. Repeated
reads of the same completion do not replay it, and muted turns are not replayed
when sound is enabled again.

Hooks are the primary source of agent state.
On launch Workbench installs or updates a small script at
`~/Library/Application Support/TabTerm/hooks/tabterm-agent-hook.sh` and
registers it against the events that mark the edges of a turn — in
`~/.claude/settings.json` for Claude Code, and in `~/.codex/hooks.json` for
codex, which takes the same shape of entry:

| Event | What the dot does |
| --- | --- |
| `SessionStart`, `SessionEnd`, Codex `Interrupt` | goes out |
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`, `PreCompact`, `PostCompact`, `ElicitationResult` | amber — working |
| `PermissionRequest`, permission/question `Notification`, `Elicitation` | red — blocked on you |
| `Stop`, `StopFailure` | red — the turn ended |

Tool results and elicitation responses restore working state after a question.
Claude's `idle_prompt` notification is a silent recovery signal for a missed Stop;
it preserves an existing unread completion instead of lighting a new red dot.

Each agent is registered only with the events it supports; writing one it
doesn't know risks it rejecting the whole file. Neither file is created for an
agent you don't have installed — if its config directory isn't there, that
agent is skipped until a launch after you install it.

Each terminal exports `TABTERM_AGENT_ID` and `TABTERM_AGENT_DIR`, so the script
knows which pane it is running in and where to leave the answer, and **exits
immediately when they aren't set** — a `claude` started from any other terminal
behaves exactly as it did before. It writes one small JSON file per terminal by
rename, which is atomic and moves the directory's mtime; the app watches that
directory with a `DispatchSource`. Alongside the event it
records the `session_id`, `turn_id`, and `transcript_path` out of the payload, which is
what makes resuming below possible. Claude Code pipes that payload in; codex
has passed it as an argument, so the script takes it either way — and reads
stdin only when it isn't a terminal, so an agent that sends neither can't leave
it waiting forever. A file rather than a socket
because the hook can use macOS's built-in shell and JSON tools, and
a listening port would put the app in front of the firewall for no reason.

Events from Claude subagents (the Task tool) are dropped: the terminal is busy
either way, and a subagent finishing is not the turn ending. They're recognized
by a top-level `agent_id` in the payload, which codex sets on everything — so for codex
the subagent events are simply never registered.

Hooks can be missed, especially when a turn is interrupted. Workbench also uses
explicit evidence to repair stale state, following cmux's approach:

- Claude Code's native OSC 7501 reports track working and blocked activity,
  including child records. When that activity ends, a three-second grace period
  lets a late Stop arrive before a still-working indicator is cleared. New work
  cancels recovery; a pending permission prompt is not cleared by that timer.
- Codex's transcript is checked off the UI thread every two seconds while a
  command is running. Only explicit `task_started`, `task_complete`,
  `turn_complete`, and `turn_aborted` records count, with timestamp and turn-id
  checks. Unknown formats are ignored; this is a fallback, not a stable API.
- Returning to the shell clears stale working/waiting indicators after two
  consecutive process checks and at least four seconds since the last hook.

Recovery changes status without inventing completion sounds or phone alerts.
A quiet terminal alone is never evidence that work has finished. Native status
recovery requires an agent version that emits those reports. Restart Workbench
to install the updated hooks, then restart existing agent sessions to load them.

Only entries naming our own script are ever touched, so the rest of each file
— including your own hooks, and other tools' — is left alone;
installing twice doesn't stack up duplicates. To uninstall, delete those
entries and the script. Note that the file is rewritten with sorted keys, since
JSON objects have no order to preserve.

### Resuming agents

Quit with Claude Code or codex running in a pane and it comes back to that
session. The restored pane opens your shell as usual, then types the command
back at the prompt — `claude --resume <id>`, or `codex resume <flags> <id>` —
and the shell runs it.

**Typed rather than run as the pane's command**, because a pane whose process
*is* the agent dies when you quit the agent. Typing it means the line is in
your scrollback and your history, and quitting the agent leaves you at your own
prompt in the right directory.

The command line is **replayed as it was recorded, not rebuilt from a name**.
`claude` is usually reached through an alias — `clauded` for
`claude --dangerously-skip-permissions`, say — and only the expansion ever
reaches the process table, so replaying argv is the only way to bring a session
back with the flags it was started under. Assuming `--dangerously-skip-permissions`
instead would be worse than dropping it: it would turn permission skipping on
in panes that were deliberately started without it. Any `--resume` or
`--continue` already in there is taken out first, so a pane restored twice
doesn't accumulate them, and for codex the recorded flags move across the
`resume` subcommand.

A pane started with a prompt on the command line — `claude "fix the tests"` —
is **not resumed at all**. That prompt is an instruction that has already been
given, and sending it again on every restart, in whatever permission mode the
pane was in, is worse than coming back to a plain shell. Telling a prompt from
a flag's value needs a list of which flags take one; a flag missing from that
list makes its value look like a prompt, which costs a resume rather than
causing one.

A pane is only offered for resume when the agent was **the foreground process at
the moment the window closed** — not merely something that ran in it once — and
when its saved session is resumable. If the hook supplied a transcript path,
that file must still exist; a missing path does not prevent resume. Workspaces
materialize lazily, so a worktree you don't open doesn't start an agent. Its
resume command is queued when you first open it.

The line goes in once the shell reports its directory — that comes from the
shell integration libghostty injects, after your rc files have run, which is
when a typed line lands on a prompt rather than ahead of one — or after two
seconds for a shell that never reports one.

### Sidebar navigation

Above the repositories is **Home**, a workspace with no directory, so the app is
useful before you've added anything. It gets a dot on the same terms.

The panel reads as a list of workspaces rather than a file tree: a repository is
a plain section header with no icon, its worktrees are two lines — the branch,
then which folder it is and when it was last opened — and a **New Worktree** row
sits at the end of each repository's list. The first nine workspaces show the
`⇧⌘1`…`⇧⌘9` that reaches them, counting Home first. Last-opened times live in `appState`
under `worktreeLastUsed:<id>`, so a worktree you've never opened falls back to
when its directory appeared on disk.

The sidebar icon at the left of the tab strip shows and hides the panel, as does
`⌃⌘S`. It lives in the tab bar rather than the titlebar so it's still on screen
once the sidebar is collapsed.

## Splits

To give the focused split its own tab, use **View → Move Split to New Tab**
(`⌘⇧T`). The new tab opens beside the original and keeps the same terminal,
scrollback, and running process. This is available when the tab has multiple panes.

`⌘D` splits the focused pane to the right, `⌘⇧D` splits it downwards, and each
half can be split again. A pane splits into another terminal in the same
directory. Drag a divider to resize.

You can also **drag a tab from the strip onto a pane**: the half of the pane it
would take lights up as you move — left, right, top or bottom, whichever edge
you're nearest — and dropping moves that tab in as a split, bringing its own
splits with it.

Dropping **files** on a terminal types their paths, escaped and space-separated,
the way Ghostty does; so does pasting files copied in Finder. That's how Claude
Code picks up an image dragged into it and shows it as `[Image #1]`.

The unfocused panes are dimmed with your `unfocused-split-fill` and
`unfocused-split-opacity`, the same two settings Ghostty dims its own splits
with, and their cursors stop blinking — that part is libghostty's doing, since
each surface is told whether it holds the focus.

## Icons

A tab draws whatever its focused pane reports and falls back to the terminal
symbol when there's nothing better, so an icon is always an addition, never a
blank space.

Nothing announces that the program in a terminal changed, so each
terminal asks its session for the pty's foreground process every two seconds and,
only when that pid changes, reads the process's command line via
`KERN_PROCARGS2`. Both shapes Claude Code runs as count: a `claude` binary, and
`node .../@anthropic-ai/claude-code/cli.js` from an npm install. Only the
executable and first two arguments are looked at, so an editor holding a
`claude.md` isn't mistaken for it. The mark is an SF Symbol in Claude's orange —
put a `claude.png` in `Resources/Icons/` to use a real one instead.

## Sessions

libghostty would happily own each pane's pty, and it used to. But then the
output only ever goes to that one surface, and nothing else — a phone, say — can
see it. So Workbench holds the pty itself, in a `TerminalSession`, and the pane's
Ghostty surface doesn't run a shell at all. It runs
`Workbench --attach <socket> <session>`, a small process that puts its own
terminal in raw mode and relays bytes both ways over a Unix socket. The shell
sees a normal terminal; Ghostty sees a normal child. Everything in between is a
straight copy.

Getting that indistinguishable from Ghostty spawning the shell itself takes
three things, all in `SessionEnvironment.swift`:

- **The environment.** The attach process is the child Ghostty set up, so it
  forwards the environment it was given — `TERM`, `TERMINFO`,
  `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_SHELL_FEATURES`, your config's `env`
  entries — and the shell starts from exactly that, plus Workbench's own
  variables.
- **Shell integration.** Ghostty only injects it when the command it runs is a
  shell, and the attach process isn't one, so the session does it instead, the
  same way (`ZDOTDIR` for zsh, `ENV` and `--posix` for bash, `XDG_DATA_DIRS` for
  fish), honouring your `shell-integration` setting. It's what reports the
  current directory, which resume and new tabs depend on.
- **A login shell.** `/usr/bin/login -flp $USER /bin/bash --noprofile --norc -c
  "exec -l <shell>"`, exactly as Ghostty runs it on macOS.

What is running in a pane — for its icon, its close confirmation, and resume —
now comes from the session's pty rather than libghostty's, which would only
ever report the attach process.

A session can have any number of clients. The pty takes the **smallest size
among the clients that are showing it**, as tmux does: a desktop's 200 columns
squeezed into a phone's 45 is unreadable, while the reverse just leaves space.
A pane in a background tab doesn't count, and neither does a phone that went to
the background, so the Mac gets its width back the moment the phone is put
away. The Mac pane always receives everything, whatever size the pty is; its
scrollback is its own.

Each session keeps the last 2 MB of output in an `OutputRing`, with every byte
numbered. A client that drops off and comes back says where it was and gets
exactly the bytes it missed. When that isn't possible — the gap is too big, or
the pty changed size in between, so what it missed was laid out for a different
width — it resets its screen, gets the terminal modes the program switched on
(alternate screen, bracketed paste, hidden cursor…, tracked by `ModeTracker`)
and the recent output, and the program is asked to redraw by shrinking the pty a
row and putting it back. The design follows what
[Superset](https://github.com/superset-sh/superset) arrived at, down to never
synthesizing screen contents.

Sessions end with the app, as the shells did before: quitting hangs every one
up. That takes more than closing the pty, which only signals `login`, and
`login` is root and ignores it — so each shell is sent SIGHUP directly, again
every 10 ms until it has gone, the way Ghostty kills its own children. A shell
still starting up has SIGHUP ignored until its rc files are done, and one signal
can arrive too early to count.

## On your iPhone

The iPhone app shows the Mac's sidebar — Home, each repository's worktrees, the
agent dots — and opens any terminal as it is right now. It opens straight to
whatever the Mac is showing, so picking up the phone continues what you were
doing; and when nobody has touched the Mac for a minute, the Mac follows the
phone, so sitting back down continues too.

Typing on a phone is done mostly through a **message box** rather than into the
terminal: write the whole message, send it, and the Mac types it the way a
person would — the text, then Enter half a second later on its own, because
agents treat bytes that arrive together as a paste and an Enter inside a paste
is a newline, not a send. A row of keys covers what the phone keyboard lacks
(esc, tab, ⇧tab, arrows, ^C), and a keyboard button types into the terminal
directly for anything else.

### Setting it up

1. Install [Tailscale](https://tailscale.com) on the Mac and the iPhone, signed
   in to the same tailnet. Workbench only listens on the Mac's Tailscale address
   (port 7766), so nothing outside your tailnet can reach it, and Tailscale
   encrypts the connection.
2. On the Mac, **Workbench ▸ Pair iPhone…** shows a QR code. Scan it with the
   iPhone's Camera (or from inside the app). The code works once, for ten
   minutes; the phone trades it for a token of its own, and only a hash of that
   is kept on the Mac.
3. That's it. The same window lists paired phones and forgets them.

While a phone is paired, Workbench keeps the Mac from idle-sleeping (the display
still sleeps and the screen still locks) — a sleeping Mac drops off Tailscale.

### Notifications

When an agent stops to ask permission or finishes its turn and you're away from
the Mac — screen locked, or two minutes without input — the phone gets a
notification naming the worktree. Tapping it opens that terminal. A phone
already showing that terminal isn't told.

Apple only delivers to the app with a key from the team it is signed with, so
this needs one thing from you: an APNs key. In the Apple Developer site, under
Certificates, Identifiers & Profiles ▸ Keys, create one with Apple Push
Notifications enabled, download the `.p8`, and give it to Workbench in Pair
iPhone… with its Key ID and your Team ID. The Mac then talks to APNs directly —
no server in between.

### How the phone keeps up

The protocol is in [TabTermKit/PROTOCOL.md](TabTermKit/PROTOCOL.md), and
everything both ends must agree on — frames, messages, the output ring, the
mode tracker, filtering the terminal's automatic replies — is in `TabTermKit`,
shared by both apps.

- Only the terminal on screen is attached, so the phone only ever holds the
  size of the one terminal you are looking at.
- A dropped connection is retried at once; the phone says where it was and gets
  exactly what it missed. The Mac holds a dropped phone's place for three
  seconds, so a phone moving from Wi-Fi to cellular comes back to its screen
  rather than a redraw.
- Both ends ping. A phone that vanished without a word — suspended mid-session —
  is dropped after two missed pings, so it can't keep the Mac's terminal narrow.
- When a program asks the terminal a question (where is the cursor, what colour
  is the background), the Mac's Ghostty answers. The phone's terminal would
  answer too, landing garbage on the command line, so its replies are filtered
  out and only keystrokes are sent.

## From another Mac

`workbench` is a command-line client for a second Mac: the same terminals, in the
terminal you already have open there. It speaks the phone's protocol, so the
Mac running Workbench needs nothing new — to it, this is one more paired device.

```sh
workbench ls                     # the workspaces, and the terminals in each
workbench attach                 # the terminal that Mac has on screen
workbench attach feature-auth    # a worktree's terminal: its selected tab
workbench attach feature-auth 2  # ...or its second tab, numbered as ls shows them
workbench new feature-search     # make a worktree on that branch, and open it
```

A worktree is named by any part of its name that no other shares, so `auth` is
enough for `myapp/feature-auth` until a second worktree has it in its name too.
Attaching to a worktree nobody has opened since Workbench started starts its
terminals, without switching the Mac's window to it.

`workbench new [<repository>] <branch>` makes a worktree the way the sidebar's
sheet does, and lands in its terminal. The branch decides what happens, as the
sheet's two modes do: one that exists is checked out, one that only exists on a
remote gets a local branch tracking it, and any other name is a new branch from
the remote's default branch, freshly fetched. It goes in the same sibling
`<repo>-worktrees` folder. The repository only needs naming when the sidebar has
more than one, and a worktree's name will stand for the repository it is in. The
Mac's own window stays on whatever it was showing. Run from a script rather than
a terminal, it makes the worktree and stops there.

A worktree made with plain `git worktree add` in any terminal works too:
Workbench watches each repository for that, and it is in `workbench ls` a moment
later.

While attached, **`ctrl-\` brings up the list of terminals** — every workspace,
its terminals, and the agent dots beside them, kept current while it is up.
Arrows or `j`/`k` and Return switch to one, `1`…`9` jump straight to a row, `n`
opens a new tab in the highlighted workspace, `q` detaches, and Escape goes back.
Pressing `ctrl-\` again types it, for the program that wants it.
`TABTERM_MENU_KEY=b` makes the key `ctrl-b` instead. A terminal whose shell exits
leaves you on the list rather than back at your own prompt.

### Setting it up

1. Build it, and put it on the other Mac's `PATH`. It is one file of about a
   megabyte that links nothing but the system:

   ```sh
   cd CLI && swift build -c release      # .build/release/workbench
   ```

   Copy that file across, or build it over there — the package needs only `CLI/`
   and `TabTermKit/`, not libghostty, so it builds in seconds on a Mac that has
   never built the app.
2. Tailscale on both Macs, as for the phone: Workbench listens on its Tailscale
   address and nowhere else.
3. On the Mac running Workbench, **Workbench ▸ Pair iPhone… ▸ Copy Link**, and on the
   other one `workbench pair '<link>'` — quoted, because the link has an `&` in it.
   The link works once; what the Mac issues in exchange is kept in
   `~/.config/tabterm/pairing.json`, readable only by you. The Mac lists it with
   the phones, and forgets it from the same window.

### What it does to your terminal

Like a pane's attach process, `workbench` draws nothing: the terminal's output is
written to yours untouched, so it is your own terminal emulator — its fonts, its
scrollback, its handling of images and links — doing the work. The one piece of
interface it has is the list, and that is why the list is something you call up
rather than a sidebar that is always there: sharing the screen with a terminal
means redrawing that terminal yourself.

That has three consequences worth knowing:

- **Attaching takes the window over.** The protocol's catch-up starts from a
  reset terminal, so attaching — and each switch — resets yours, scrollback
  included, and replays the terminal's recent output. Scrolling up shows that
  terminal's history and never the last one's. Detaching puts back everything
  the program had switched on (the alternate screen, mouse reporting, bracketed
  paste, the keyboard protocol) and leaves the last screen above your prompt, as
  ssh does.
- **Old bells stay quiet.** A replay is history, and some of what a program
  wrote back then *did* something: rang the bell, raised a notification, wrote to
  the clipboard. Those are taken out of the replay — otherwise attaching would
  deliver every "Claude needs your attention" of the last hour at once — and
  pass through as usual once you are attached.
- **Your terminal's answers are dropped.** When a program asks the terminal a
  question, the Mac's Ghostty answers, exactly as with the phone; this
  terminal's answers to the same questions are filtered out of what it sends.
  Clicks and scrolling are not: a Mac's pointer is the real thing.

The list borrows the alternate screen, so the terminal underneath is intact when
it comes down and anything written meanwhile appears then. A program that was on
the alternate screen itself — an editor — is sent again from scratch instead.

A dropped connection is retried at once and caught up exactly, the same way a
phone is; a laptop changing networks shows nothing at all. After a second and a
half without the Mac, the list comes up to say so, and takes itself down when
the connection is back.

## Keys

| Shortcut | Action |
| --- | --- |
| `⌃⌘S` | Show or hide the sidebar |
| `⌘⇧G` / `⌘⇧I` | Show or hide Changes / CI checks |
| `⌘T` | New terminal tab |
| `⌘D` / `⌘⇧D` | Split right / down |
| `⌘⇧T` | Move the focused split to a new tab |
| `⌘W` | Close the focused split, or the tab when it's the only one |
| `⌘⇧1`…`⌘⇧9` | Jump to workspace N, counting Home then each worktree |
| `⌘]` / `⌘[` | Next / previous tab |
| `⌘1`…`⌘9` | Jump to tab N |

Everything else goes to the focused terminal, including your own Ghostty
keybinds. Split bindings from your config work too — `new_split`, `goto_split`
and `equalize_splits` are routed into the pane tree — but `⌘D` and `⌘⇧D` are
menu shortcuts, so those two chords are handled here whatever your config says.

## Storage

The Mac app stores repositories, layouts, settings, and pairing records in SQLite
via [GRDB](https://github.com/groue/GRDB.swift), at
`~/Library/Application Support/TabTerm/tabterm.sqlite`. Supporting files live
beside it. Set `TABTERM_DATA_DIR` to use a different data directory.

| Table | Holds |
| --- | --- |
| `repository` | Repositories added to the sidebar: top-level path and display name |
| `worktree` | Worktrees per repository, keyed by path so ids survive a refresh |
| `savedTab` | Each workspace's tabs; a null `worktreeId` means the Home workspace. `layout` holds the pane tree as JSON |
| `appState` | Key/value odds and ends — window frame, sidebar width, selected workspace, the APNs key's ids |
| `pairedDevice` | Paired phones and CLI clients: token hashes and phone notification details |

Schema changes go through `DatabaseMigrator` in `AppDatabase.swift`; add a new
`registerMigration` block rather than editing an existing one.

Tab layouts are stored as JSON in `savedTab.layout` rather than as a table of
panes with parent pointers. The tree is small, and it's always read and written
whole, so a column is the simpler shape — `SavedLayout` mirrors `SplitNode`,
carrying each split's orientation and divider position and each pane's
directory, the agent session it was in, and whether it held focus. Restoring replays the tree through the same `split`
calls the UI uses, so there's one code path for building panes. Rows written
before this column existed decode as a single pane.

If the database file can't be opened, the app falls back to an in-memory one and
logs why; database changes then won't survive relaunch.

Other files under the data directory:

| Path | Purpose |
| --- | --- |
| `hooks/tabterm-agent-hook.sh` | Installed agent status script, updated on launch |
| `agent-state/` | Per-terminal reports, cleared at startup |
| `hooks.json` | Global user hook configuration |
| `logs/hooks.log` | User hook output and exit status, with one rotated backup |
| `sounds/` | Imported completion sounds |
| `run/<pid>.sock` | Local session socket for each running copy, removed on quit |
| `apns/AuthKey.p8` | Imported notification key, readable only by you |

## Testing

From the repository root:

```sh
swift test                            # user hooks and Changes/CI
swift test --package-path TabTermKit   # protocol and terminal bookkeeping
swift test --package-path CLI          # command-line client
./scripts/bundle.sh
./build/Workbench.app/Contents/MacOS/Workbench --self-test
```

The app's self-test uses a throwaway database and exercises tabs, splits,
workspaces, saved layouts, close confirmation, file drops, agent status and
resume, completion sounds, and real PTY sessions. A simulated phone connects to
a loopback server to check pairing, attachment, sizing, reconnection, and remote
worktree creation. Hook installation is tested against fixtures, not your agent
settings. The CLI tests run the real client in a PTY against a fake host.

The self-test calls UI methods directly and skips normal app activation. Actual
AppKit drag targeting and live agent integration still need manual verification.

For the iPhone tests, use an installed simulator (adjust the destination name):

```sh
xcodebuild test -project iOS/TabTermMobile.xcodeproj -scheme TabTermMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
    -skipPackagePluginValidation
```

To try a build against a phone with separate workspaces and settings, run a
second copy with its own data directory and port. `--pairing-link` prints a
one-time link, which `xcrun simctl openurl booted '<link>'` hands to the simulator:

```sh
TABTERM_DATA_DIR=/tmp/workbench-try TABTERM_REMOTE_PORT=7767 \
    ./build/Workbench.app/Contents/MacOS/Workbench --pairing-link
```

A copy with its own data directory skips global Claude Code and Codex hook
installation.

## Known gaps

- **One window.** `⌘N` is not wired up. Closing the last tab leaves the window
  open; quit with `⌘Q`.
- **Pane dragging and zoom.** Use `⌘⇧T` to move a split to its own tab. Dragging
  a pane out into a tab or window and split zoom aren't supported.
- **Reordering.** Tabs and sidebar worktrees cannot be reordered by dragging.
- **Session lifetime.** Quitting ends shells and loses scrollback and running
  processes. Layouts and directories restore; eligible Claude Code and Codex
  sessions resume from their own transcripts. A crash can leave shells running.
- **Automatic resume.** There is no opt-out or confirmation. Recorded flags,
  including permission-skipping flags, are preserved. Close the pane before
  quitting if you don't want that session restored.
- **Agent support.** Status and resume support local Claude Code and Codex;
  only Claude Code has a custom tab icon. Agents behind SSH or inside containers
  aren't detected automatically, and other agents aren't integrated.
- **Global agent hooks.** Registration uses `~/.claude/settings.json` and
  `~/.codex/hooks.json`. There is no in-app switch to disable it; remove the
  entries manually.
- **Shared terminal size.** The smallest visible client's dimensions win.
  Output written at phone width stays that width in the Mac's scrollback, and
  replaying Mac-width output on a phone can look ragged until a redraw. A larger
  CLI window can show incorrect wrapping when the Mac pane is smaller; showing
  another tab on the Mac or shrinking the CLI window avoids it.
- **CLI controls.** The client shows one pane at a time, with splits as separate
  list entries. It can open tabs and create worktrees, but cannot close or remove
  them. Worktree creation uses `workbench new`, not the interactive list.
- **Remote pairing.** Each phone or CLI client pairs with one Mac and needs
  Tailscale. The phone has no terminal font pinch-to-zoom or lock-screen Live
  Activity.
- **libghostty updates.** The embedding API can change. The rebuild script has
  no version pin: a fresh clone uses `main`, while an existing checkout is built
  as-is.

## Licensing

`GhosttyKit.xcframework` and the two vendored `Sources/TabTerm/Ghostty/*Input*`
/ `NSEvent+Extension.swift` files come from
[Ghostty](https://github.com/ghostty-org/ghostty), MIT licensed — see
`Frameworks/GHOSTTY-LICENSE`.
