import Foundation
import TabTermKit

/// `workbench attach`: this terminal, as a view of one on the Mac.
///
/// Like a pane's own attach process, it passes bytes both ways and draws
/// nothing itself: what the Mac's terminal writes goes to this one untouched,
/// and so it is this terminal — its fonts, its scrollback, its handling of
/// whatever the program sends — doing the work. Unlike that process, the
/// session can be anywhere the phone's can: it comes over TCP, survives the
/// connection dropping, and can be swapped for another without leaving.
///
/// One loop on one thread, around `poll`.
final class AttachSession {
    private let host: PairedHost
    private let menuKey = MenuKey.configured

    private var link: HostLink?
    /// This connection has said hello and been let in.
    private var isWelcomed = false
    /// This connection has been asked for `current`.
    private var isAttached = false
    private var helloDeadline = Date.distantFuture
    private var state: HostState

    /// The terminal on screen, or wanted there.
    private var current: UUID?
    private var position = StreamPosition()
    /// The modes this terminal has been put in by what it was shown, so they
    /// can be taken back when it is handed back.
    private var modes = ModeTracker()
    /// The next output frame is a replay of old output, not new output.
    private var replayIsNext = false
    /// What is on screen isn't `current` as the Mac has it — another terminal
    /// was there, or the list drew over it — so it has to be sent afresh.
    private var screenIsLost = false

    private var scanner = InputScanner()
    private var lastInput = Date()
    private var isPasting = false

    private var menu: Menu?
    /// Output that arrived while the list was up, to show when it comes down.
    private var held = Data()
    private var heldAfterReset = false
    private var heldTooMuch = false
    /// A program was on the alternate screen when the list went up. The list
    /// borrows that screen, so the program's drawing doesn't survive it.
    private var borrowedAlternateScreen = false

    private enum Request {
        case opening(workspace: String)
        case newTab(id: String)
    }

    private var request: Request?
    private var requestDeadline = Date.distantFuture

    private let connector = Connector()
    private var lostAt: Date?
    private var retryAt = Date.distantFuture
    private var failures = 0
    private var hasAnnouncedLoss = false
    private var lastPing = Date()
    private var pingID = 0

    private var original: termios?

    /// A lone ESC is the Escape key once this long passes with nothing after
    /// it. A terminal writes a sequence in one go, so the rest of one is never
    /// this far behind.
    private static let escapeWait: TimeInterval = 0.05
    /// The Mac pings every 15 s and this pings every 10 s, so this much
    /// silence means the link is gone even if TCP hasn't noticed.
    private static let silenceLimit: TimeInterval = 25
    private static let pingInterval: TimeInterval = 10
    /// How long a dropped connection gets to come back before saying so. Most
    /// are back sooner — a laptop changing networks — and never show.
    private static let lossGrace: TimeInterval = 1.5
    private static let holdLimit = 8 * 1024 * 1024

    /// Takes over a connection that has already been welcomed. With no
    /// `session` it opens on the list of terminals.
    init(host: PairedHost, client: HostClient, session: UUID?) {
        self.host = host
        self.link = client.link
        self.state = client.state
        self.current = session
        self.isWelcomed = true
    }

    // MARK: - The loop

