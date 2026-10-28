import AppKit
import TabTermKit

/// The window's side of the phone server: what phones are shown, and the
/// things they ask the window to do.
///
/// Main queue only. The sidebar isn't observable in one place — titles,
/// panes, agent dots and the selection all change through different paths —
/// so while a phone is connected this rebuilds the snapshot twice a second and
/// sends it only when it differs. It is a few dozen small values; comparing
/// them costs nothing, and a snapshot can't miss a change the way a missed
/// notification can.
final class RemoteHost {
    static let shared = RemoteHost()

    private var timer: Timer?
    private var lastSent: HostState?

    /// How long this Mac has to sit untouched before it follows the phone.
    static let followAfterIdle: TimeInterval = 60

    var controller: MainWindowController? { MainWindowController.current }

    func snapshot() -> HostState {
        let state = controller?.remoteState()
            ?? HostState(hostName: Host.current().localizedName ?? "Mac", workspaces: [], focus: nil)
        lastSent = state
        return state
    }

    /// Start or stop watching for changes as phones come and go.
    func clientsChanged(connected: Bool) {
        if connected {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            lastSent = nil
        }
    }

    /// Send the snapshot now if it changed — after anything a phone asked for,
    /// so it sees the result without waiting for the next tick.
    func poll() {
        guard let controller else { return }
        let state = controller.remoteState()
        guard state != lastSent else { return }
        lastSent = state
        RemoteServer.shared.broadcast(state)
    }

    // MARK: - Requests

    func openWorkspace(_ id: String) {
        guard let key = WorkspaceKey(stateValue: id) else { return }
        controller?.openWorkspaceInBackground(key)
        poll()
    }

    func newTab(in workspaceID: String) -> UUID? {
        guard let key = WorkspaceKey(stateValue: workspaceID) else { return nil }
        let session = controller?.addTab(inWorkspace: key)
        poll()
        return session
    }

    /// Make a worktree in the repository `workspaceID` belongs to, on
    /// `branch`. Calls back with the new workspace's id, or why not.
    func newWorktree(
        beside workspaceID: String,
        branch: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let controller, let key = WorkspaceKey(stateValue: workspaceID) else {
            return completion(.failure(GitError.commandFailed("There is no such workspace.")))
        }
        controller.addWorktree(besideWorkspace: key, branch: branch) { [weak self] result in
            // The sidebar first, so the new workspace is in it by the time
            // the client hears its name.
            self?.poll()
            completion(result.map(\.stateValue))
        }
    }

    /// A phone switched terminals.
    ///
    /// If nobody has touched this Mac for a minute, it switches to the same
    /// terminal, so whatever you were doing on the phone is on screen when
    /// you sit back down. Someone actually using the Mac is never interrupted.
    func phoneIsViewing(_ session: UUID?) {
        guard let session, UserActivity.idleSeconds >= Self.followAfterIdle else { return }
        controller?.reveal(session: session)
        poll()
    }
}

/// Whether someone is at this Mac.
enum UserActivity {
    /// Seconds since the last keyboard or mouse event, from anyone.
    static var idleSeconds: TimeInterval {
        // ~0 is kCGAnyInputEventType, which Swift doesn't expose by name.
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Nobody is looking at the screen, so a notification belongs on the phone.
    static var isAway: Bool {
        isScreenLocked || idleSeconds >= 120
    }
}
