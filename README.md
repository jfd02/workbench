# TabTerm

A native macOS app with a sidebar of git repositories on the left and a tab bar
on top. Each tab is either a **real Ghostty terminal** (via libghostty) or an
**embedded web browser** (WKWebView).

**Every worktree gets its own set of tabs.** Pick a worktree in the sidebar and
the tab bar swaps to that worktree's terminals and pages; switch away and they
keep running, so you can leave a build going in one branch while you work in
another. Terminals start at the worktree's directory. A worktree with Claude
Code running in it shows a dot on the right of its row — amber while it works,
red when it's waiting for you — so an agent you left running in another branch
says when it needs you. See [Agent status](#agent-status).

The `+` sits right after the last tab and opens a vertical launcher: Terminal,
Web Browser, then any sites you've pinned. One click opens the row — there's no
address prompt, so Web Browser goes straight to Google. Pin the page you're on
with the pin button in the browser toolbar, and it shows up in that list.

**Add Site…** at the bottom of the launcher saves a link without visiting it
first: type `figma.com`, leave the name blank and it becomes "Figma". Pinned
sites are drawn with their own icon, as are browser tabs, and a terminal
running Claude Code shows a Claude mark instead of the terminal symbol — so a
background tab still says what's happening in it. See
[Icons](#icons) for where those come from.

Closing only asks when there's something to lose. A terminal sitting at a prompt
and any web page just close; a terminal with a process still running warns that
it'll be killed. A shell that exits on its own closes silently too.

Unselected tabs show the `⌘1`…`⌘9` that reaches them, swapping to a close button
on hover.

<!-- screenshot: tab bar with a "~" terminal tab and a "Hacker News" browser tab -->

## What "real Ghostty" means here

This is not a terminal emulator that looks like Ghostty — it links
`libghostty` itself, the same core that ships inside Ghostty.app:

- Ghostty's Metal renderer draws into an `NSView` we hand it.
- It reads **your** config (`~/.config/ghostty/config` and the
  `com.mitchellh.ghostty` support directory), so fonts, themes, padding, and
  keybinds match the Ghostty you already run.
- `$TERM` is `xterm-ghostty`, resolved from the terminfo bundled into the app.

## Build

```sh
./scripts/bundle.sh          # builds + assembles build/TabTerm.app
open build/TabTerm.app
```

`swift build` alone produces the binary but **not** a runnable app: libghostty
finds its terminfo and shell-integration by walking up from the executable to
`Contents/Resources`, so it must run from the bundle.

### Sharing it with another Mac

```sh
./scripts/package.sh          # build/TabTerm-<version>-<stamp>.zip, ~8 MB
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
  `xattr -dr com.apple.quarantine /Applications/TabTerm.app`.

### Updating without losing your data

Everything you accumulate — repositories, worktrees, pinned sites, saved tabs,
window frame — lives in `~/Library/Application Support/TabTerm/tabterm.sqlite`,
outside the bundle. **Replacing `TabTerm.app` keeps all of it.** Quit the app,
drop the new one over the old, reopen.

Schema changes ride along: `DatabaseMigrator` runs any migrations the new build
adds the first time it launches, so an older database is upgraded in place.

The one direction that doesn't work is backwards — an older build opening a
database a newer one has migrated. If you want a way back, copy the `.sqlite`
file somewhere before updating.

### Rebuilding libghostty

`Frameworks/GhosttyKit.xcframework` (a ~129 MB static library) and
`Resources/{terminfo,ghostty}` are checked in prebuilt. To regenerate them from
Ghostty source:

```sh
./scripts/build-ghostty.sh              # clones ghostty into build/ghostty-src
./scripts/build-ghostty.sh /path/to/ghostty
```

This needs `zig` matching Ghostty's `minimum_zig_version` (0.16.0 at the time of
writing) and `xcodebuild`. It takes a while — the whole terminal core compiles.

## Layout

| Path | What |
| --- | --- |
| `Sources/TabTerm/Ghostty/GhosttyApp.swift` | Process-wide `ghostty_app_t`, and the C callbacks libghostty calls back into (clipboard, titles, actions) |
| `Sources/TabTerm/Ghostty/GhosttySurfaceView.swift` | The `NSView` hosting one terminal surface: keyboard, IME, mouse, sizing, focus |
| `Sources/TabTerm/Ghostty/GhosttyInput.swift` | Key/mouse translation tables, vendored from Ghostty (MIT) |
| `Sources/TabTerm/Ghostty/NSEvent+Extension.swift` | `NSEvent` → `ghostty_input_key_s`, vendored from Ghostty (MIT) |
| `Sources/TabTerm/Git/GitService.swift` | The `git` CLI: worktree list/add/remove, branches, and the sibling-path convention |
| `Sources/TabTerm/Storage/AppDatabase.swift` | SQLite store (GRDB): connection, migrations, and the `appState` key/value table |
| `Sources/TabTerm/Storage/RepositoryStore.swift` | Repositories and worktrees, reconciled against what git reports |
| `Sources/TabTerm/UI/SidebarViewController.swift` | The left panel, its context menus, and the add-repository flow |
| `Sources/TabTerm/Tabs/Workspace.swift` | One tab set per worktree, materialized lazily and persisted |
| `Sources/TabTerm/Tabs/` | The tab model, the two tab kinds, and the pinned-sites store |
| `Sources/TabTerm/Tabs/SplitTree.swift` | The tree of panes behind one tab |
| `Sources/TabTerm/Tabs/Tab.swift` | One tab: its panes, which one has focus, and closing them |
| `Sources/TabTerm/UI/TabBarView.swift` | Tab strip and `+` button; tabs are drag sources |
| `Sources/TabTerm/UI/SplitContainerView.swift` | Panes as nested `NSSplitView`s, and the drop target for dragged tabs |
| `Sources/TabTerm/UI/NewTabDialog.swift` | The Terminal / Web Browser picker sheet |
| `Sources/TabTerm/UI/AddSiteDialog.swift` | The sheet behind **Add Site…**, and what counts as an address |
| `Sources/TabTerm/Tabs/FaviconStore.swift` | Site icons: finding them, normalizing them, and the cache |
| `Sources/TabTerm/Tabs/ForegroundProcess.swift` | What a terminal is running, read from its foreground pid |
| `Sources/TabTerm/UI/ClaudeIcon.swift` | The mark shown on a tab running Claude Code |
| `Sources/TabTerm/Agents/ClaudeHooks.swift` | The hook script, and merging it into `~/.claude/settings.json` |
| `Sources/TabTerm/Agents/AgentActivity.swift` | Turning the hook's events back into per-terminal state |
| `Sources/TabTerm/UI/AgentStatusDotView.swift` | The dot on a sidebar row |
| `Sources/TabTerm/MainWindowController.swift` | Window, tab list, content swapping |

## Repositories and worktrees

**Add Repository…** at the bottom of the sidebar takes any folder inside a git
repository and stores its top level. Its worktrees are read straight from
`git worktree list`, so the main checkout shows up alongside the others — git
treats it as a worktree, and so does this.

Each repository row carries a **+** on its right edge — that's the quick way to
add a worktree; the same thing sits in the row's context menu as
**New Worktree…**. Either one asks for a branch (new, or an existing one that
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

### Agent status

A worktree running Claude Code carries a **dot on the right of its row**: amber
and slowly pulsing while Claude is working, red when it has stopped and wants
you — either a permission prompt it can't get past, or a turn that finished and
is waiting for your next instruction. A worktree with nothing running has no
dot at all, so the sidebar looks exactly as it did before you started anything.

The dot is per worktree, not per terminal: it shows the most demanding state
across every terminal in that workspace, so one prompt waiting for an answer is
never hidden behind another pane's progress. Fold a repository away and its
header takes over its worktrees' dots, so collapsing a section never quietly
hides an agent. Selecting a worktree — or coming
back to the window — counts as having seen it, and puts out a red dot that only
meant "the turn ended". A dot that means "answer me" stays lit until the agent
itself moves on, because looking at a prompt isn't answering it.

Nothing in a terminal announces this, so Claude Code is asked to say so itself.
At first launch TabTerm writes a small script to
`~/Library/Application Support/TabTerm/hooks/tabterm-agent-hook.sh` and
registers it in `~/.claude/settings.json` against the events that mark the
edges of a turn:

| Event | What the dot does |
| --- | --- |
| `SessionStart`, `SessionEnd` | goes out |
| `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` | amber — working |
| `PermissionRequest`, `Notification` | red — blocked on you |
| `Stop`, `StopFailure` | red — the turn ended |

`PostToolUse` isn't a state of its own; it's what fires once you've answered a
permission prompt, and so the only signal that a blocked agent is unblocked.
`Notification` is narrowed to `permission_prompt` and `elicitation_dialog` —
its `idle_prompt` fires a minute after a turn ends, which `Stop` already said.

Each terminal exports `TABTERM_AGENT_ID` and `TABTERM_AGENT_DIR`, so the script
knows which pane it is running in and where to leave the answer, and **exits
immediately when they aren't set** — a `claude` started from any other terminal
behaves exactly as it did before. It writes one small JSON file per terminal by
rename, which is atomic and moves the directory's mtime; the app watches that
directory with a `DispatchSource` and never polls. A file rather than a socket
because the hook is a shell script with nothing but the shell to work with, and
a listening port would put the app in front of the firewall for no reason.

Events from subagents (the Task tool) are dropped: the terminal is busy either
way, and a subagent finishing is not the turn ending.

Only entries naming our own script are ever touched, so the rest of
`settings.json` — including your own hooks, and other tools' — is left alone;
installing twice doesn't stack up duplicates. To uninstall, delete those
entries and the script. Note that the file is rewritten with sorted keys, since
JSON objects have no order to preserve.

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

`⌘D` splits the focused pane to the right, `⌘⇧D` splits it downwards, and each
half can be split again. A terminal splits into another terminal in the same
directory; a browser splits into another view of the same page. Drag a divider
to resize.

You can also **drag a tab from the strip onto a pane**: the half of the pane it
would take lights up as you move — left, right, top or bottom, whichever edge
you're nearest — and dropping moves that tab in as a split, bringing its own
splits with it.

The unfocused panes are dimmed with your `unfocused-split-fill` and
`unfocused-split-opacity`, the same two settings Ghostty dims its own splits
with, and their cursors stop blinking — that part is libghostty's doing, since
each surface is told whether it holds the focus.

## Icons

A tab draws whatever its focused pane reports and falls back to the terminal or
globe symbol when there's nothing better, so an icon is always an addition, never
a blank space.

**Sites.** Icons are keyed by host: one per site, shared by every page on it and
by any pin pointing there. A loaded page is asked for its `<link rel="icon">`
tags first; failing that the store tries `/favicon.ico`; failing that it reads
the page's HTML for tags the page never got the chance to declare. Whatever
comes back — `.ico`, `.png`, `.svg` — is re-encoded as one 32×32 PNG and written
to SQLite, so the launcher draws a pin's icon before anything has loaded. A host
with no icon is remembered as missing for the rest of the session rather than
retried on every list rebuild.

**Claude.** Nothing announces that the program in a terminal changed, so each
terminal asks libghostty for its pty's foreground pid every two seconds and,
only when that pid changes, reads the process's command line via
`KERN_PROCARGS2`. Both shapes Claude Code runs as count: a `claude` binary, and
`node .../@anthropic-ai/claude-code/cli.js` from an npm install. Only the
executable and first two arguments are looked at, so an editor holding a
`claude.md` isn't mistaken for it. The mark is an SF Symbol in Claude's orange —
put a `claude.png` in `Resources/Icons/` to use a real one instead.

## Keys

| Shortcut | Action |
| --- | --- |
| `⌃⌘S` | Show or hide the sidebar |
| `⌘T` | New tab (opens the picker) |
| `⌘D` / `⌘⇧D` | Split right / down |
| `⌘W` | Close the focused split, or the tab when it's the only one |
| `⌘⇧1`…`⌘⇧9` | Jump to workspace N, counting Home then each worktree |
| `⌘]` / `⌘[` | Next / previous tab |
| `⌘1`…`⌘9` | Jump to tab N |

Everything else goes to the focused terminal, including your own Ghostty
keybinds. Split bindings from your config work too — `new_split`, `goto_split`
and `equalize_splits` are routed into the pane tree — but `⌘D` and `⌘⇧D` are
menu shortcuts, so those two chords are handled here whatever your config says.

## Storage

Everything the app persists *between launches* lives in one SQLite database via
[GRDB](https://github.com/groue/GRDB.swift), at
`~/Library/Application Support/TabTerm/tabterm.sqlite`. Nothing of ours is in
UserDefaults.

| Table | Holds |
| --- | --- |
| `pinnedSite` | Pinned sites: title, URL, an explicit `position` for ordering, and a `normalizedURL` unique key |
| `favicon` | One 32×32 PNG per host, with the time it was fetched |
| `repository` | Repositories added to the sidebar: top-level path and display name |
| `worktree` | Worktrees per repository, keyed by path so ids survive a refresh |
| `savedTab` | Each workspace's tabs; a null `worktreeId` means the Home workspace. `layout` holds the pane tree as JSON |
| `appState` | Key/value odds and ends — window frame, sidebar width, selected workspace |

Schema changes go through `DatabaseMigrator` in `AppDatabase.swift`; add a new
`registerMigration` block rather than editing an existing one.

Tab layouts are stored as JSON in `savedTab.layout` rather than as a table of
panes with parent pointers. The tree is small, and it's always read and written
whole, so a column is the simpler shape — `SavedLayout` mirrors `SplitNode`,
carrying each split's orientation and divider position and each pane's kind, URL
or directory, and whether it held focus. Restoring replays the tree through the
same `split` calls the UI uses, so there's one code path for building panes.
Rows written before this column existed decode as a single pane.

Two details worth knowing:

- `normalizedURL` is scheme+host+path, lowercased and stripped of a trailing
  slash, so `example.com/docs` and `example.com/docs/?utm_source=x` are one pin
  rather than two.
- Pins written by the older UserDefaults build are imported once at startup
  (`PinnedSites.migrateFromUserDefaultsIfNeeded`) and the old key is deleted.
  That code can be dropped once no old installs remain.

If the database file can't be opened, the app falls back to an in-memory one and
logs why — it keeps running, it just won't remember anything.

Two things sit beside it in `~/Library/Application Support/TabTerm/` rather than
in the database, because a shell script has to be able to write them:
`hooks/` holds the agent status hook, and `agent-state/` holds one file per live
terminal. Neither survives a launch — `agent-state` is emptied at startup, since
every terminal comes back as a fresh shell and no file written before then
describes anything that is still running.

## Testing

```sh
./build/TabTerm.app/Contents/MacOS/TabTerm --self-test
```

Runs an in-process smoke test (`Sources/TabTerm/SelfTest.swift`) covering the
database and `appState` round-trips, tab creation, URL normalization, the
pinned-sites store and its ordering, the pin button on a real loaded page, the
dialog's row list, adding a site through its sheet, the icon cache and the
`<link rel="icon">` parsing behind it, the close-confirmation flow, splitting and
closing panes, and dropping a tab into a pane. It exits non-zero on failure.

Agent status is covered end to end except for Claude itself: the event-to-state
mapping, the priority order a worktree picks its dot with, reading real files
out of a throwaway directory, the directory watch noticing one written the way
the hook writes it, acknowledgement (a finished turn clears when seen, a blocked
one doesn't), and the `settings.json` merge — run against fixtures rather than
your real file, and checked for preserving other tools' hooks, not duplicating
on a second install, and leaving nothing behind on removal. The one live check
is that a terminal's `TABTERM_AGENT_ID` actually reaches its pty: the test opens
a terminal whose command writes the variable to a file and waits for it to
appear, which is the only way to know libghostty took the environment.

Icons are tested in the two halves that can be checked offline: the store, given
a PNG directly, and the classifier that decides whether a command line is Claude
Code. What the run does check against the live system is that libghostty reports
a foreground pid at all and that its command line can be read — the ground both
of those stand on. `FaviconStore.networkEnabled` is off for the whole run, so no
step can quietly depend on a site being reachable.

The drag is driven by handing the pane area a stand-in `NSDraggingInfo` rather
than a real mouse, so the test can check what a drop would highlight and where
it would land. What it can't check is AppKit picking our view as the drag
destination in the first place — that needs a real drag.

It runs against a throwaway database in `$TMPDIR`, so it never touches your real
pins. Steps that depend on AppKit settling (sheets attaching, a page loading)
poll for the condition instead of sleeping, so the run isn't timing-dependent.

It calls the same methods the buttons call rather than synthesizing clicks, so
it **never moves the cursor and never takes focus** — you can keep working while
it runs. It also skips the usual `NSApp.activate` on launch for that reason.

Controls carry accessibility identifiers (`newTabButton`, `newTabRow`,
`pinButton`, `addSiteAddress`, `addSiteTitle`, `addSiteButton`) if you ever want
to drive it externally instead.

## Known gaps

- **One window.** `⌘N` is not wired up. Closing the last tab in a workspace
  leaves it empty rather than closing the window — quit with `⌘Q`.
- **Splits are per tab.** A pane can't be dragged out into its own tab or
  window, only tabs can be dragged into panes. There is no split zoom.
- **Terminals restore as fresh shells.** The layout comes back, but scrollback
  and running processes can't — a shell that was mid-`tail -f` reopens at a
  prompt in the same directory.
- Tabs cannot be reordered by dragging, and worktrees can't be reordered in the
  sidebar.
- **Cached icons never expire.** A site that changes its favicon keeps the old
  one until the `favicon` row is deleted; there is no refresh and no way to
  clear the cache from the UI.
- A pinned site can be removed and re-added but not edited: renaming one means
  removing it and adding it again.
- Only Claude Code gets a mark. Nothing else running in a terminal changes the
  tab's icon, and a Claude running behind `ssh` or inside a container isn't
  visible to us — the foreground process is the local `ssh`.
- **Agent status is Claude-only and local-only.** Codex, OpenCode and the rest
  all have their own hook or plugin shapes; none are wired up. A Claude running
  over `ssh` never sees `TABTERM_AGENT_ID`, so it reports nothing.
- The dot lives on the sidebar row, not on the tab. A worktree with several
  terminals tells you *something* wants you, not which one — you still have to
  look through its tabs to find it.
- Hook registration is global (`~/.claude/settings.json`), so it is written once
  for every project rather than per repository, and there is no in-app switch to
  turn it off — remove the entries by hand.
- A turn that ends while you are watching that worktree still lights the dot for
  the moment between the `Stop` hook firing and the app noticing the window is
  key; and a worktree you have open in the background stays red until you click
  back to it, even if you read the output on another display.
- The sidebar doesn't watch the filesystem. A worktree added or removed by git
  outside the app shows up after **Refresh Worktrees** on the repository.
- The browser tab is deliberately minimal: back/forward/reload, an address bar,
  and DuckDuckGo for anything that isn't a URL. No bookmarks, downloads, or
  per-tab profiles.
- libghostty's embedding API is explicitly unstable. A future Ghostty release
  can break the wrapper; `scripts/build-ghostty.sh` pins nothing, so a rebuild
  tracks `main`.

## Licensing

`GhosttyKit.xcframework` and the two vendored `Sources/TabTerm/Ghostty/*Input*`
/ `NSEvent+Extension.swift` files come from
[Ghostty](https://github.com/ghostty-org/ghostty), MIT licensed — see
`Frameworks/GHOSTTY-LICENSE`.
