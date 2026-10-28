import CTabTermPTY
import Foundation
import TabTermKit

/// Something showing a session: a Ghostty pane's attach process, or a phone.
///
/// Called on the session queue.
protocol SessionClient: AnyObject {
    /// Output, counted towards the stream position.
    func session(_ session: TerminalSession, didOutput bytes: Data)
    /// Bytes the host made up — the mode preamble ahead of a replay.
    func session(_ session: TerminalSession, didSynthesize bytes: Data)
    func session(_ session: TerminalSession, didSync synced: Synced)
    func session(_ session: TerminalSession, didExit code: Int32)

    /// Bytes queued for this client but not yet sent.
    var bufferedBytes: Int { get }
    /// The client fell too far behind and is being dropped.
    func sessionDidDropForBackpressure(_ session: TerminalSession)
}

/// One terminal: a shell on a pty that Workbench spawned and owns.
///
/// Before this existed, libghostty owned every pane's pty, and nothing outside
/// the pane could see its output. Now the pty lives here and the pane is just
/// the first of its clients — any number can attach, see the same live
/// terminal, and type into it. That is what lets a phone pick up a terminal the
/// Mac is showing.
///
/// Everything here runs on `SessionManager.queue`. The few things the UI asks
/// from the main thread (`foregroundPID`, `hasRunningProcess`) go through
/// `queue.sync`, which is safe because nothing on the queue ever waits for the
/// main thread.
final class TerminalSession {
    let id: UUID

    /// Identifies this session's output stream. A client anchored to another
    /// epoch — a session object that no longer exists — can't be caught up.
    let epoch = String(UUID().uuidString.prefix(8))

    let queue: DispatchQueue

    /// Where the shell starts, and what it runs instead of the login shell.
    let directory: String?
    let command: String?
    /// Workbench's own additions to the shell's environment.
    let extraEnvironment: [String: String]

    enum Phase: Equatable {
        /// Waiting for the pane to attach and say what Ghostty would have
        /// given the shell.
        case pending
        case running
        case exited(Int32)
    }

    private(set) var phase: Phase = .pending
    private(set) var pid: pid_t = 0
    private var master: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSourceActive = false
    private var processSource: DispatchSourceProcess?
    private var pendingWrites: [Data] = []
    private var pendingWriteOffset = 0

    private var ring = OutputRing()
    /// Modes at the live end of the stream, fed as output arrives.
    private var liveModes = ModeTracker()
    private var agentProgramStatus = AgentProgramStatus()

    private(set) var size = TerminalSize(cols: 80, rows: 24)
    /// Where the stream was when the pty last changed size. Bytes on either
    /// side were laid out for different widths, so no client can be caught up
    /// across it.
    private var lastResizeSeq: UInt64?
    private var resizeGeneration = 0

    private final class Entry {
        let client: SessionClient
        var size: TerminalSize?
        var visible: Bool
        /// The Mac pane: the client that started the shell. Its Ghostty is a
        /// real terminal with its own scrollback, so it is always sent
        /// everything, whatever size the pty is.
        let isPane: Bool
        /// Set when the pty changed size while this client was hidden: its
        /// copy stopped matching there, so its output is withheld until it
        /// comes back and is reset.
        var divergedAt: UInt64?

