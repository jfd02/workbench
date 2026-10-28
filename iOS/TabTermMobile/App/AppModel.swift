import Foundation
import Observation
import SwiftUI
import TabTermKit
import UIKit
import UserNotifications

/// Where the navigation stack can go.
enum Route: Hashable {
    case terminal(UUID)
}

/// What the connection indicator shows.
enum ConnectionState: Equatable {
    case offline
    case connecting
    case connected
    case denied(String)
}

/// The app's state: which Mac, whether we're connected to it, what it's
/// showing, and which terminal is on screen here.
///
/// One of these for the app's lifetime. It owns the connection and the cache
/// of terminals, and routes what arrives from the Mac to the terminal it is
/// for. Views read it and call its methods; they never talk to the connection.
@MainActor
@Observable
final class AppModel {
    private(set) var pairedMac: PairedHost?
    private(set) var connectionState: ConnectionState = .offline
    private(set) var hostState: HostState = .empty

    var path: [Route] = []

    /// Pairing in progress, and why the last attempt failed.
    private(set) var isPairing = false
    var pairingError: String?

    /// Worktrees asked to open, until the Mac reports their terminals.
    private(set) var openingWorkspaces: Set<String> = []

    /// A transient message for the terminal screen.
    var notice: String?

    /// Unsent composer text, per terminal.
    var drafts: [UUID: String] = [:]

    /// Bumped when a terminal's own state changes (exit, reset), so views that
    /// show it re-read it.
    private(set) var terminalRevision = 0

    let isDemo: Bool

    @ObservationIgnored private let connection = MacConnection()
    @ObservationIgnored private var terminals: [UUID: RemoteTerminal] = [:]
    @ObservationIgnored private(set) var displayedSession: UUID?
    @ObservationIgnored private var sceneIsActive = true

    /// The Mac's focus when we last heard about it. Coming back to the app
    /// follows the Mac only if this moved — i.e. someone did something at the
    /// Mac — so locking the phone and unlocking it again never yanks you off
    /// the terminal you were reading.
    @ObservationIgnored private var lastSeenMacFocus: HostState.Focus?
    @ObservationIgnored private var followMacOnNextState: FollowReason?
    @ObservationIgnored private var pushToken: String?
    @ObservationIgnored private var pendingNewTabs: Set<String> = []

    private enum FollowReason {
        /// A cold launch: open whatever the Mac is showing.
        case launch
        /// Back from the background: open it only if the Mac moved.
        case returning
    }

    init(demo: Bool = false) {
        isDemo = demo
        if demo {
            loadDemo()
            return
        }

        connection.onStatusChange = { [weak self] status in self?.connectionStatusChanged(status) }
        connection.onWelcome = { [weak self] welcome in self?.welcomed(welcome) }
        connection.onMessage = { [weak self] message in self?.handle(message) }
        connection.onTerminalFrame = { [weak self] frame in self?.route(frame) }

        pairedMac = PairingStore.load()
        followMacOnNextState = .launch
        if let pairedMac { connect(to: pairedMac, pairingCode: nil) }
    }

    // MARK: - Pairing

    /// Pair with the Mac a link points at. The link's code is good once, for a
    /// few minutes; the Mac answers it with the token we keep instead.
    func pair(with link: PairingLink) {
        guard !isDemo else { return }
        pairingError = nil
        isPairing = true
        terminals.removeAll()
        hostState = .empty
        path = []

        let provisional = PairedHost(name: link.name, hosts: link.hosts, port: link.port, deviceID: "", deviceToken: "")
        pairedMac = nil
        connect(to: provisional, pairingCode: link.code)
        pendingPairing = provisional
    }

    @ObservationIgnored private var pendingPairing: PairedHost?

    /// Handle a link opened from outside: the Camera app scanning the QR code.
    func handle(url: URL) {
        guard let link = PairingLink(url: url) else { return }
        pair(with: link)
    }

    func forgetMac() {
        connection.stop()
        PairingStore.clear()
        pairedMac = nil
        pendingPairing = nil
        hostState = .empty
        terminals.removeAll()
        drafts.removeAll()
        path = []
        connectionState = .offline
    }

    private func connect(to mac: PairedHost, pairingCode: String?) {
        connection.start(MacConnection.Credentials(
            hosts: mac.hosts,
            port: mac.port,
            deviceName: UIDevice.current.name,
            deviceToken: mac.deviceToken.isEmpty ? nil : mac.deviceToken,
            pairingCode: pairingCode
        ))
    }

