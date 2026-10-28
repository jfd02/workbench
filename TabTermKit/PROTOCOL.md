# Workbench wire protocol

How the Mac and the phone talk, and how a Ghostty pane talks to the session
behind it. The types live in `Sources/TabTermKit`; this is what they mean.

## Who holds what

Workbench owns every terminal session. Each one is a pty and a shell that Workbench
spawned itself, with the recent output kept in an `OutputRing`. A session has
any number of **clients**, each a view of the same live terminal:

- **The Mac pane.** Its Ghostty surface doesn't run a shell; it runs
  `Workbench --attach <socket> <session>`, a small process that passes bytes
  between Ghostty's pty and the session over a Unix socket. It is always
  attached while the pane exists, and it is the client that answers the
  program's terminal queries.
- **Phones.** Over TCP on the Mac's Tailscale address, port 7766 by default.
- **`tabterm`, on another Mac.** The same connection and the same messages as
  a phone, with a real terminal on the far end instead of an emulator in an
  app. It sends its mouse reports as input, which a phone never does, and
  takes the bells, notifications and clipboard writes out of a `reset` replay
  before showing it, since its terminal would act on them a second time.

## Framing

Every message is a frame: a 4-byte big-endian length, a kind byte, then for
terminal data the session's 16-byte UUID, then the payload.

| Kind | | Direction | Payload |
| --- | --- | --- | --- |
| 1 | control | both | JSON `ClientMessage` or `ServerMessage` |
| 2 | output | host → client | terminal output. **Counted** |
| 3 | input | client → host | keyboard bytes for the session |
| 4 | synthesized | host → client | bytes the host made up (the mode preamble). **Not counted** |

## Connecting (phone)

1. The phone opens TCP to the first host in its list that answers.
2. It sends `hello` with its `deviceToken` or, the first time, the one-time
   `pairingCode` from the pairing link.
3. The Mac answers `welcome` (with a `deviceToken` on the pairing visit, which
   the phone must keep) or `denied` and closes.
4. The Mac sends `state` straight away and again whenever anything in it
   changes.

## Stream positions

Every byte of a session's output has a position. A client counts the counted
(kind 2) bytes it receives for a session, starting from the `seq` in the
`synced` message for its latest attach. The `epoch` identifies the stream: a
different epoch means a different session object and positions don't carry
over.

## Attaching

`attach { session, anchor, size, visible }`, where `anchor` is either empty
(`fresh`: nothing on screen) or `{ epoch, seq }`: everything up to `seq` is on
screen.

The host replies with `synced { session, epoch, seq, mode, size }` and then
bytes:

- **`exact`** — the anchor was still in the ring and the terminal hasn't
  changed size since. The counted bytes that follow are exactly what the
  client missed. Keep the screen.
- **`reset`** — anything else. The client must reset its terminal (`ESC c`),
  then apply what follows: a synthesized mode preamble, then the recent output
  (counted, starting at `seq`). The host then asks the program to redraw.

After that, live output arrives as counted frames. A client counts from `seq`.

## Size

A session's pty takes the **smallest** size among its visible clients, as tmux
does. A phone that goes to the background sends
`visibility { visible: false }` and stops counting towards the size, so the
Mac gets its full width back; when it comes back it sends
`visibility { visible: true }`. A hidden client keeps receiving output until
the size changes; after that it is withheld, and its return is served like a
`reset` attach. `resize` reports a client's new size.

## Typing

- `input` frames carry keystrokes. A phone must pass whatever its terminal
  emulator wants to send through `ResponseFilter.keystrokes(from:)` first: the
  Mac answers the program's queries, and a second answer lands on the command
  line as garbage.
- `submit { text, pressEnter }` types a message the way a person would: the
  text (inside bracketed-paste markers when the program asked for them), then
  Enter half a second later on its own. Agents treat bytes that arrive together
  as a paste, and an Enter inside a paste becomes a newline instead of sending.

## Everything else

| Message | |
| --- | --- |
| `detach { session }` | stop receiving a session |
| `openWorkspace { workspace }` | start a worktree's terminals without switching the Mac to it |
| `newTab { workspace, requestID }` | open a terminal; answered with `tabCreated { requestID, workspace, session }` |
| `newWorktree { workspace, branch, requestID }` | make a worktree in the repository `workspace` belongs to, as the Mac's sheet would for that branch name, without switching the Mac to it; answered with `worktreeCreated { requestID, workspace }` once `state` has it, or with `error` carrying git's reason |
| `viewing { session? }` | what the phone has on screen; the Mac follows it when nobody is at the Mac |
| `registerPush { token, environment, bundleID }` | where to send notifications when an agent needs you |
| `ping` / `pong { id }` | liveness. The Mac pings every 15 s; a visible client that misses two is dropped |
| `exit { session, code }` | the session's shell exited. Code `-1` means the Mac has no such session: it was closed, or Workbench restarted and its terminals came back as new sessions |
| `error { message }` | a request that couldn't be done |

A message one end doesn't know is not a different protocol version: the Mac
answers it with `error { "Unrecognized message." }` and carries on, so a
message can be added without turning away every client built before it.
`newWorktree` was added that way.

## The attach process (Mac pane)

The pane's process connects to the Unix socket and sends
`attachHello { session, size, environment }` first. The first attach to a
session spawns its shell, with the environment Ghostty gave the attach process
(so `TERM`, `TERMINFO`, `GHOSTTY_RESOURCES_DIR` and the rest match a normal
Ghostty shell) plus shell integration and Workbench's own variables. After that
it is a client like any other, always visible, sending `resize` when Ghostty's
pty changes size and `input` for everything typed.
