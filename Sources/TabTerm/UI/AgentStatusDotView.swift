import AppKit

/// The dot on the right of a sidebar row saying what an agent is doing in it.
///
/// Two colours, because there are only two things worth interrupting someone
/// for: Claude's own orange while it is working, and red when it has stopped
/// and can't go on without them. Anything else draws nothing at all — a row
/// with no agent in it should look exactly as it did before.
///
/// The working dot breathes. A steady dot in the corner of the eye reads as a
/// badge; a moving one reads as something happening, which is what it is.
final class AgentStatusDotView: NSView {
    static let diameter: CGFloat = 8

    private(set) var state: AgentState = .idle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.diameter / 2
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.diameter, height: Self.diameter)
    }

    func setState(_ newState: AgentState) {
        let changed = newState != state
        state = newState

        isHidden = newState == .idle
        if changed {
            layer?.backgroundColor = Self.color(for: newState).cgColor
            toolTip = Self.tooltip(for: newState)
        }

        // Cells are reused, so a dot that should be pulsing may arrive here
        // already the right colour but with its animation left behind.
        if newState == .working {
            if layer?.animation(forKey: Self.pulseKey) == nil { startPulsing() }
        } else {
            layer?.removeAnimation(forKey: Self.pulseKey)
        }
    }

    /// Animations are dropped when a view leaves the window, so put it back.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, state == .working else { return }
        if layer?.animation(forKey: Self.pulseKey) == nil { startPulsing() }
    }

    private static let pulseKey = "tabterm.agentPulse"

    private func startPulsing() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(pulse, forKey: Self.pulseKey)
    }

    static func color(for state: AgentState) -> NSColor {
        switch state {
        case .idle: return .clear
        // The same orange the tab already draws Claude's mark in.
        case .working: return ClaudeIcon.color
        case .finished, .blocked: return .systemRed
        }
    }

    static func tooltip(for state: AgentState) -> String? {
        switch state {
        case .idle: return nil
        case .working: return "Claude is working here"
        case .finished: return "Claude finished — waiting for you"
        case .blocked: return "Claude is waiting for your answer"
        }
    }
}