        init(client: SessionClient, size: TerminalSize?, visible: Bool, isPane: Bool) {
            self.client = client
            self.size = size
            self.visible = visible
            self.isPane = isPane
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Whether the Mac pane is on screen. A pane in a background tab keeps
    /// its last size but doesn't hold anyone else to it.
    private var paneVisible = true
    private var submissions: [(text: String, pressEnter: Bool)] = []
    private var submitting = false

    /// Called on the session queue once the shell is gone and every client
    /// has been told.
    var onFinish: ((TerminalSession) -> Void)?

    /// A client that stops reading gets this much buffered before it is cut
    /// off; the terminal itself never waits for anyone.
    static let backpressureLimit = 8 * 1024 * 1024

    /// Gap between a submitted message and its Enter. Agents treat bytes that
    /// arrive together as a paste, and an Enter inside a paste is a newline in
    /// the draft rather than a send; half a second puts it in a read of its own.
    static let submitEnterDelay: TimeInterval = 0.5

    init(id: UUID, directory: String?, command: String?, environment: [String: String], queue: DispatchQueue) {
        self.id = id
        self.directory = directory
        self.command = command
        self.extraEnvironment = environment
        self.queue = queue
    }

    // MARK: - Spawning

    /// Start the shell. Called for the first attach from the pane, with the
    /// environment Ghostty gave the attach process.
    private func spawn(size: TerminalSize, ghosttyEnvironment: [String: String]?) {
        guard phase == .pending else { return }

        let plan = SessionEnvironment.plan(
            command: command,
            directory: directory,
            ghosttyEnvironment: ghosttyEnvironment,
            extra: extraEnvironment
        )
        self.size = size.clamped

        var masterFD: Int32 = -1
        var childPID: pid_t = 0
        let result = withCStrings(plan.arguments) { argv in
            withCStrings(plan.environment.map { "\($0.key)=\($0.value)" }.sorted()) { envp in
                tabterm_spawn(
                    plan.path, argv, envp, plan.directory,
                    UInt16(clamping: self.size.cols), UInt16(clamping: self.size.rows),
                    UInt16(clamping: self.size.pixelWidth), UInt16(clamping: self.size.pixelHeight),
                    &masterFD, &childPID
                )
            }
        }

        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            Ghostty.logger.error("session spawn failed: \(reason, privacy: .public)")
            broadcast(Data("\r\nTabTerm couldn't start a shell: \(reason)\r\n".utf8))
            finish(code: 127)
            return
        }

        master = masterFD
        pid = childPID
        phase = .running
        LiveSessions.add(pid: childPID, master: masterFD)

        let reader = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        reader.setEventHandler { [weak self] in self?.readOutput() }
        reader.resume()
        readSource = reader

        let writer = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: queue)
        writer.setEventHandler { [weak self] in self?.flushWrites() }
        writeSource = writer

        let process = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: queue)
        process.setEventHandler { [weak self] in self?.childExited() }
        process.resume()
        processSource = process

