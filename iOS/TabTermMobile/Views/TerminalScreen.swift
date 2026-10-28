import SwiftUI
import TabTermKit

/// One terminal, full screen: the live terminal, a row of the keys a phone
/// keyboard lacks, and a composer for writing to it the comfortable way.
struct TerminalScreen: View {
    let session: UUID

    @Environment(AppModel.self) private var model
    @FocusState private var composerFocused: Bool
    @State private var keyboardVisible = false

    var body: some View {
        let terminal = model.terminal(for: session)
        let location = model.hostState.locate(session)
        // Read so an exit or reset redraws the banner.
        let _ = model.terminalRevision

        VStack(spacing: 0) {
            TerminalHost(terminal: terminal)
                .overlay(alignment: .top) {
                    banner(terminal: terminal, location: location)
                        .padding(.top, 8)
                }

            QuickKeysBar(
                keyboardVisible: keyboardVisible,
                send: { key in model.send(key, to: session) },
                toggleKeyboard: { toggleDirectTyping(terminal) }
            )

            ComposerBar(
                text: draftBinding,
                isClaude: location?.pane.isClaude ?? false,
                focused: $composerFocused,
                send: { text in model.submit(text, to: session) }
            )
        }
        .background(Color(uiColor: TerminalTheme.background).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TerminalTheme.chrome, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TitleView(location: location)
            }
            ToolbarItem(placement: .topBarTrailing) {
                paneMenu(location: location)
            }
        }
        .onAppear { model.display(session) }
        .onDisappear { model.stopDisplaying(session) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { model.drafts[session] ?? "" },
            set: { model.drafts[session] = $0 }
        )
    }

    /// Type straight into the terminal rather than through the composer — for
    /// a `y`/`n`, a pager, vim. Pressing it again puts the keyboard away.
    private func toggleDirectTyping(_ terminal: RemoteTerminal) {
        let view = terminal.terminalView
        if view.isFirstResponder || keyboardVisible {
            composerFocused = false
            _ = view.resignFirstResponder()
        } else {
            _ = view.becomeFirstResponder()
        }
    }

    // MARK: - Banner

    @ViewBuilder
    private func banner(terminal: RemoteTerminal, location: (workspace: WorkspaceInfo, tab: TabInfo, pane: PaneInfo)?) -> some View {
        if let code = terminal.exitCode {
            Pill(icon: "stop.circle", text: code == 0 ? "Session ended" : "Session ended (exit \(code))")
        } else if !model.isDemo, model.connectionState != .connected {
            Pill(icon: "arrow.triangle.2.circlepath", text: "Reconnecting to \(model.pairedMac?.name ?? "your Mac")…")
        } else if !model.isDemo, !model.hostState.workspaces.isEmpty, location == nil {
            Pill(icon: "xmark.circle", text: "This terminal was closed on the Mac")
        } else if let notice = model.notice {
            Pill(icon: "exclamationmark.triangle", text: notice)
                .task {
                    try? await Task.sleep(for: .seconds(3))
                    model.notice = nil
                }
        }
    }

    // MARK: - Pane menu

    @ViewBuilder
    private func paneMenu(location: (workspace: WorkspaceInfo, tab: TabInfo, pane: PaneInfo)?) -> some View {
        if let workspace = location?.workspace {
            Menu {
                ForEach(workspace.tabs) { tab in
                    Section(tab.panes.count > 1 ? tab.title : "") {
                        ForEach(tab.panes) { pane in
                            Button {
                                model.open(session: pane.session)
                            } label: {
                                if pane.session == session {
                                    Label(pane.displayTitle, systemImage: "checkmark")
                                } else {
                                    Label(pane.displayTitle, systemImage: pane.isClaude ? "sparkle" : "terminal")
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("New Terminal", systemImage: "plus") {
                    model.newTab(in: workspace.id)
                }
            } label: {
                Image(systemName: "rectangle.stack")
            }
        }
    }
}

/// Pane title over where it lives, with its agent dot.
private struct TitleView: View {
    let location: (workspace: WorkspaceInfo, tab: TabInfo, pane: PaneInfo)?

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                if let pane = location?.pane {
                    StatusDot(status: pane.status, size: 7)
                }
                Text(location?.pane.displayTitle ?? "Terminal")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            if let workspace = location?.workspace {
                Text(workspace.repository.map { "\($0) · \(workspace.branch ?? workspace.name)" } ?? workspace.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 240)
    }
}

private struct Pill: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(TerminalTheme.hairline))
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