    // MARK: - Connection events

    private func connectionStatusChanged(_ status: MacConnection.Status) {
        switch status {
        case .idle:
            connectionState = .offline
        case .connecting:
            connectionState = .connecting
        case .connected:
            connectionState = .connected
        case .retrying:
            connectionState = pendingPairing == nil ? .connecting : .offline
            terminalsLostConnection()
            if pendingPairing != nil {
                // A pairing attempt that can't reach the Mac is a failure to
                // report, not something to retry quietly forever.
                connection.stop()
                isPairing = false
                pendingPairing = nil
                pairingError = "Couldn't reach the Mac. Check that Tailscale is connected on this iPhone and that Workbench is running."
            }
        case .denied(let denied):
            terminalsLostConnection()
            if pendingPairing != nil {
                isPairing = false
                pendingPairing = nil
                pairingError = denied.reason == .unauthorized
                    ? "That pairing code has expired or was already used. Show a new one on the Mac and scan it again."
                    : denied.message
                connectionState = .offline
            } else {
                connectionState = .denied(denied.message)
            }
        }
    }

    private func welcomed(_ welcome: Welcome) {
        if var pending = pendingPairing {
            pending.name = welcome.hostName.isEmpty ? pending.name : welcome.hostName
            pending.deviceID = welcome.deviceID
            pending.deviceToken = welcome.deviceToken ?? pending.deviceToken
            PairingStore.save(pending)
            pairedMac = pending
            pendingPairing = nil
            isPairing = false
            followMacOnNextState = .launch
            requestPushAuthorization()
        }

        sendPushRegistration()
        connection.send(.viewing(Viewing(session: displayedSession)))
        for terminal in terminals.values { terminal.reattachIfWanted() }
    }