        // Anything typed before the shell existed — a resume command, say.
        flushWrites()
    }

    // MARK: - Output

    private func readOutput() {
        guard master >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(master, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer[0..<count])
                ring.append(data)
                liveModes.feed(data)
                for event in agentProgramStatus.feed(data) {
                    switch event {
                    case .query:
                        write(Data("\u{1b}]7501;?\u{1b}\\".utf8))
                    case .claude(let state):
                        let id = id.uuidString
                        DispatchQueue.main.async {
                            AgentActivityStore.shared.receiveNativeState(state, forAgent: id)
                        }
                    case .shellPrompt:
                        break // Process polling confirms the foreground really is the shell.
                    }
                }
                broadcast(data)
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            // EOF or EIO: every holder of the slave side is gone. The process
            // source reports the exit; stop reading so this doesn't spin.
            readSource?.cancel()
            readSource = nil
            return
        }
    }

    private func broadcast(_ data: Data) {
        for entry in entries.values {
            if entry.divergedAt != nil { continue }
            if entry.client.bufferedBytes > Self.backpressureLimit {
                let client = entry.client
                detach(client)
                client.sessionDidDropForBackpressure(self)
                continue
            }
            entry.client.session(self, didOutput: data)
        }
    }

    private func childExited() {
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        let code: Int32
        if reaped == pid {
            if (status & 0x7F) == 0 {
                code = (status >> 8) & 0xFF
            } else {
                code = 128 + (status & 0x7F)
            }
        } else {
            code = 0
        }
        // Whatever the shell said on its way out is still in the pty.
        readOutput()
        finish(code: code)
    }

    private func finish(code: Int32) {
        if case .exited = phase { return }
        phase = .exited(code)
        closePTY()

        let clients = entries.values.map(\.client)
        entries.removeAll()
        for client in clients { client.session(self, didExit: code) }
        onFinish?(self)
    }

    /// Stop watching the pty and close it.
    private func closePTY() {
        if pid > 0 { LiveSessions.remove(pid: pid) }
        processSource?.cancel()
        processSource = nil
        readSource?.cancel()
        readSource = nil
        if let writeSource {
            // libdispatch traps on releasing a suspended source, so it has to
            // be running before it is cancelled.
            if !writeSourceActive { writeSource.resume() }
            writeSource.cancel()
        }
        writeSource = nil
        writeSourceActive = false
        pendingWrites.removeAll()
        pendingWriteOffset = 0
        if master >= 0 {
            close(master)
            master = -1
        }
    }

    /// End the session: the pane was closed. Mirrors what Ghostty does to a
    /// surface's child — SIGHUP to the process group, then the pty goes.
    func terminate() {
        if phase == .running {
            tabterm_hangup(pid, master)
            // Keep at it off the queue until the shell is really gone — see
            // tabterm_hangup_and_reap for why once isn't always enough.
            let child = pid
            DispatchQueue.global(qos: .utility).async {
                _ = tabterm_hangup_and_reap(child, -1, 5000)
            }
        }
        finish(code: 0)
    }

    // MARK: - Input

    /// Write keyboard bytes to the shell. Queued until the shell exists, and
    /// whenever the pty's input buffer is full.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        if case .exited = phase { return }
        pendingWrites.append(data)
        flushWrites()
    }

    private func flushWrites() {
        guard master >= 0 else { return }
        while let first = pendingWrites.first {
            let remaining = first.count - pendingWriteOffset
            let written = first.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(master, base + pendingWriteOffset, remaining)
            }
            if written > 0 {
                if written == remaining {
                    pendingWrites.removeFirst()
                    pendingWriteOffset = 0
                } else {
                    pendingWriteOffset += written
                }
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                setWriteSource(active: true)
                return
            }
            // The pty is gone; the exit handler will tidy up.
            pendingWrites.removeAll()
            pendingWriteOffset = 0
            break
        }
        setWriteSource(active: false)
    }

    private func setWriteSource(active: Bool) {
        guard let writeSource, active != writeSourceActive else { return }
        writeSourceActive = active
        if active { writeSource.resume() } else { writeSource.suspend() }
    }

    /// Type a message the way a person would: the text, then Enter on its own
    /// a moment later. Submissions queue, so a second one can't land between
    /// another's text and its Enter.
    func submit(_ text: String, pressEnter: Bool) {
        submissions.append((text, pressEnter))
        runSubmissions()
    }

    private func runSubmissions() {
        guard !submitting, !submissions.isEmpty else { return }
        submitting = true
        let (text, pressEnter) = submissions.removeFirst()

        // Terminals send a pasted newline as CR. Escape is dropped so the text
        // can't end a bracketed paste early and have the rest read as keys.
        var body = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        body.removeAll { $0 == "\u{1b}" }

        if !body.isEmpty {
            if liveModes.modes.bracketedPaste {
                write(Data("\u{1b}[200~\(body)\u{1b}[201~".utf8))
            } else {
                write(Data(body.utf8))
            }
        }

        let delay = body.isEmpty ? 0 : Self.submitEnterDelay
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if pressEnter { self.write(Data([0x0D])) }
            self.submitting = false
            self.runSubmissions()
        }
    }

    // MARK: - Clients

    /// Add a client, or re-attach one, and bring it up to date.
    ///
    /// `ghosttyEnvironment` is only passed by the pane's attach process; the
    /// first attach that brings one starts the shell.
    func attach(
        _ client: SessionClient,
        anchor: StreamAnchor,
        size: TerminalSize?,
        visible: Bool,
        ghosttyEnvironment: [String: String]? = nil
    ) {
        if case .exited(let code) = phase {
            client.session(self, didExit: code)
            return
        }

        let isPane = ghosttyEnvironment != nil
        let entry = Entry(
            client: client,
            size: size?.clamped,
            visible: isPane ? paneVisible : visible,
            isPane: isPane
        )
        entries[ObjectIdentifier(client)] = entry

        if phase == .pending {
            if let ghosttyEnvironment {
                spawn(size: size ?? self.size, ghosttyEnvironment: ghosttyEnvironment)
            } else {
                // Only the pane can start its shell; a phone that gets here
                // first waits for it.
            }
        }

        let before = self.size
        let reset = !catchUp(entry, anchor: anchor)
        applyEffectiveSize()
        if reset, self.size == before, phase == .running {
            nudgeRepaint()
        }
    }

    func detach(_ client: SessionClient) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(client)) else { return }
        if entry.visible, entry.size != nil { applyEffectiveSize() }
    }

    func resize(_ client: SessionClient, to size: TerminalSize) {
        guard let entry = entries[ObjectIdentifier(client)] else { return }
        entry.size = size.clamped
        applyEffectiveSize(force: true)
    }

    /// The Mac pane's tab was shown or hidden.
    func setPaneVisible(_ visible: Bool) {
        guard paneVisible != visible else { return }
        paneVisible = visible
        for entry in entries.values where entry.isPane {
            entry.visible = visible
        }
        applyEffectiveSize()
    }

    func setVisible(_ client: SessionClient, _ visible: Bool) {
        guard let entry = entries[ObjectIdentifier(client)], entry.visible != visible else { return }
        entry.visible = visible

        guard visible else {
            applyEffectiveSize()
            return
        }

        let before = size
        var needsRepaint = false
        if entry.divergedAt != nil {
            entry.divergedAt = nil
            sendReset(to: entry)
            needsRepaint = true
        }
        applyEffectiveSize()
        if needsRepaint, size == before { nudgeRepaint() }
    }

    /// Serve an attach. Returns true when the client was caught up exactly.
    private func catchUp(_ entry: Entry, anchor: StreamAnchor) -> Bool {
        if case .position(let clientEpoch, let seq) = anchor,
           clientEpoch == epoch,
           seq >= ring.startSeq, seq <= ring.endSeq,
           lastResizeSeq.map({ seq > $0 }) ?? true,
           let missed = ring.bytes(from: seq) {
            entry.client.session(self, didSync: Synced(
                session: id, epoch: epoch, seq: seq, mode: .exact, size: size
            ))
            if !missed.isEmpty { entry.client.session(self, didOutput: missed) }
            return true
        }
        sendReset(to: entry)
        return false
    }

    /// Tell a client to start over: reset, the modes in force where the replay
    /// begins, then the recent output laid out at the current size.
    private func sendReset(to entry: Entry) {
        let start = ring.replayStart(atOrAfter: lastResizeSeq ?? 0)
        let modes = ring.modes(at: start)?.modes ?? liveModes.modes
        entry.client.session(self, didSync: Synced(
            session: id, epoch: epoch, seq: start, mode: .reset, size: size
        ))
        let preamble = modes.preamble
        if !preamble.isEmpty { entry.client.session(self, didSynthesize: preamble) }
        if let tail = ring.bytes(from: start), !tail.isEmpty {
            entry.client.session(self, didOutput: tail)
        }
    }

    // MARK: - Size

    /// The smallest size across the clients that are showing this terminal,
    /// as tmux does. Last-writer-wins would leave every other client showing
    /// output laid out for a width it doesn't have — and a desktop's 200
    /// columns squeezed into a phone's 45 is unreadable. Hidden clients don't
    /// count, so a phone in the background never holds the Mac narrow.
    private var effectiveSize: TerminalSize? {
        var best: TerminalSize?
        for entry in entries.values where entry.visible {
            guard let size = entry.size else { continue }
            if var current = best {
                current.cols = min(current.cols, size.cols)
                current.rows = min(current.rows, size.rows)
                if size.cols <= current.cols, size.pixelWidth > 0 {
                    current.pixelWidth = size.pixelWidth
                }
                if size.rows <= current.rows, size.pixelHeight > 0 {
                    current.pixelHeight = size.pixelHeight
                }
                best = current
            } else {
                best = size
            }
        }
        return best
    }

    private func applyEffectiveSize(force: Bool = false) {
        guard let next = effectiveSize else { return }
        let changed = next.cols != size.cols || next.rows != size.rows
        guard changed || force else { return }

        if changed {
            lastResizeSeq = ring.endSeq
            // Hidden clients still in step stop being so here.
            for entry in entries.values where !entry.visible && !entry.isPane && entry.divergedAt == nil {
                entry.divergedAt = ring.endSeq
            }
        }
        size = next
        resizeGeneration += 1
        guard master >= 0 else { return }
        _ = tabterm_set_size(
            master,
            UInt16(clamping: next.cols), UInt16(clamping: next.rows),
            UInt16(clamping: next.pixelWidth), UInt16(clamping: next.pixelHeight)
        )
    }

    /// Make the running program redraw by shrinking the pty a row and putting
    /// it back: two real SIGWINCHes, since a same-size resize sends none.
    /// Used when a client's screen was reset and the size didn't move, so the
    /// program — the only party that knows the whole screen — repaints it.
    private func nudgeRepaint() {
        guard master >= 0 else { return }
        let current = size
        let generation = resizeGeneration
        let rows = current.rows > TerminalSize.minimum.rows ? current.rows - 1 : current.rows + 1
        _ = tabterm_set_size(
            master, UInt16(clamping: current.cols), UInt16(clamping: rows),
            UInt16(clamping: current.pixelWidth), UInt16(clamping: current.pixelHeight)
        )
        queue.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            // A real resize landed in between and owns the size now.
            guard let self, self.master >= 0, self.resizeGeneration == generation else { return }
            _ = tabterm_set_size(
                self.master, UInt16(clamping: current.cols), UInt16(clamping: current.rows),
                UInt16(clamping: current.pixelWidth), UInt16(clamping: current.pixelHeight)
            )
        }
    }

    // MARK: - What's running

    /// The pty's foreground process group: the command the user is looking
    /// at, not the shell that started it.
    ///
    /// Until the shell sets up job control, the foreground group is still
    /// login(1)'s. That is a root process whose command line can't be read,
    /// and not what anyone would call "running in the terminal", so the shell
    /// — login's child — stands in for it.
    var foregroundProcessGroup: pid_t {
        guard master >= 0 else { return 0 }
        let group = tcgetpgrp(master)
        guard group > 0 else { return 0 }
        if group == pid { return tabterm_first_child(pid) }
        return group
    }

    /// True when something other than the shell is in the foreground.
    ///
    /// The process tree is login → shell → job. At a prompt the foreground is
    /// the shell, whose parent is login; while a command runs it is the
    /// command, whose parent is the shell.
    var isRunningSomething: Bool {
        guard master >= 0, pid > 0 else { return false }
        let group = tcgetpgrp(master)
        guard group > 0, group != pid else { return false }
        return tabterm_parent_pid(group) != pid
    }

    /// Clients currently looking at this terminal.
    func isVisible(to client: SessionClient) -> Bool {
        entries[ObjectIdentifier(client)]?.visible ?? false
    }
}

