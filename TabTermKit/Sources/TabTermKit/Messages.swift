import Foundation

// MARK: - Shared shapes

/// A terminal's size in cells, plus pixels when the client knows them.
public struct TerminalSize: Codable, Equatable, Hashable, Sendable {
    public var cols: Int
    public var rows: Int
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(cols: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.cols = cols
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Anything smaller is a client mid-layout, not a real terminal.
    public static let minimum = TerminalSize(cols: 20, rows: 5)

    public var clamped: TerminalSize {
        TerminalSize(
            cols: max(cols, Self.minimum.cols),
            rows: max(rows, Self.minimum.rows),
            pixelWidth: max(pixelWidth, 0),
            pixelHeight: max(pixelHeight, 0)
        )
    }
}

/// What the agent in a terminal is doing, as the Mac's sidebar dot shows it.
public enum AgentStatus: String, Codable, Comparable, Sendable {
    case idle, working, finished, blocked

    private var rank: Int {
        switch self {
        case .idle: return 0
        case .working: return 1
        case .finished: return 2
        case .blocked: return 3
        }
    }

    public static func < (a: AgentStatus, b: AgentStatus) -> Bool { a.rank < b.rank }

    /// Red rather than amber: the agent is waiting on the user.
    public var wantsAttention: Bool { self == .finished || self == .blocked }
}

// MARK: - Host state

/// Everything the phone shows outside a terminal: the Mac's sidebar, its tabs
/// and panes, and what is on the Mac's screen right now. Sent whole whenever
/// any of it changes — it is small, and a whole snapshot can't drift.
public struct HostState: Codable, Equatable, Sendable {
    public var hostName: String
    public var workspaces: [WorkspaceInfo]
    /// What the Mac is showing: the workspace, and its focused terminal.
    public var focus: Focus?

    public init(hostName: String, workspaces: [WorkspaceInfo], focus: Focus?) {
        self.hostName = hostName
        self.workspaces = workspaces
        self.focus = focus
    }

    public struct Focus: Codable, Equatable, Sendable {
        public var workspace: String
        public var session: UUID?

        public init(workspace: String, session: UUID?) {
            self.workspace = workspace
            self.session = session
        }
    }

    public func workspace(id: String) -> WorkspaceInfo? {
        workspaces.first { $0.id == id }
    }

    /// The pane a session is running in, and where that pane lives.
    public func locate(_ session: UUID) -> (workspace: WorkspaceInfo, tab: TabInfo, pane: PaneInfo)? {
        for workspace in workspaces {
            for tab in workspace.tabs {
                if let pane = tab.panes.first(where: { $0.session == session }) {
                    return (workspace, tab, pane)
                }
            }
        }
        return nil
    }

    public static let empty = HostState(hostName: "", workspaces: [], focus: nil)
}

/// One row of the Mac's sidebar: Home, or a worktree.
public struct WorkspaceInfo: Codable, Equatable, Identifiable, Sendable {
    /// `home`, or `worktree:<id>` — the same string the Mac remembers it by.
    public var id: String
    public var name: String
    /// The repository a worktree belongs to; nil for Home.
    public var repository: String?
    public var branch: String?
    public var directory: String?
    /// False for a worktree nobody has opened since launch: it has no
    /// terminals yet, and opening it from the phone starts them.
    public var isOpen: Bool
    public var status: AgentStatus
    public var tabs: [TabInfo]

    public init(
        id: String,
        name: String,
        repository: String?,
        branch: String?,
        directory: String?,
        isOpen: Bool,
        status: AgentStatus,
        tabs: [TabInfo]
    ) {
        self.id = id
        self.name = name
        self.repository = repository
        self.branch = branch
        self.directory = directory
        self.isOpen = isOpen
        self.status = status
        self.tabs = tabs
    }
}

public struct TabInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var isSelected: Bool
    public var panes: [PaneInfo]

    public init(id: UUID, title: String, isSelected: Bool, panes: [PaneInfo]) {
        self.id = id
        self.title = title
        self.isSelected = isSelected
        self.panes = panes
    }
}

public struct PaneInfo: Codable, Equatable, Identifiable, Sendable {
    public var session: UUID
    public var title: String
    public var directory: String?
    public var isClaude: Bool
    public var status: AgentStatus
    public var isFocused: Bool

    public var id: UUID { session }

