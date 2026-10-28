import SwiftTerm
import TabTermKit
import UIKit

/// The phone's view of one terminal on the Mac.
///
/// Owns a SwiftTerm `TerminalView` and keeps it in step with the Mac's session:
/// attaching with the last stream position so a return is caught up exactly,
/// feeding what arrives, and sending back what is typed. Kept alive in a cache
/// after it leaves the screen, so going back to a terminal shows the last
/// screen straight away while the missed bytes arrive behind it.
@MainActor
final class RemoteTerminal: NSObject {
    let session: UUID
    let terminalView: PhoneTerminalView

    /// Sends a frame to the Mac. Set by `AppModel`; nil in demo mode.
    var sendFrame: ((Frame) -> Void)?

    /// Whether frames sent now would reach the Mac. An attach sent into a
    /// dead link is lost, and believing it went out would stop the reconnect
    /// from sending it again.
    var isLinkUp: () -> Bool = { false }

    /// Something the screen shows about this terminal changed.
    var onChange: (() -> Void)?

    private(set) var position = StreamPosition()
    private(set) var isAttached = false
    /// Set when the shell on the Mac exited.
    private(set) var exitCode: Int32?

    /// Attach once the view has a real size to report: attaching at SwiftTerm's
    /// 80×25 default would resize the Mac's pty for nothing.
    private var wantsAttach = false
    private var wantsVisible = true
    private var reportedSize: TerminalSize?
    private var resizeWork: DispatchWorkItem?
    /// Collects the wheel events SwiftTerm encodes while scrolling a program.
    private var wheelEvents: [UInt8]?

    init(session: UUID) {
        self.session = session
        var options = TerminalOptions.default
        options.scrollback = 5000
        options.termName = "xterm-256color"
        terminalView = PhoneTerminalView(options: options)
        super.init()

        terminalView.terminalDelegate = self
        // Touches are for scrolling and selecting, never for clicking into a
        // program on the Mac.
        terminalView.allowMouseReporting = false
        terminalView.onScroll = { [weak self] rows, col, row in
            self?.scrollProgram(rows: rows, col: col, row: row)
        }
        // The quick-keys row below the terminal does this job, for the
        // composer and for direct typing alike.
        terminalView.inputAccessoryView = nil
        TerminalTheme.apply(to: terminalView)
    }

    // MARK: - Size

    private var hasUsableSize: Bool {
        terminalView.bounds.width > 40 && terminalView.bounds.height > 40
    }

    var size: TerminalSize {
        let terminal = terminalView.getTerminal()
        let scale = terminalView.window?.screen.scale ?? UIScreen.main.scale
        return TerminalSize(
            cols: terminal.cols,
            rows: terminal.rows,
            pixelWidth: Int(terminalView.bounds.width * scale),
            pixelHeight: Int(terminalView.bounds.height * scale)
        )
    }

    /// Whether arrows should go out in application-cursor form.
    var applicationCursor: Bool { terminalView.getTerminal().applicationCursor }

    // MARK: - Attaching

    /// Start receiving this session. Waits for a real size if there isn't one.
    func attach(visible: Bool) {
        wantsAttach = true
        wantsVisible = visible
        guard hasUsableSize, sendFrame != nil, isLinkUp() else { return }

        let size = self.size
        isAttached = true
        position.suspend()
        reportedSize = size
        send(.attach(Attach(session: session, anchor: position.anchor, size: size, visible: visible)))
    }

    func detach() {
        wantsAttach = false
        resizeWork?.cancel()
        guard isAttached else { return }
        send(.detach(SessionRef(session: session)))
        isAttached = false
        position.suspend()
    }

    /// The connection dropped. The next attach resumes from where we were.
    func connectionLost() {
        isAttached = false
        position.suspend()
    }

    /// Re-attach after a reconnect, if this terminal was attached before.
    func reattachIfWanted() {
        guard wantsAttach, !isAttached else { return }
        attach(visible: wantsVisible)
    }

    func setVisible(_ visible: Bool) {
        wantsVisible = visible
        guard isAttached else { return }
        send(.visibility(Visibility(session: session, visible: visible)))
    }