    private func terminalsLostConnection() {
        for terminal in terminals.values { terminal.connectionLost() }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .state(let state):
            receive(state)
        case .synced(let synced):
            terminals[synced.session]?.handle(synced)
        case .exit(let exit):
            terminals[exit.session]?.handleExit(code: exit.code)
            terminalRevision += 1
            if exit.code == SessionExit.unknownSession, exit.session == displayedSession {
                followAfterLosingSession(exit.session)
            }
        case .tabCreated(let created):
            guard pendingNewTabs.remove(created.requestID) != nil else { return }
            open(session: created.session)
        case .error(let error):
            notice = error.message
        default:
            break
        }
    }

    private func route(_ frame: Frame) {
        guard let session = frame.session, let terminal = terminals[session] else { return }
        switch frame.kind {
        case .output: terminal.handleOutput(frame.payload)
        case .synthesized: terminal.handleSynthesized(frame.payload)
        default: break
        }
    }

    private func receive(_ state: HostState) {
        hostState = state

        // Worktrees that finished opening.
        for id in openingWorkspaces where state.workspace(id: id)?.isOpen == true {
            openingWorkspaces.remove(id)
        }

        if let reason = followMacOnNextState {
            followMacOnNextState = nil
            let macMoved = state.focus != lastSeenMacFocus
            if let session = state.focus?.session,
               reason == .launch || macMoved,
               session != displayedSession {
                open(session: session)
            }
        }
        lastSeenMacFocus = state.focus
    }

    /// The terminal on screen no longer exists on the Mac — Workbench was
    /// restarted, and every terminal came back as a new session. Rather than
    /// leave you looking at a dead screen, go where the Mac is now.
    private func followAfterLosingSession(_ lost: UUID) {
        terminals.removeValue(forKey: lost)
        if let focus = hostState.focus?.session, focus != lost {
            open(session: focus)
        } else {
            followMacOnNextState = .launch
        }
    }

    // MARK: - Terminals

    /// The terminal for a session, from the cache or new.
    func terminal(for session: UUID) -> RemoteTerminal {
        if let existing = terminals[session] { return existing }
        let terminal = RemoteTerminal(session: session)
        if !isDemo {
            terminal.sendFrame = { [weak self] frame in self?.connection.send(frame: frame) }
            terminal.isLinkUp = { [weak self] in self?.connection.isConnected ?? false }
        }
        terminal.onChange = { [weak self] in self?.terminalRevision += 1 }
        terminals[session] = terminal
        if isDemo { feedDemo(into: terminal) }
        return terminal
    }

    /// Put a terminal on screen: navigate to it.
    func open(session: UUID) {
        path = [.terminal(session)]
    }

    /// The terminal screen appeared. Only the terminal on screen is attached:
    /// an attached, visible terminal holds the Mac's pty at the phone's size.
    func display(_ session: UUID) {
        displayedSession = session
        for (id, terminal) in terminals where id != session {
            terminal.detach()
        }
        // Sent now if connected, otherwise as soon as the welcome arrives.
        terminal(for: session).attach(visible: sceneIsActive)
        connection.send(.viewing(Viewing(session: session)))
    }

    func stopDisplaying(_ session: UUID) {
        guard displayedSession == session else { return }
        displayedSession = nil
        terminals[session]?.detach()
        connection.send(.viewing(Viewing(session: nil)))
    }

    // MARK: - Actions

    func openWorkspace(_ id: String) {
        guard hostState.workspace(id: id)?.isOpen == false else { return }
        openingWorkspaces.insert(id)
        connection.send(.openWorkspace(WorkspaceRef(workspace: id)))
    }

    func newTab(in workspace: String) {
        let request = UUID().uuidString
        pendingNewTabs.insert(request)
        connection.send(.newTab(NewTab(workspace: workspace, requestID: request)))
    }

    /// Type a message into a terminal and press Enter, the way the Mac's
    /// `submit` does it: text first, Enter on its own a moment later.
    func submit(_ text: String, to session: UUID) {
        if isDemo {
            terminals[session]?.feedLocal("\r\n\u{1b}[38;5;245m> \u{1b}[0m\(text)\r\n")
            return
        }
        connection.send(.submit(Submit(session: session, text: text)))
    }

    func send(_ key: TerminalKey, to session: UUID) {
        terminals[session]?.send(key: key)
    }

    // MARK: - Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            let wasInBackground = !sceneIsActive
            sceneIsActive = true
            guard !isDemo, pairedMac != nil else { return }
            if wasInBackground, followMacOnNextState == nil {
                followMacOnNextState = .returning
            }
            connection.appDidBecomeActive()
            if let displayedSession { terminals[displayedSession]?.setVisible(true) }
        case .background:
            guard sceneIsActive else { return }
            sceneIsActive = false
            guard !isDemo else { return }
            // Stop holding the Mac's pty at phone size. Given a moment of
            // background time so the message leaves before iOS suspends us.
            let task = UIApplication.shared.beginBackgroundTask(withName: "visibility")
            if let displayedSession { terminals[displayedSession]?.setVisible(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                UIApplication.shared.endBackgroundTask(task)
            }
        case .inactive:
            // Control Center, a notification banner: brief, and not worth
            // resizing the Mac's terminal twice over.
            break
        @unknown default:
            break
        }
    }

    // MARK: - Push

    func requestPushAuthorization() {
        guard !isDemo else { return }
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func didRegisterForPush(token: Data) {
        pushToken = token.map { String(format: "%02x", $0) }.joined()
        sendPushRegistration()
    }

    private func sendPushRegistration() {
        guard let pushToken else { return }
        connection.send(.registerPush(RegisterPush(
            token: pushToken,
            environment: PushEnvironment.current,
            bundleID: Bundle.main.bundleIdentifier ?? "com.tabterm.TabTermMobile"
        )))
    }

    /// A notification was tapped. Its terminal wins over following the Mac.
    func handleNotification(session raw: String?) {
        guard let raw, let session = UUID(uuidString: raw) else { return }
        followMacOnNextState = nil
        open(session: session)
    }

    /// Whether a notification for this session is worth showing while the app
    /// is open: not if it's the terminal already on screen.
    func shouldPresentNotification(session raw: String?) -> Bool {
        guard let raw, let session = UUID(uuidString: raw) else { return true }
        return session != displayedSession
    }

    // MARK: - Demo

    private func loadDemo() {
        #if DEBUG
        pairedMac = DemoData.mac
        connectionState = .connected
        hostState = DemoData.state
        if ProcessInfo.processInfo.arguments.contains("-demoUnpaired") {
            pairedMac = nil
            connectionState = .offline
        } else if ProcessInfo.processInfo.arguments.contains("-demoTerminal") {
            path = [.terminal(DemoData.claudeSession)]
        }
        #endif
    }

    private func feedDemo(into terminal: RemoteTerminal) {
        #if DEBUG
        terminal.feedLocal(DemoData.output(for: terminal.session))
        #endif
    }
}