    func run() -> Never {
        original = Terminal.makeRaw()
        let signals = Signals.watch([SIGWINCH, SIGTERM, SIGHUP])

        if current == nil {
            openMenu(notice: "Nothing is open on \(host.name) yet. Pick a workspace to start a terminal in.")
        } else {
            screenIsLost = true
            resync()
        }
        if let link { process(link.drain()) }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var fds = [
                pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
                pollfd(fd: signals, events: Int16(POLLIN), revents: 0),
                pollfd(fd: connector.wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            if let link { fds.append(pollfd(fd: link.fd, events: Int16(POLLIN), revents: 0)) }

            let ready = poll(&fds, nfds_t(fds.count), scanner.hasPending ? 20 : 250)
            if ready < 0, errno != EINTR { quit(nil, code: 1) }

            if ready > 0, fds[0].revents != 0 {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count > 0 {
                    lastInput = Date()
                    route(scanner.feed(Array(buffer[0..<count])))
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    // The window this was running in is gone.
                    quit(nil)
                }
            }

            if ready > 0, fds[1].revents != 0 {
                var numbers = [UInt8](repeating: 0, count: 16)
                let count = read(signals, &numbers, numbers.count)
                for number in numbers.prefix(max(count, 0)) {
                    if Int32(number) == SIGWINCH { resized() } else { quit(nil) }
                }
            }

            if ready > 0, fds[2].revents != 0, let outcome = connector.take() {
                connected(outcome)
            }

            // Only if it is still the connection that was polled: any of the
            // above can have dropped it.
            if ready > 0, fds.count > 3, fds[3].revents != 0, let link, link.fd == fds[3].fd {
                if link.fill() {
                    process(link.drain())
                } else {
                    connectionLost()
                }
            }

            tick()
        }
    }

    private func tick() {
        let now = Date()
        if scanner.hasPending, now.timeIntervalSince(lastInput) >= Self.escapeWait {
            route(scanner.flush())
        }

        if let link {
            if !isWelcomed, now >= helloDeadline {
                connectionLost()
            } else if now.timeIntervalSince(link.lastHeard) > Self.silenceLimit {
                connectionLost()
            } else if isWelcomed, now.timeIntervalSince(lastPing) >= Self.pingInterval {
                lastPing = now
                pingID += 1
                link.send(.ping(Ping(id: pingID)))
            }
        }

        if link == nil {
            if !connector.isBusy, now >= retryAt {
                connector.start(hosts: host.hosts, port: host.port)
            }
            if let lostAt, !hasAnnouncedLoss, now.timeIntervalSince(lostAt) >= Self.lossGrace {
                hasAnnouncedLoss = true
                openMenu(notice: "Lost the connection to \(host.name). Reconnecting…", automatic: true)
            }
        }

        if request != nil, now >= requestDeadline {
            request = nil
            note("\(host.name) didn't answer.")
        }
    }

    // MARK: - The connection

    private func connectionLost() {
        link?.close()
        link = nil
        isWelcomed = false
        isAttached = false
        position.suspend()
        request = nil

        if lostAt == nil {
            // A connection that was working is worth an immediate retry: the
            // usual cause is a change of network, which the next attempt
            // survives.
            lostAt = Date()
            failures = 0
            retryAt = Date().addingTimeInterval(0.3)
        } else {
            retryLater()
        }
    }

    private func retryLater() {
        failures += 1
        retryAt = Date().addingTimeInterval(min(pow(2, Double(failures - 1)) * 0.5, 15))
    }

    private func connected(_ outcome: Connector.Outcome) {
        guard case .connected(let fd) = outcome else {
            retryLater()
            return
        }
        let link = HostLink(fd: fd)
        self.link = link
        helloDeadline = Date().addingTimeInterval(10)
        link.send(HostClient.hello(for: host))
    }

    private func welcomed() {
        isWelcomed = true
        lostAt = nil
        failures = 0
        hasAnnouncedLoss = false
        lastPing = Date()

        if menu?.isAutomatic == true, current != nil {
            closeMenu()
        } else {
            note(nil)
            resync()
        }
    }

    /// Make sure the Mac is sending `current`, from somewhere this screen can
    /// carry on from: where it left off, if what it shows is still good, and
    /// from scratch otherwise.
    private func resync() {
        guard let link, isWelcomed, let current, !isAttached || screenIsLost else { return }
        if screenIsLost {
            position = StreamPosition()
            screenIsLost = false
        }
        position.suspend()
        isAttached = true
        link.send(.attach(Attach(session: current, anchor: position.anchor, size: Terminal.size)))
    }

    // MARK: - From the Mac

    private func process(_ frames: [Frame]) {
        for frame in frames {
            switch frame.kind {
            case .control:
                if let message = try? frame.decode(ServerMessage.self) { handle(message) }

            case .output:
                guard frame.session == current, position.receiveOutput(count: frame.payload.count) else { continue }
                if replayIsNext {
                    replayIsNext = false
                    show(Replay.withoutSideEffects(frame.payload))
                } else {
                    show(frame.payload)
                }

            case .synthesized:
                guard frame.session == current, position.isCounting else { continue }
                show(frame.payload)

            case .input:
                break
            }
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .welcome:
            welcomed()

        case .denied(let denied):
            quit(Command.explain(.denied(denied), host: host), code: 1)

        case .state(let new):
            state = new
            menu?.update(new)
            if case .opening(let workspace) = request, let opened = new.workspace(id: workspace), opened.isOpen {
                if let session = Catalog.terminal(in: opened) {
                    switchTo(session)
                } else {
                    openTerminal(in: workspace)
                }
            }
            drawMenu()

        case .synced(let synced):
            guard synced.session == current else { return }
            position.apply(synced)
            guard synced.mode == .reset else { return }
            // What follows is this terminal from scratch: its modes, then its
            // recent output in one frame, then whatever it writes next.
            replayIsNext = true
            if menu == nil {
                resetScreen()
            } else {
                held.removeAll()
                heldAfterReset = true
                heldTooMuch = false
            }

        case .exit(let exit):
            guard exit.session == current else { return }
            current = nil
            isAttached = false
            position = StreamPosition()
            held.removeAll()
            let notice = exit.code == SessionExit.unknownSession
                ? "That terminal is gone."
                : "That terminal's shell exited."
            openMenu(notice: notice)

        case .tabCreated(let created):
            guard case .newTab(let id) = request, id == created.requestID else { return }
            switchTo(created.session)

        case .worktreeCreated:
            // Only `workbench new` asks for one, before it gets this far.
            break

        case .error(let error):
            request = nil
            note(error.message)

        case .ping(let ping):
            link?.send(.pong(ping))

        case .pong:
            break
        }
    }

    /// Put output on screen — or keep it for later, while the list has the
    /// screen.
    private func show(_ bytes: Data) {
        guard menu == nil else {
            guard !heldTooMuch else { return }
            held.append(bytes)
            if held.count > Self.holdLimit {
                // More than is worth keeping; ask for the terminal again when
                // the list comes down.
                held.removeAll()
                heldTooMuch = true
            }
            return
        }
        modes.feed(bytes)
        Terminal.write(bytes)
    }

    private func resetScreen() {
        Terminal.write(Terminal.reset)
        modes = ModeTracker()
    }

    // MARK: - From the keyboard

    private func route(_ tokens: [InputToken]) {
        var typed: [UInt8] = []
        func sendTyped() {
            if !typed.isEmpty { send(typed) }
            typed.removeAll()
        }

        for token in tokens {
            // A paste is text whatever it contains, and is never a command.
            if case .sequence(let bytes) = token, bytes == Paste.start || bytes == Paste.end {
                isPasting = bytes == Paste.start
                if menu == nil { typed += bytes }
                continue
            }
            if menu != nil {
                sendTyped()
                if !isPasting { menuInput(token) }
                continue
            }

            switch token {
            case .sequence(let bytes):
                if isPasting || isMouseReport(bytes) {
                    typed += bytes
                } else if let event = menuKey.event(in: bytes) {
                    sendTyped()
                    if event == .press { openMenu() }
                } else {
                    // The Mac's own terminal answers the program's questions;
                    // this terminal's answers to the same ones are dropped.
                    typed += ResponseFilter.keystrokes(from: bytes)
                }

            case .text(let bytes):
                guard !isPasting, let index = bytes.firstIndex(of: menuKey.byte) else {
                    typed += bytes
                    continue
                }
                typed += bytes[..<index]
                sendTyped()
                openMenu()
                let rest = Array(bytes[(index + 1)...])
                if !rest.isEmpty { menuInput(.text(rest)) }
            }
        }
        sendTyped()
    }

    private func send(_ bytes: [UInt8]) {
        guard let link, let current, isAttached else { return }
        link.send(.input(current, Data(bytes)))
    }

    private func menuInput(_ token: InputToken) {
        switch token {
        case .sequence(let bytes):
            if menuKey.event(in: bytes) == .press {
                sendMenuKeyThrough()
            } else if bytes.count == 3, bytes[1] == 0x5B || bytes[1] == 0x4F {
                // Arrows, in either of the forms a terminal sends them.
                if bytes[2] == 0x41 { moveSelection(-1) }
                if bytes[2] == 0x42 { moveSelection(1) }
            }

        case .text(let bytes):
            // An ESC with more after it is a sequence that never finished.
            if bytes.first == 0x1B {
                if bytes.count == 1 { goBack() }
                return
            }
            for (index, byte) in bytes.enumerated() {
                guard menu != nil else {
                    // A key closed the list; the rest was typed after it.
                    route([.text(Array(bytes[index...]))])
                    return
                }
                pressed(byte)
            }
        }
    }

    private func pressed(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "j"), 0x0E: moveSelection(1)
        case UInt8(ascii: "k"), 0x10: moveSelection(-1)
        case 0x0D, 0x0A:
            if let row = menu?.selected { choose(row) }
        case UInt8(ascii: "1")...UInt8(ascii: "9"):
            if let row = menu?.row(numbered: Int(byte - UInt8(ascii: "0"))) { choose(row) }
        case UInt8(ascii: "n"):
            if let workspace = menu?.selected?.workspace ?? current.flatMap({ state.locate($0)?.workspace.id }) {
                openTerminal(in: workspace)
            }
        case UInt8(ascii: "q"), UInt8(ascii: "d"):
            quit("[workbench: detached from \(host.name)]")
        case 0x03:
            goBack()
        case menuKey.byte:
            sendMenuKeyThrough()
        default:
            break
        }
    }

    private func moveSelection(_ delta: Int) {
        menu?.move(delta)
        drawMenu()
    }

    private func choose(_ row: Menu.Row) {
        switch row.target {
        case .terminal(let session):
            switchTo(session)
        case .unopened:
            guard ask(.openWorkspace(WorkspaceRef(workspace: row.workspace))) else { return }
            request = .opening(workspace: row.workspace)
            note("Starting its terminals…")
        case .empty:
            openTerminal(in: row.workspace)
        case nil:
            break
        }
    }

    private func openTerminal(in workspace: String) {
        let id = UUID().uuidString
        guard ask(.newTab(NewTab(workspace: workspace, requestID: id))) else { return }
        request = .newTab(id: id)
        note("Opening a terminal…")
    }

    /// Send something that will be answered, and start waiting for the answer.
    private func ask(_ message: ClientMessage) -> Bool {
        guard let link, isWelcomed else {
            note("Not connected to \(host.name) right now.")
            return false
        }
        requestDeadline = Date().addingTimeInterval(10)
        return link.send(message)
    }

    /// Pressing the key twice types it, for the program that wants it.
    private func sendMenuKeyThrough() {
        guard current != nil else { return }
        let bytes = menuKey.bytes(keyboardFlags: modes.modes.keyboardFlags)
        closeMenu()
        send(bytes)
    }

    // MARK: - The list

    private func openMenu(notice: String? = nil, automatic: Bool = false) {
        if menu != nil {
            note(notice)
            return
        }
        var menu = Menu(hostName: state.hostName.isEmpty ? host.name : state.hostName, keyName: menuKey.name)
        menu.notice = notice
        menu.isAutomatic = automatic
        menu.canGoBack = current != nil
        menu.update(state)
        if let current { menu.select(current) }
        self.menu = menu

        // Take back what the program switched on first — the list reads plain
        // keys, and leaving a program's alternate screen is what lets the
        // list have one of its own.
        borrowedAlternateScreen = modes.modes.alternateScreen != nil
        Terminal.write(modes.modes.undo)
        Terminal.write(Menu.enter)
        drawMenu()
    }

    private func drawMenu() {
        guard var menu else { return }
        menu.canGoBack = current != nil
        self.menu = menu
        Terminal.write(menu.render(size: Terminal.size))
    }

    /// Change the line under the list's title, if the list is up.
    private func note(_ notice: String?) {
        guard menu != nil else { return }
        menu?.notice = notice
        drawMenu()
    }

    private func goBack() {
        if current != nil { closeMenu() }
    }

    /// Take the list down and carry on with the terminal behind it.
    private func closeMenu() {
        guard menu != nil else { return }
        dismissMenu()

        if heldAfterReset {
            // The Mac started this terminal over while the list was up; what
            // was kept is that fresh start.
            resetScreen()
        } else if borrowedAlternateScreen || heldTooMuch {
            screenIsLost = true
        } else {
            // The screen underneath is as it was. Put back the modes that
            // were taken from it, and show what it missed.
            Terminal.write(modes.modes.preamble)
        }

        let missed = held
        held = Data()
        heldAfterReset = false
        heldTooMuch = false
        if !screenIsLost { show(missed) }
        resync()
    }

    private func dismissMenu() {
        menu = nil
        request = nil
        Terminal.write(Menu.leave)
    }

    private func switchTo(_ session: UUID) {
        guard session != current else {
            closeMenu()
            return
        }
        if menu != nil { dismissMenu() }
        held = Data()
        heldAfterReset = false
        heldTooMuch = false

        if let current, isAttached { link?.send(.detach(SessionRef(session: current))) }
        current = session
        isAttached = false
        // Whatever is on screen belongs to the terminal just left.
        screenIsLost = true
        resync()
    }

    // MARK: - Size

    private func resized() {
        drawMenu()
        guard let link, let current, isAttached else { return }
        link.send(.resize(Resize(session: current, size: Terminal.size)))
    }

    // MARK: - Leaving

    /// Hand the terminal back the way it was found, and go.
    private func quit(_ message: String?, code: Int32 = 0) -> Never {
        if let current, isAttached { link?.send(.detach(SessionRef(session: current))) }
        link?.close()

        // With the list up, the program's modes were already taken back.
        Terminal.write(menu == nil ? modes.modes.undo : Data(Menu.leave.utf8))
        Terminal.write(Terminal.tidy(rows: Terminal.size.rows))
        Terminal.restore(original)
        if let message { print(message) }
        exit(code)
    }
}