    // MARK: - From the Mac

    func handle(_ synced: Synced) {
        if synced.mode == .reset {
            // The Mac couldn't catch this screen up, so start clean: what
            // follows is the modes and the recent output from scratch.
            terminalView.feed(byteArray: [0x1B, 0x63][...])
        }
        position.apply(synced)
        exitCode = nil
        onChange?()
    }

    func handleOutput(_ bytes: Data) {
        guard position.receiveOutput(count: bytes.count) else { return }
        feed(bytes)
    }

    func handleSynthesized(_ bytes: Data) {
        feed(bytes)
    }

    func handleExit(code: Int32) {
        exitCode = code
        isAttached = false
        onChange?()
    }

    /// Show bytes that didn't come from the Mac — demo output.
    func feedLocal(_ text: String) {
        feed(Data(text.utf8))
    }

    private func feed(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        let array = [UInt8](bytes)
        terminalView.feed(byteArray: array[...])
    }

    // MARK: - Typing

    /// Send a key the phone keyboard doesn't have.
    func send(key: TerminalKey) {
        sendInput(key.bytes(applicationCursor: applicationCursor))
    }

    func sendInput(_ bytes: [UInt8]) {
        guard isAttached, !bytes.isEmpty else { return }
        sendFrame?(.input(session, Data(bytes)))
    }

    private func send(_ message: ClientMessage) {
        sendFrame?(.control(message))
    }

    // MARK: - Scrolling

    /// Scroll a program that keeps its own scrollback, the way the Mac's
    /// Ghostty does on the alternate screen: wheel events to a program that
    /// listens to the mouse, like Claude Code's fullscreen mode, and arrow keys
    /// to one that doesn't. Positive `rows` is back towards older output.
    private func scrollProgram(rows: Int, col: Int, row: Int) {
        let terminal = terminalView.getTerminal()
        let count = abs(rows)
        guard terminal.mouseMode != .off else {
            let key: TerminalKey = rows > 0 ? .up : .down
            sendInput(Array(repeating: key.bytes(applicationCursor: applicationCursor), count: count).flatMap { $0 })
            return
        }
        // SwiftTerm encodes the event in whichever form the program asked for
        // and hands it to `send(source:data:)`, which would drop it as a reply
        // like any other mouse report; collect it there instead.
        let flags = terminal.encodeButton(button: rows > 0 ? 4 : 5, release: false, shift: false, meta: false, control: false)
        wheelEvents = []
        for _ in 0..<count {
            terminal.sendEvent(buttonFlags: flags, x: col, y: row)
        }
        let bytes = wheelEvents ?? []
        wheelEvents = nil
        sendInput(bytes)
    }

    // MARK: - Resizing

    private func sizeDidChange() {
        if wantsAttach, !isAttached, hasUsableSize {
            attach(visible: wantsVisible)
            return
        }
        guard isAttached else { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isAttached else { return }
                let size = self.size
                // Pixel sizes wobble with rotation animations; only cells matter.
                guard size.cols != self.reportedSize?.cols || size.rows != self.reportedSize?.rows else { return }
                self.reportedSize = size
                self.send(.resize(Resize(session: self.session, size: size)))
            }
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}

extension RemoteTerminal: TerminalViewDelegate {
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { sizeDidChange() }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// What SwiftTerm wants to send: keystrokes when typing into the terminal
    /// directly, but also its automatic answers to the program's queries. The
    /// Mac's Ghostty answers those already, so they are filtered out here.
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        MainActor.assumeIsolated {
            if wheelEvents != nil {
                wheelEvents?.append(contentsOf: bytes)
            } else {
                sendInput(ResponseFilter.keystrokes(from: bytes))
            }
        }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        MainActor.assumeIsolated { UIApplication.shared.open(url) }
    }

    nonisolated func bell(source: TerminalView) {
        MainActor.assumeIsolated { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        let text = String(decoding: content, as: UTF8.self)
        MainActor.assumeIsolated { UIPasteboard.general.string = text }
    }

    nonisolated func clipboardRead(source: TerminalView) -> Data? { nil }

    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