    public init(
        session: UUID,
        title: String,
        directory: String?,
        isClaude: Bool,
        status: AgentStatus,
        isFocused: Bool
    ) {
        self.session = session
        self.title = title
        self.directory = directory
        self.isClaude = isClaude
        self.status = status
        self.isFocused = isFocused
    }
}

// MARK: - Client → host

public struct Hello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var deviceName: String
    /// The long-lived credential from an earlier pairing.
    public var deviceToken: String?
    /// The one-time code from a pairing link, when this is the first visit.
    public var pairingCode: String?

    public init(protocolVersion: Int = TabTermProtocol.version, deviceName: String, deviceToken: String?, pairingCode: String?) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.deviceToken = deviceToken
        self.pairingCode = pairingCode
    }
}

/// What a Ghostty pane's attach process says first. The environment is the
/// one Ghostty gave it, which is what the session's shell should get too.
public struct AttachHello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var session: UUID
    public var size: TerminalSize
    public var environment: [String: String]

    public init(protocolVersion: Int = TabTermProtocol.version, session: UUID, size: TerminalSize, environment: [String: String]) {
        self.protocolVersion = protocolVersion
        self.session = session
        self.size = size
        self.environment = environment
    }
}

/// Where a client already is in a session's output stream.
public enum StreamAnchor: Codable, Equatable, Sendable {
    /// Nothing on screen yet.
    case fresh
    /// Every byte up to `seq` of the stream identified by `epoch` is on screen.
    case position(epoch: String, seq: UInt64)

    private enum CodingKeys: String, CodingKey { case epoch, seq }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let epoch = try container.decodeIfPresent(String.self, forKey: .epoch),
           let seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) {
            self = .position(epoch: epoch, seq: seq)
        } else {
            self = .fresh
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if case .position(let epoch, let seq) = self {
            try container.encode(epoch, forKey: .epoch)
            try container.encode(seq, forKey: .seq)
        }
    }
}

public struct Attach: Codable, Equatable, Sendable {
    public var session: UUID
    public var anchor: StreamAnchor
    public var size: TerminalSize
    public var visible: Bool

    public init(session: UUID, anchor: StreamAnchor, size: TerminalSize, visible: Bool = true) {
        self.session = session
        self.anchor = anchor
        self.size = size
        self.visible = visible
    }
}

public struct SessionRef: Codable, Equatable, Sendable {
    public var session: UUID
    public init(session: UUID) { self.session = session }
}

public struct Resize: Codable, Equatable, Sendable {
    public var session: UUID
    public var size: TerminalSize
    public init(session: UUID, size: TerminalSize) {
        self.session = session
        self.size = size
    }
}

public struct Visibility: Codable, Equatable, Sendable {
    public var session: UUID
    public var visible: Bool
    public init(session: UUID, visible: Bool) {
        self.session = session
        self.visible = visible
    }
}

/// Text to enter at a terminal, the way a person would: typed, then Enter.
public struct Submit: Codable, Equatable, Sendable {
    public var session: UUID
    public var text: String
    /// False to leave the text on the line without pressing Enter.
    public var pressEnter: Bool

    public init(session: UUID, text: String, pressEnter: Bool = true) {
        self.session = session
        self.text = text
        self.pressEnter = pressEnter
    }
}

public struct WorkspaceRef: Codable, Equatable, Sendable {
    public var workspace: String
    public init(workspace: String) { self.workspace = workspace }
}

public struct NewTab: Codable, Equatable, Sendable {
    public var workspace: String
    /// Echoed back with the new session, so the phone knows which request it
    /// answers.
    public var requestID: String
    public init(workspace: String, requestID: String) {
        self.workspace = workspace
        self.requestID = requestID
    }
}

/// A worktree to make, the way the Mac's New Worktree sheet makes one.
public struct NewWorktree: Codable, Equatable, Sendable {
    /// Any workspace of the repository the worktree is for. Repositories
    /// aren't named on the wire; their worktrees are.
    public var workspace: String
    /// The branch it will be on: one that exists, here or on a remote, or
    /// the name of a new one to start from the remote's default branch.
    public var branch: String
    /// Echoed back with the new workspace.
    public var requestID: String

    public init(workspace: String, branch: String, requestID: String) {
        self.workspace = workspace
        self.branch = branch
        self.requestID = requestID
    }
}

/// Which terminal the phone has on screen, or nil when none.
public struct Viewing: Codable, Equatable, Sendable {
    public var session: UUID?
    public init(session: UUID?) { self.session = session }
}