/// Run `body` with a NULL-terminated C array of the strings.
private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// The sessions still running, for hanging them all up as the app exits.
///
/// Kept apart from the sessions themselves, behind a lock, because it is read
/// from an `atexit` handler, which runs on whatever thread called `exit` —
/// the self-test calls it directly, and a normal quit gets there too.
enum LiveSessions {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var processes: [pid_t: Int32] = [:]
    nonisolated(unsafe) private static var registered = false

    static func add(pid: pid_t, master: Int32) {
        lock.withLock {
            processes[pid] = master
            if !registered {
                registered = true
                atexit { LiveSessions.hangUpAll() }
            }
        }
    }

    static func remove(pid: pid_t) {
        lock.withLock { _ = processes.removeValue(forKey: pid) }
    }

    /// A session outlives the app only if something tells its shell; closing
    /// the ptys as the process exits isn't enough (see `tabterm_hangup`).
    static func hangUpAll() {
        let all = lock.withLock { processes }
        guard !all.isEmpty else { return }
        for (pid, master) in all { tabterm_hangup(pid, master) }
        // The app is on its way out, so this can block, briefly: long enough
        // for shells caught mid-startup to take the signal.
        DispatchQueue.concurrentPerform(iterations: all.count) { index in
            let (pid, master) = all[all.index(all.startIndex, offsetBy: index)]
            _ = tabterm_hangup_and_reap(pid, master, 400)
        }
    }
}
