import AppKit

/// The content hosted inside a pane.
///
/// A pane holds a terminal. The protocol keeps the tab machinery — titles,
/// focus, closing — written in terms of content rather than terminals, so a
/// pane's contents can be treated uniformly.
protocol TabContent: AnyObject {
    var view: NSView { get }
    var title: String { get }

    /// Icon for the tab bar: the mark of the program running in a terminal.
    /// Nil means the tab shows its own symbol.
    var icon: NSImage? { get }

    /// Called when the content's title changes.
    var onTitleChange: ((String) -> Void)? { get set }

    /// Called when `icon` changes — a terminal started running something we
    /// have a mark for.
    var onIconChange: ((NSImage?) -> Void)? { get set }

    /// Called when the content wants its pane closed.
    ///
    /// `confirm` is true when the user asked for the close and may be
    /// discarding something; false when the content is already finished (a
    /// shell that exited on its own), where there is nothing to ask about.
    var onRequestClose: ((_ confirm: Bool) -> Void)? { get set }

    /// One sentence for the close confirmation describing what is lost.
    var closeConfirmationDetail: String { get }

    /// True when closing this loses nothing, so no confirmation is warranted:
    /// a terminal sitting at a prompt.
    var isDisposable: Bool { get }

    /// Give keyboard focus to whatever should have it.
    func takeFocus()

    /// Whether this pane is the focused one in its tab.
    ///
    /// Panes are told directly rather than inferring it from the first
    /// responder: a terminal that only learns it lost focus keeps blinking its
    /// cursor as if it were still typing.
    func setFocused(_ focused: Bool)

    /// The pane's tab became the selected tab, or stopped being it.
    func setVisible(_ visible: Bool)

    /// Release resources. Called when the pane is closed.
    func close()
}
