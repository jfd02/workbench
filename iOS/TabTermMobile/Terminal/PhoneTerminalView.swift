import SwiftTerm
import UIKit

/// SwiftTerm's terminal view, with touch handling for a phone that writes
/// through a composer.
///
/// A tap never raises the keyboard. The composer is where writing happens and
/// the keyboard key in the quick-keys row is how to type into the terminal
/// directly, so a tap here puts away whichever keyboard is up, the way a tap on
/// a chat's transcript does. Once the terminal has the keyboard, taps go back
/// to SwiftTerm for links, selection and the paste menu.
///
/// A program on the alternate screen — Claude Code's fullscreen mode, less,
/// vim — keeps its own scrollback, so there is nothing here for the scroll view
/// to scroll. A vertical drag there is handed to `onScroll` instead, a row of
/// drag to a row and coasting after a flick, for the program to scroll itself.
final class PhoneTerminalView: TerminalView {
    /// Rows to scroll a program on the alternate screen, positive back towards
    /// older output, and the cell under the finger.
    var onScroll: ((_ rows: Int, _ col: Int, _ row: Int) -> Void)?

    private lazy var scrollPan = UIPanGestureRecognizer(target: self, action: #selector(scrollPanned(_:)))
    /// Drag not yet sent because it doesn't make a whole row.
    private var unsentDistance: CGFloat = 0
    private var lastTranslation: CGFloat = 0
    private var lastLocation: CGPoint = .zero
    private var coast: CADisplayLink?
    private var coastVelocity: CGFloat = 0
    private var lastCoastTime: CFTimeInterval = 0

    init(options: TerminalOptions) {
        super.init(frame: .zero, font: nil, options: options)
        scrollPan.maximumNumberOfTouches = 1
        addGestureRecognizer(scrollPan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var isOnAlternateScreen: Bool {
        getTerminal().isCurrentBufferAlternate
    }

    private var rowHeight: CGFloat {
        bounds.height / CGFloat(max(getTerminal().rows, 1))
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture === scrollPan {
            let velocity = scrollPan.velocity(in: self)
            return isOnAlternateScreen && !hasActiveSelection && abs(velocity.y) > abs(velocity.x)
        }
        // The alternate screen is exactly one screen tall; the drag is ours.
        if gesture === panGestureRecognizer, isOnAlternateScreen {
            return false
        }
        // SwiftTerm's single tap takes the keyboard when the terminal doesn't
        // have it.
        if !isFirstResponder, let tap = gesture as? UITapGestureRecognizer, tap.numberOfTapsRequired == 1 {
            window?.endEditing(true)
            return false
        }
        return super.gestureRecognizerShouldBegin(gesture)
    }

    /// SwiftTerm adds a drag recognizer for mouse reporting whenever a program
    /// turns the mouse on. Reporting is off here, so all it would do is take
    /// drags away from scrolling.
    override func mouseModeChanged(source: Terminal) {}

    // MARK: - Scrolling the alternate screen

    @objc private func scrollPanned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopCoasting()
            unsentDistance = 0
            lastTranslation = 0
        case .changed:
            let translation = gesture.translation(in: self).y
            lastLocation = gesture.location(in: self)
            scroll(by: translation - lastTranslation)
            lastTranslation = translation
        case .ended:
            startCoasting(velocity: gesture.velocity(in: self).y)
        default:
            break
        }
    }

    /// Turn `distance` points of drag, positive downwards, into whole rows.
    private func scroll(by distance: CGFloat) {
        let rowHeight = self.rowHeight
        guard rowHeight > 0 else { return }
        unsentDistance += distance
        let rows = Int(unsentDistance / rowHeight)
        guard rows != 0 else { return }
        unsentDistance -= CGFloat(rows) * rowHeight

        let terminal = getTerminal()
        let col = min(max(Int(lastLocation.x / max(bounds.width, 1) * CGFloat(terminal.cols)), 0), terminal.cols - 1)
        let row = min(max(Int(lastLocation.y / rowHeight), 0), terminal.rows - 1)
        onScroll?(rows, col, row)
    }

    private func startCoasting(velocity: CGFloat) {
        guard abs(velocity) > 200 else { return }
        coastVelocity = velocity
        lastCoastTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(coastStep(_:)))
        link.add(to: .main, forMode: .common)
        coast = link
    }

    /// Slows the way a scroll view does after a flick.
    @objc private func coastStep(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let elapsed = now - lastCoastTime
        lastCoastTime = now
        scroll(by: coastVelocity * elapsed)
        coastVelocity *= pow(UIScrollView.DecelerationRate.normal.rawValue, elapsed * 1000)
        if abs(coastVelocity) < 30 || !isOnAlternateScreen {
            stopCoasting()
        }
    }

    private func stopCoasting() {
        coast?.invalidate()
        coast = nil
    }

    /// A finger coming down stops a coast, as it does a scroll view's.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopCoasting()
        super.touchesBegan(touches, with: event)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopCoasting() }
    }
}
