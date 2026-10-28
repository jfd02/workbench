import SwiftUI
import TabTermKit

/// The agent dot, as on the Mac's sidebar: amber and gently pulsing while an
/// agent works, red when it wants you, nothing at all otherwise.
struct StatusDot: View {
    let status: AgentStatus
    var size: CGFloat = 8

    @State private var pulsing = false

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .working:
            Circle()
                .fill(TerminalTheme.claude)
                .frame(width: size, height: size)
                .opacity(pulsing ? 0.35 : 1)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
                .accessibilityLabel("Working")
        case .finished, .blocked:
            Circle()
                .fill(Color.red)
                .frame(width: size, height: size)
                .accessibilityLabel(status == .blocked ? "Needs your answer" : "Finished")
        }
    }
}

extension AgentStatus {
    /// Words for the one place a dot needs explaining.
    var caption: String? {
        switch self {
        case .idle: return nil
        case .working: return "Working"
        case .finished: return "Finished"
        case .blocked: return "Needs you"
        }
    }
}

/// Connected, connecting, or not.
struct ConnectionBadge: View {
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .yellow
        case .offline, .denied: return .gray
        }
    }

    private var label: String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .offline: return "Offline"
        case .denied: return "Not allowed"
        }
    }
}
