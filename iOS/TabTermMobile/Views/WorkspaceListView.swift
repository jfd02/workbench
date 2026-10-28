import SwiftUI
import TabTermKit

/// The Mac's sidebar, on the phone: Home, then each repository's worktrees,
/// each with its agent dot. Expanding a workspace shows its terminals.
struct WorkspaceListView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []
    @State private var confirmForget = false

    var body: some View {
        List {
            if case .denied(let message) = model.connectionState {
                Section {
                    Label(message, systemImage: "lock.slash")
                        .foregroundStyle(.secondary)
                    Button("Pair Again") { model.forgetMac() }
                }
            }

            if let focus = focusedPane {
                Section {
                    Button {
                        model.open(session: focus.pane.session)
                    } label: {
                        OnYourMacRow(workspace: focus.workspace, pane: focus.pane)
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("On your Mac")
                }
            }

            ForEach(sections, id: \.title) { section in
                Section {
                    ForEach(section.workspaces) { workspace in
                        WorkspaceRow(
                            workspace: workspace,
                            isExpanded: expanded.contains(workspace.id),
                            isOpening: model.openingWorkspaces.contains(workspace.id),
                            toggle: { toggle(workspace) }
                        )
                        .listRowBackground(rowBackground(onScreen: workspace.id == model.hostState.focus?.workspace))
                        if expanded.contains(workspace.id) {
                            ForEach(workspace.tabs) { tab in
                                ForEach(tab.panes) { pane in
                                    Button {
                                        model.open(session: pane.session)
                                    } label: {
                                        PaneRow(pane: pane, tabTitle: tab.panes.count > 1 ? tab.title : nil)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            if workspace.isOpen {
                                Button {
                                    model.newTab(in: workspace.id)
                                } label: {
                                    Label("New Terminal", systemImage: "plus")
                                        .font(.subheadline)
                                        .padding(.leading, 26)
                                }
                            }
                        }
                    }
                } header: {
                    if section.title != Self.homeSection {
                        Text(section.title)
                    }
                }
            }

            if model.hostState.workspaces.isEmpty, model.connectionState != .connected {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reaching \(model.pairedMac?.name ?? "your Mac")…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } footer: {
                    Text("Workbench needs to be running on the Mac, and Tailscale connected on both.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: TerminalTheme.background))
        .navigationTitle(model.hostState.hostName.isEmpty ? (model.pairedMac?.name ?? "Workbench") : model.hostState.hostName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectionBadge(state: model.connectionState)
                    .fixedSize()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Forget This Mac", systemImage: "xmark.circle", role: .destructive) {
                        confirmForget = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Forget \(model.pairedMac?.name ?? "this Mac")?",
            isPresented: $confirmForget,
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) { model.forgetMac() }
        } message: {
            Text("You'll need to scan a new pairing code from the Mac to connect again.")
        }
        .onAppear(perform: expandBusyWorkspaces)
        .onChange(of: model.hostState) { _, _ in expandBusyWorkspaces() }
    }

    // MARK: - Data

    /// Home's section, which gets no header: it sits above the repositories
    /// as it does on the Mac.
    private static let homeSection = "\u{0}home"

    private struct SidebarSection {
        var title: String
        var workspaces: [WorkspaceInfo]
    }

    /// Home first, then one section per repository, in the Mac's order.
    private var sections: [SidebarSection] {
        var result: [SidebarSection] = []
        for workspace in model.hostState.workspaces {
            let title = workspace.repository ?? Self.homeSection
            if let index = result.firstIndex(where: { $0.title == title }) {
                result[index].workspaces.append(workspace)
            } else {
                result.append(SidebarSection(title: title, workspaces: [workspace]))
            }
        }
        return result
    }

    private var focusedPane: (workspace: WorkspaceInfo, pane: PaneInfo)? {
        guard let session = model.hostState.focus?.session,
              let found = model.hostState.locate(session)
        else { return nil }
        return (found.workspace, found.pane)
    }

    /// The usual row, tinted blue for the worktree the Mac is showing.
    private func rowBackground(onScreen: Bool) -> some View {
        Color(uiColor: .secondarySystemGroupedBackground)
            .overlay(onScreen ? TerminalTheme.onScreen : .clear)
    }

    private func toggle(_ workspace: WorkspaceInfo) {
        if expanded.contains(workspace.id) {
            expanded.remove(workspace.id)
        } else {
            expanded.insert(workspace.id)
            if !workspace.isOpen { model.openWorkspace(workspace.id) }
        }
    }

    /// Open workspaces with something to say start expanded, so an agent that
    /// wants you is one tap away rather than two.
    private func expandBusyWorkspaces() {
        for workspace in model.hostState.workspaces where workspace.isOpen && workspace.status != .idle {
            expanded.insert(workspace.id)
        }
    }
}

// MARK: - Rows

private struct OnYourMacRow: View {
    let workspace: WorkspaceInfo
    let pane: PaneInfo

    var body: some View {
        HStack(spacing: 12) {
            PaneIcon(isClaude: pane.isClaude)
                .font(.title3)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.displayTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(workspace.repository.map { "\($0) · \(workspace.name)" } ?? workspace.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusDot(status: pane.status)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct WorkspaceRow: View {
    let workspace: WorkspaceInfo
    let isExpanded: Bool
    let isOpening: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: workspace.repository == nil ? "house" : "arrow.triangle.branch")
                    .foregroundStyle(TerminalTheme.claude)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.branch ?? workspace.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isOpening {
                    ProgressView().controlSize(.small)
                }
                StatusDot(status: workspace.status)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isExpanded)
    }

    private var detail: String? {
        if !workspace.isOpen { return isOpening ? "Opening…" : "Not open on the Mac" }
        if workspace.repository == nil { return nil }
        let count = workspace.tabs.reduce(0) { $0 + $1.panes.count }
        let folder = workspace.directory.map { ($0 as NSString).lastPathComponent } ?? workspace.name
        return "\(folder) · \(count) terminal\(count == 1 ? "" : "s")"
    }
}

private struct PaneRow: View {
    let pane: PaneInfo
    let tabTitle: String?

    var body: some View {
        HStack(spacing: 10) {
            PaneIcon(isClaude: pane.isClaude)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                if let caption = pane.status.caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(pane.status.wantsAttention ? Color.red : TerminalTheme.claude)
                }
            }
            Spacer(minLength: 8)
            StatusDot(status: pane.status, size: 7)
        }
        .padding(.leading, 26)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Claude's mark for a terminal running Claude Code, the terminal symbol
/// otherwise — the same rule as the Mac's tab icons.
struct PaneIcon: View {
    let isClaude: Bool

    var body: some View {
        if isClaude {
            Image(systemName: "sparkle")
                .foregroundStyle(TerminalTheme.claude)
        } else {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
        }
    }
}
