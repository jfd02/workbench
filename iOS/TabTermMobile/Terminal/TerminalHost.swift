import SwiftTerm
import SwiftUI
import UIKit

/// Holds a terminal view and keeps its size still while the keyboard is up.
///
/// The phone is usually the smallest screen on a session, so its size is the
/// Mac's pty size. If the terminal shrank every time the keyboard rose for the
/// composer, every tap into the text field would resize the pty and make the
/// program on the Mac redraw. So while the keyboard is up the terminal keeps
/// the height it had, pinned to the bottom of this container and clipped at
/// the top: the newest lines — where the prompt is — stay in view above the
/// composer, and nothing is resized.
final class TerminalContainerView: UIView {
    private(set) var terminalView: TerminalView?
    private var lockedHeight: CGFloat?
    private var lockedWidth: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = TerminalTheme.background

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidHide), name: UIResponder.keyboardDidHideNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func host(_ view: TerminalView) {
        guard terminalView !== view else { return }
        terminalView?.removeFromSuperview()
        terminalView = view
        addSubview(view)
        setNeedsLayout()
    }

    @objc private func keyboardWillShow() {
        // Remember the height from before the keyboard took its share. A
        // second show (switching keyboards) keeps the first lock.
        guard lockedHeight == nil, bounds.height > 0 else { return }
        lockedHeight = bounds.height
        lockedWidth = bounds.width
    }

    @objc private func keyboardDidHide() {
        lockedHeight = nil
        lockedWidth = nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let terminalView else { return }

        // A rotation while locked makes the old height meaningless.
        if lockedWidth != nil, lockedWidth != bounds.width {
            lockedHeight = nil
            lockedWidth = nil
        }

        if let lockedHeight, lockedHeight > bounds.height {
            terminalView.frame = CGRect(
                x: 0,
                y: bounds.height - lockedHeight,
                width: bounds.width,
                height: lockedHeight
            )
        } else {
            terminalView.frame = bounds
        }
    }
}

/// SwiftUI's handle on a `RemoteTerminal`'s view.
struct TerminalHost: UIViewRepresentable {
    let terminal: RemoteTerminal

    func makeUIView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView(frame: .zero)
        container.host(terminal.terminalView)
        return container
    }

    func updateUIView(_ container: TerminalContainerView, context: Context) {
        container.host(terminal.terminalView)
    }
}