public struct RegisterPush: Codable, Equatable, Sendable {
    /// The APNs device token, hex encoded.
    public var token: String
    /// `sandbox` for a development build, `production` for TestFlight.
    public var environment: String
    public var bundleID: String

    public init(token: String, environment: String, bundleID: String) {
        self.token = token
        self.environment = environment
        self.bundleID = bundleID
    }
}

public struct Ping: Codable, Equatable, Sendable {
    public var id: Int
    public init(id: Int) { self.id = id }
}

public enum ClientMessage: Codable, Equatable, Sendable {
    case hello(Hello)
    case attachHello(AttachHello)
    case attach(Attach)
    case detach(SessionRef)
    case resize(Resize)
    case visibility(Visibility)
    case submit(Submit)
    case openWorkspace(WorkspaceRef)
    case newTab(NewTab)
    case newWorktree(NewWorktree)
    case viewing(Viewing)
    case registerPush(RegisterPush)
    case ping(Ping)
    case pong(Ping)

    private enum CodingKeys: String, CodingKey { case type, body }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello": self = .hello(try c.decode(Hello.self, forKey: .body))
        case "attachHello": self = .attachHello(try c.decode(AttachHello.self, forKey: .body))
        case "attach": self = .attach(try c.decode(Attach.self, forKey: .body))
        case "detach": self = .detach(try c.decode(SessionRef.self, forKey: .body))
        case "resize": self = .resize(try c.decode(Resize.self, forKey: .body))
        case "visibility": self = .visibility(try c.decode(Visibility.self, forKey: .body))
        case "submit": self = .submit(try c.decode(Submit.self, forKey: .body))
        case "openWorkspace": self = .openWorkspace(try c.decode(WorkspaceRef.self, forKey: .body))
        case "newTab": self = .newTab(try c.decode(NewTab.self, forKey: .body))
        case "newWorktree": self = .newWorktree(try c.decode(NewWorktree.self, forKey: .body))
        case "viewing": self = .viewing(try c.decode(Viewing.self, forKey: .body))
        case "registerPush": self = .registerPush(try c.decode(RegisterPush.self, forKey: .body))
        case "ping": self = .ping(try c.decode(Ping.self, forKey: .body))
        case "pong": self = .pong(try c.decode(Ping.self, forKey: .body))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown client message \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let v): try c.encode("hello", forKey: .type); try c.encode(v, forKey: .body)
        case .attachHello(let v): try c.encode("attachHello", forKey: .type); try c.encode(v, forKey: .body)
        case .attach(let v): try c.encode("attach", forKey: .type); try c.encode(v, forKey: .body)
        case .detach(let v): try c.encode("detach", forKey: .type); try c.encode(v, forKey: .body)
        case .resize(let v): try c.encode("resize", forKey: .type); try c.encode(v, forKey: .body)
        case .visibility(let v): try c.encode("visibility", forKey: .type); try c.encode(v, forKey: .body)
        case .submit(let v): try c.encode("submit", forKey: .type); try c.encode(v, forKey: .body)
        case .openWorkspace(let v): try c.encode("openWorkspace", forKey: .type); try c.encode(v, forKey: .body)
        case .newTab(let v): try c.encode("newTab", forKey: .type); try c.encode(v, forKey: .body)
        case .newWorktree(let v): try c.encode("newWorktree", forKey: .type); try c.encode(v, forKey: .body)
        case .viewing(let v): try c.encode("viewing", forKey: .type); try c.encode(v, forKey: .body)
        case .registerPush(let v): try c.encode("registerPush", forKey: .type); try c.encode(v, forKey: .body)
        case .ping(let v): try c.encode("ping", forKey: .type); try c.encode(v, forKey: .body)
        case .pong(let v): try c.encode("pong", forKey: .type); try c.encode(v, forKey: .body)
        }
    }
}

// MARK: - Host → client

public struct Welcome: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var hostName: String
    public var deviceID: String
    /// Only on the visit that used a pairing code: the credential to present
    /// from now on. Kept in the phone's keychain.
    public var deviceToken: String?

    public init(protocolVersion: Int = TabTermProtocol.version, hostName: String, deviceID: String, deviceToken: String?) {
        self.protocolVersion = protocolVersion
        self.hostName = hostName
        self.deviceID = deviceID
        self.deviceToken = deviceToken
    }
}

public struct Denied: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// The token or pairing code wasn't recognised. Pair again.
        case unauthorized
        /// The two ends speak different protocol versions. Update one.
        case versionMismatch
    }

    public var reason: Reason
    public var message: String

    public init(reason: Reason, message: String) {
        self.reason = reason
        self.message = message
    }
}

