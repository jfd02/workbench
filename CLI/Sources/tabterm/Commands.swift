import Foundation
import TabTermKit

/// What `workbench` can be asked to do.
enum Command {
    static let usage = """
        workbench — Workbench's terminals, from another Mac

          workbench pair '<link>'            pair with a Mac. The link is Workbench ▸ Pair iPhone… ▸ Copy Link
          workbench ls                       its workspaces, and the terminals in each
          workbench attach                   open the terminal that Mac has on screen
          workbench attach <worktree> [tab]  open a worktree's terminal: its selected tab, or tab N
          workbench new [<repo>] <branch>    make a worktree on that branch, and open it
          workbench unpair                   forget the Mac

        While attached, \(MenuKey.configured.name) brings up the list of terminals, to switch to
        another, open a new one, or detach. A worktree can be named by any part
        of its name that no other shares.
        """

    static func run(_ arguments: [String]) -> Int32 {
        let rest = Array(arguments.dropFirst())
        switch arguments.first {
        case "pair": return pair(rest)
        case "unpair": return unpair()
        case "ls", "list": return list()
        case "attach", "a": return attach(rest)
        case "new": return new(rest)
        case nil, "help", "-h", "--help":
            print(usage)
            return 0
        case let other?:
            return fail("workbench: no such command '\(other)'\n\n\(usage)")
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }

    /// A failure to reach the Mac, as something to act on.
    static func explain(_ error: HostError, host: PairedHost) -> String {
        switch error {
        case .unreachable:
            return "Couldn't reach \(host.name). Workbench has to be running there, and Tailscale connected on both Macs."
        case .silent:
            return "\(host.name) took the connection and then went quiet. Is that Workbench still starting up?"
        case .denied(let denied) where denied.reason == .versionMismatch:
            return "\(host.name) runs a Workbench that speaks a different version of the protocol than this workbench. Rebuild whichever is older."
        case .denied:
            return "\(host.name) doesn't know this Mac any more. Pair again: Workbench ▸ Pair iPhone… ▸ Copy Link there, then `workbench pair '<link>'` here."
        }
    }

    /// Connect as the paired Mac's client, or say why not.
    private static func connect() -> (PairedHost, HostClient)? {
        guard let host = PairingFile.load() else {
            _ = fail("""
                Not paired with a Mac yet. On the Mac running Workbench, choose Workbench ▸ Pair iPhone… ▸ Copy Link, then here:
                  workbench pair '<link>'
                """)
            return nil
        }
        do {
            return (host, try HostClient.open(host))
        } catch {
            _ = fail(explain(error as? HostError ?? .silent, host: host))
            return nil
        }
    }

    // MARK: - pair

    private static func pair(_ arguments: [String]) -> Int32 {
        guard let text = arguments.first, let url = URL(string: text), let link = PairingLink(url: url) else {
            // The link has `&` in it, which a shell reads as "run in the
            // background" unless the link is quoted.
            return fail("""
                usage: workbench pair '<link>'
                The link comes from Workbench ▸ Pair iPhone… ▸ Copy Link on the other Mac. Keep the quotes: it has an & in it.
                """)
        }

        var host = PairedHost(name: link.name, hosts: link.hosts, port: link.port, deviceID: "", deviceToken: "")
        do {
            let client = try HostClient.open(host, pairingCode: link.code)
            defer { client.link.close() }
            guard let token = client.welcome.deviceToken else { throw HostError.silent }
            if !client.welcome.hostName.isEmpty { host.name = client.welcome.hostName }
            host.deviceID = client.welcome.deviceID
            host.deviceToken = token
        } catch HostError.denied(let denied) where denied.reason == .unauthorized {
            return fail("That link has expired or was already used: each one works once, for ten minutes, while the pairing window is open. Copy a new one and try again.")
        } catch {
            return fail(explain(error as? HostError ?? .silent, host: host))
        }

        do {
            try PairingFile.save(host)
        } catch {
            return fail("Paired, but couldn't write \(PairingFile.url.path): \(error.localizedDescription)")
        }
        print("Paired with \(host.name). `workbench ls` shows what's running there.")
        return 0
    }

    private static func unpair() -> Int32 {
        guard let host = PairingFile.load() else {
            print("Not paired with a Mac.")
            return 0
        }
        PairingFile.remove()
        print("Forgot \(host.name). It still lists this Mac under Workbench ▸ Pair iPhone… until it is forgotten there too.")
        return 0
    }

    // MARK: - ls

    private static func list() -> Int32 {
        guard let (_, client) = connect() else { return 1 }
        defer { client.link.close() }
        let color = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        print(Catalog.listing(client.state, color: color))
        return 0
    }

    // MARK: - attach

    private static func attach(_ arguments: [String]) -> Int32 {
        guard arguments.count <= 2 else {
            return fail("usage: workbench attach [<worktree> [<tab>]]")
        }
        var tab: Int?
        var pane: Int?
        if arguments.count == 2 {
            // `2`, or `2.1` for a pane of a tab that has been split.
            let parts = arguments[1].split(separator: ".").map { Int($0) }
            guard (1...2).contains(parts.count), !parts.contains(nil) else {
                return fail("workbench: '\(arguments[1])' isn't a tab. Tabs are numbered as `workbench ls` shows them.")
            }
            tab = parts[0]
            pane = parts.count == 2 ? parts[1] : nil
        }
        guard Terminal.isInteractive else {
            return fail("workbench: attach needs a terminal to attach to.")
        }
        guard let (host, client) = connect() else { return 1 }

        let session: UUID?
        if let query = arguments.first {
            switch target(query, tab: tab, pane: pane, on: client) {
            case .success(let found): session = found
            case .failure(let problem):
                client.link.close()
                return fail("workbench: \(problem.message)")
            }
        } else {
            // Carry on with what the Mac has on screen, as the phone does;
            // failing that, with anything it has open at all.
            session = client.state.focus?.session
                ?? client.state.workspaces.lazy.compactMap { Catalog.terminal(in: $0) }.first
        }

        AttachSession(host: host, client: client, session: session).run()
    }

    private struct Problem: Error {
        var message: String
    }

    // MARK: - new

    private static func new(_ arguments: [String]) -> Int32 {
        guard (1...2).contains(arguments.count), let branch = arguments.last, !branch.isEmpty else {
            return fail("""
                usage: workbench new [<repository>] <branch>
                The branch can be one that exists, here or on a remote, or the name of a new one.
                """)
        }
        guard let (host, client) = connect() else { return 1 }

        let query = arguments.count == 2 ? arguments[0] : nil
        let repository: String
        let beside: String
        switch Catalog.findRepository(query, in: client.state) {
        case .one(let name, let workspace):
            (repository, beside) = (name, workspace)
        case .none:
            client.link.close()
            return fail(query.map { "workbench: no repository called '\($0)'. `workbench ls` shows what there is." }
                ?? "workbench: \(host.name) has no repositories in its sidebar yet.")
        case .several(let names):
            client.link.close()
            return fail("workbench: which repository — \(names.joined(separator: ", "))? `workbench new <repository> \(branch)`")
        }

        // A new branch starts from the remote's default branch, freshly
        // fetched, so this can take as long as a fetch does.
        FileHandle.standardError.write(Data("Making \(repository)/\(branch)…\n".utf8))
        let id = UUID().uuidString
        var created: String?
        var refusal: String?
        client.link.send(.newWorktree(NewWorktree(workspace: beside, branch: branch, requestID: id)))
        _ = client.wait(120) { message in
            if case .worktreeCreated(let made) = message, made.requestID == id { created = made.workspace }
            if case .error(let error) = message { refusal = error.message }
            return created != nil || refusal != nil
        }

        guard let created else {
            client.link.close()
            switch refusal {
            case "Unrecognized message.":
                // What a Workbench from before this message existed says to it.
                return fail("""
                    workbench: the Workbench running on \(host.name) is older than this workbench and can't be asked for a worktree. \
                    Rebuild and restart it — or run `git worktree add` in one of its terminals, which it notices by itself.
                    """)
            case let reason?:
                return fail("workbench: \(host.name) couldn't make it: \(reason)")
            case nil:
                return fail("workbench: \(host.name) didn't answer. If the worktree was made, `workbench ls` shows it.")
            }
        }

        // The sidebar is sent ahead of the answer, so it is usually here.
        if client.state.workspace(id: created) == nil {
            _ = client.wait(5) { _ in client.state.workspace(id: created) != nil }
        }
        guard let workspace = client.state.workspace(id: created) else {
            client.link.close()
            return fail("workbench: made, but \(host.name) hasn't listed it. `workbench ls` should show it.")
        }

        // Somewhere to attach means go there, as the Mac's sidebar does after
        // its own sheet. Without one — a script — making it was the job.
        guard Terminal.isInteractive else {
            client.link.close()
            print("Made \(Catalog.label(workspace))" + (workspace.directory.map { " in \(Catalog.abbreviated($0))" } ?? ""))
            return 0
        }
        switch terminal(in: workspace, tab: nil, pane: nil, on: client) {
        case .success(let session):
            AttachSession(host: host, client: client, session: session).run()
        case .failure(let problem):
            client.link.close()
            return fail("workbench: \(problem.message)")
        }
    }

    /// The terminal `query` and a tab number name.
    private static func target(_ query: String, tab: Int?, pane: Int?, on client: HostClient) -> Result<UUID, Problem> {
        let workspace: WorkspaceInfo
        switch Catalog.find(query, in: client.state) {
        case .one(let found):
            workspace = found
        case .none:
            return .failure(Problem(message: "nothing called '\(query)'. `workbench ls` shows what there is."))
        case .several(let labels):
            return .failure(Problem(message: "'\(query)' could be any of: \(labels.joined(separator: ", "))"))
        }
        return terminal(in: workspace, tab: tab, pane: pane, on: client)
    }

    /// A workspace's terminal, starting its terminals if nobody has opened
    /// it, and opening one if it has none.
    private static func terminal(
        in workspace: WorkspaceInfo, tab: Int?, pane: Int?, on client: HostClient
    ) -> Result<UUID, Problem> {
        let label = Catalog.label(workspace)

        if !workspace.isOpen {
            // Nobody has opened it since Workbench started, so its terminals
            // don't exist yet. Start them without switching the Mac to it.
            FileHandle.standardError.write(Data("Starting \(label)…\n".utf8))
            client.link.send(.openWorkspace(WorkspaceRef(workspace: workspace.id)))
            guard client.wait(15, until: { _ in client.state.workspace(id: workspace.id)?.isOpen == true }) else {
                return .failure(Problem(message: "\(label) didn't start."))
            }
        }
        guard let current = client.state.workspace(id: workspace.id) else {
            return .failure(Problem(message: "\(label) is gone."))
        }

        if let session = Catalog.terminal(in: current, tab: tab, pane: pane) {
            return .success(session)
        }
        if let tab, !current.tabs.isEmpty {
            let address = pane.map { "\(tab).\($0)" } ?? "\(tab)"
            return .failure(Problem(message: "\(label) has no tab \(address). `workbench ls` shows the ones it has."))
        }

        // Every tab was closed: open one.
        let id = UUID().uuidString
        var created: UUID?
        client.link.send(.newTab(NewTab(workspace: workspace.id, requestID: id)))
        _ = client.wait(10) { message in
            if case .tabCreated(let tab) = message, tab.requestID == id { created = tab.session }
            if case .error = message { return true }
            return created != nil
        }
        return created.map { .success($0) } ?? .failure(Problem(message: "couldn't open a terminal in \(label)."))
    }
}