/// How a client's attach was served, sent once before any counted bytes.
public struct Synced: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// The client was caught up exactly: what follows is precisely what it
        /// missed, and its screen stays.
        case exact
        /// The client's screen can't be caught up. It must reset its terminal;
        /// what follows is the mode preamble and the recent output, after
        /// which the running program is asked to redraw.
        case reset
    }

    public var session: UUID
    public var epoch: String
    /// The stream position of the first counted byte to follow.
    public var seq: UInt64
    public var mode: Mode
    /// The size the replayed output was laid out for. Counting this client
    /// in may resize the session straight afterwards.
    public var size: TerminalSize

    public init(session: UUID, epoch: String, seq: UInt64, mode: Mode, size: TerminalSize) {
        self.session = session
        self.epoch = epoch
        self.seq = seq
        self.mode = mode
        self.size = size
    }
}

public struct SessionExit: Codable, Equatable, Sendable {
    /// The code sent for a session the Mac doesn't have — it was closed, or
    /// Workbench restarted and every terminal came back as a new session.
    public static let unknownSession: Int32 = -1

    public var session: UUID
    public var code: Int32
    public init(session: UUID, code: Int32) {
        self.session = session
        self.code = code
    }
}

public struct TabCreated: Codable, Equatable, Sendable {
    public var requestID: String
    public var workspace: String
    public var session: UUID
    public init(requestID: String, workspace: String, session: UUID) {
        self.requestID = requestID
        self.workspace = workspace
        self.session = session
    }
}

public struct WorktreeCreated: Codable, Equatable, Sendable {
    public var requestID: String
    /// The new worktree's workspace, as `state` names it. Nobody has opened
    /// it yet, so it has no terminals until someone does.
    public var workspace: String
    public init(requestID: String, workspace: String) {
        self.requestID = requestID
        self.workspace = workspace
    }
}

public struct ErrorMessage: Codable, Equatable, Sendable {
    public var message: String
    public init(message: String) { self.message = message }
}

public enum ServerMessage: Codable, Equatable, Sendable {
    case welcome(Welcome)
    case denied(Denied)
    case state(HostState)
    case synced(Synced)
    case exit(SessionExit)
    case tabCreated(TabCreated)
    case worktreeCreated(WorktreeCreated)
    case error(ErrorMessage)
    case ping(Ping)
    case pong(Ping)

    private enum CodingKeys: String, CodingKey { case type, body }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "welcome": self = .welcome(try c.decode(Welcome.self, forKey: .body))
        case "denied": self = .denied(try c.decode(Denied.self, forKey: .body))
        case "state": self = .state(try c.decode(HostState.self, forKey: .body))
        case "synced": self = .synced(try c.decode(Synced.self, forKey: .body))
        case "exit": self = .exit(try c.decode(SessionExit.self, forKey: .body))
        case "tabCreated": self = .tabCreated(try c.decode(TabCreated.self, forKey: .body))
        case "worktreeCreated": self = .worktreeCreated(try c.decode(WorktreeCreated.self, forKey: .body))
        case "error": self = .error(try c.decode(ErrorMessage.self, forKey: .body))
        case "ping": self = .ping(try c.decode(Ping.self, forKey: .body))
        case "pong": self = .pong(try c.decode(Ping.self, forKey: .body))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown server message \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .welcome(let v): try c.encode("welcome", forKey: .type); try c.encode(v, forKey: .body)
        case .denied(let v): try c.encode("denied", forKey: .type); try c.encode(v, forKey: .body)
        case .state(let v): try c.encode("state", forKey: .type); try c.encode(v, forKey: .body)
        case .synced(let v): try c.encode("synced", forKey: .type); try c.encode(v, forKey: .body)
        case .exit(let v): try c.encode("exit", forKey: .type); try c.encode(v, forKey: .body)
        case .tabCreated(let v): try c.encode("tabCreated", forKey: .type); try c.encode(v, forKey: .body)
        case .worktreeCreated(let v): try c.encode("worktreeCreated", forKey: .type); try c.encode(v, forKey: .body)
        case .error(let v): try c.encode("error", forKey: .type); try c.encode(v, forKey: .body)
        case .ping(let v): try c.encode("ping", forKey: .type); try c.encode(v, forKey: .body)
        case .pong(let v): try c.encode("pong", forKey: .type); try c.encode(v, forKey: .body)
        }
    }
}
