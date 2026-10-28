import AppKit
import Carbon
import GhosttyKit

/// An NSView that hosts a real libghostty terminal surface.
///
/// libghostty owns the rendering: we hand it this view via the surface config
/// and its Metal renderer sets `wantsLayer` and installs its own CAMetalLayer.
/// Our job is to feed it input (keyboard, mouse, IME) and keep it informed of
/// size, backing scale, and focus.
final class GhosttySurfaceView: NSView, NSTextInputClient {
    /// The libghostty surface. nil if creation failed or after close.
    private(set) var surface: ghostty_surface_t?

    /// Called when the terminal reports a new title.
    var onTitleChange: ((String) -> Void)?

    /// The shell reported a directory. Also the first sign that it has finished
    /// starting up, which is when it is safe to type at it.
    var onPwdChange: ((String) -> Void)?

    /// Called when the surface wants to go away. The flag is true when the user
    /// asked for it (a close binding) and false when the child process exited.
    var onClose: ((_ confirm: Bool) -> Void)?

    /// Called when a split binding fires in this terminal.
    var onSplit: ((SplitDirection) -> Void)?

    /// Called when a binding asks to move focus to another split.
    var onGotoSplit: ((SplitFocusTarget) -> Void)?

    /// Called when a binding asks to even out the splits.
    var onEqualizeSplits: (() -> Void)?

    /// Current working directory as reported by the shell.
    private(set) var pwd: String?

    /// Cell size, used to position the IME candidate window.
    var cellSize: CGSize = .zero

    /// Error from surface creation, if any.
    private(set) var error: String?

    private var focused: Bool = false
    private var contentSize: CGSize = .zero
    private var trackingArea: NSTrackingArea?
    private var cursor: NSCursor = .iBeam
    private var cursorVisible: Bool = true

    // IME state
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    /// - Parameters:
    ///   - workingDirectory: initial cwd, or nil for the default.
    ///   - command: command to run instead of the default shell.
    ///   - environment: extra variables for the pty, on top of the app's own.
    init(
        workingDirectory: String? = nil,
        command: String? = nil,
        environment: [String: String] = [:]
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        registerForDraggedTypes(Array(Self.dropTypes))

        guard let app = GhosttyApp.shared.app else {
            error = GhosttyApp.shared.startupError ?? "libghostty unavailable"
            return
        }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            )
        )
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.context = GHOSTTY_SURFACE_CONTEXT_TAB

        // libghostty copies the environment out of the config, but only during
        // the call, so these have to be duplicated rather than borrowed from
        // the Swift strings and freed afterwards. Sorted so the pty's
        // environment doesn't depend on dictionary order.
        var strings: [UnsafeMutablePointer<CChar>] = []
        var variables: [ghostty_env_var_s] = []
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            guard let name = strdup(key), let contents = strdup(value) else { continue }
            strings.append(name)
            strings.append(contents)
            variables.append(
                ghostty_env_var_s(key: UnsafePointer(name), value: UnsafePointer(contents))
            )
        }
        defer { for string in strings { free(string) } }

        // These C strings must outlive ghostty_surface_new, so keep them alive
        // for the duration of the call rather than using a temporary.
        surface = variables.withUnsafeMutableBufferPointer { buffer in
            config.env_vars = buffer.baseAddress
            config.env_var_count = buffer.count
            return withOptionalCString(workingDirectory) { cwd in
                withOptionalCString(command) { cmd in
                    config.working_directory = cwd
                    config.command = cmd
                    return ghostty_surface_new(app, &config)
                }
            }
        }

        if surface == nil {
            error = "ghostty_surface_new failed"
            Ghostty.logger.critical("ghostty_surface_new failed")
            return
        }

        updateTrackingAreas()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    /// Tear down the surface. Safe to call more than once.
    func close() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    private func withOptionalCString<R>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) -> R
    ) -> R {
        guard let string else { return body(nil) }
        return string.withCString { body($0) }
    }

    // MARK: - Callbacks from GhosttyApp

    func titleDidChange(_ title: String) {
        onTitleChange?(title)
    }

    func pwdDidChange(_ pwd: String) {
        self.pwd = pwd
        onPwdChange?(pwd)
    }

    /// The child process exited, so the surface is finished. Nothing to confirm.
    func requestClose(processAlive: Bool) {
        onClose?(false)
    }

    /// The user triggered a close binding; treat it like clicking the tab's X.
    func requestUserClose() {
        onClose?(true)
    }

    /// A `new_split` binding fired: divide the space this surface occupies.
    func requestSplit(_ direction: SplitDirection) {
        onSplit?(direction)
    }

    /// A `goto_split` binding fired: move focus to a neighbouring pane.
    func requestFocusSplit(_ target: SplitFocusTarget) {
        onGotoSplit?(target)
    }

    /// An `equalize_splits` binding fired.
    func requestEqualizeSplits() {
        onEqualizeSplits?()
    }

    // What is running in the terminal is the session's business now: this
    // surface's own child is the attach process, so libghostty's foreground
    // pid and quit check would only ever describe that.

    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        cursor = Self.cursor(for: shape)
        window?.invalidateCursorRects(for: self)
        if focused, window?.isKeyWindow == true {
            cursor.set()
        }
    }

    func setMouseVisibility(_ visible: Bool) {
        guard cursorVisible != visible else { return }
        cursorVisible = visible
        if visible {
            NSCursor.unhide()
        } else {
            NSCursor.hide()
        }
    }

    func confirmClipboardRead(
        _ value: String,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let surface else { return }

        let alert = NSAlert()
        alert.messageText = "Allow paste?"
        alert.informativeText =
            "The terminal is trying to read the clipboard:\n\n\(value)"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        let allowed = alert.runModal() == .alertFirstButtonReturn

        value.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, allowed)
        }
    }

    private static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: return .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: return .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_GRAB: return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: return .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            return .resizeUpDown
        default: return .iBeam
        }
    }

    // MARK: - Geometry

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange(newSize)
    }

    private func sizeDidChange(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        contentSize = size

        // libghostty wants the framebuffer size, not the point size.
        let scaled = convertToBacking(size)
        setSurfaceSize(width: UInt32(scaled.width), height: UInt32(scaled.height))
    }

    private func setSurfaceSize(width: UInt32, height: UInt32) {
        guard let surface else { return }
        ghostty_surface_set_size(surface, width, height)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        // Keep the layer from being scaled by the compositor; we handle DPI
        // ourselves by resizing the framebuffer below.
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        guard let surface else { return }

        let fbFrame = convertToBacking(frame)
        let xScale = frame.size.width > 0 ? fbFrame.size.width / frame.size.width : 1
        let yScale = frame.size.height > 0 ? fbFrame.size.height / frame.size.height : 1
        ghostty_surface_set_content_scale(surface, xScale, yScale)

        let scaled = convertToBacking(contentSize)
        setSurfaceSize(width: UInt32(scaled.width), height: UInt32(scaled.height))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        viewDidChangeBackingProperties()
        sizeDidChange(frame.size)
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusDidChange(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusDidChange(false) }
        return result
    }

    func focusDidChange(_ focused: Bool) {
        guard let surface, self.focused != focused else { return }
        self.focused = focused
        ghostty_surface_set_focus(surface, focused)
    }

    /// Called when this surface's tab becomes visible or hidden.
    func setOcclusion(visible: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        // Take focus on click so typing goes to this terminal.
        window?.makeFirstResponder(self)
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        // libghostty wants top-left origin; AppKit gives us bottom-left.
        ghostty_surface_mouse_pos(
            surface,
            pos.x,
            frame.height - pos.y,
            Ghostty.ghosttyMods(event.modifierFlags)
        )
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard let surface else { return }
        // Send an out-of-bounds position so the terminal clears hover state.
        ghostty_surface_mouse_pos(surface, -1, -1, Ghostty.ghosttyMods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            // Matches Ghostty's own multiplier; it just feels better.
            x *= 2
            y *= 2
        }

        let mods = Ghostty.Input.ScrollMods(
            precision: precision,
            momentum: .init(event.momentumPhase)
        )
        ghostty_surface_mouse_scroll(surface, x, y, mods.cScrollMods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Translate mods for things like macos-option-as-alt before letting
        // AppKit produce characters.
        let translationModsGhostty = Ghostty.eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(
                surface,
                Ghostty.ghosttyMods(event.modifierFlags)
            )
        )

        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        // IMPORTANT: reuse the original event when the mods are unchanged.
        // AppKit appears to rely on event identity for some IMEs (Korean).
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Setting this non-nil marks that we're inside a keyDown, so
        // insertText accumulates instead of sending directly.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        interpretKeyEvents([translationEvent])

        syncPreedit(clearIfNeeded: markedTextBefore)

        // We're composing if we have preedit now, or if we just cleared it:
        // that input belonged to the IME, not the terminal.
        let composing = markedText.length > 0 || markedTextBefore

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                if Self.isComposingControlInput(text, composing: composing) { continue }
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if Self.isComposingControlInput(event.characters, composing: composing) { return }
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                composing: composing
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        // Don't disturb an in-progress composition.
        if hasMarkedText() { return }

        let mods = Ghostty.ghosttyMods(event.modifierFlags)

        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            // The modifier is down, but we must check it's the same side:
            // otherwise this is a release with the other side still held.
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }

        _ = keyAction(action, event: event)
    }

    @discardableResult
    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }

        var keyEvent = event.ghosttyKeyEvent(
            action,
            translationMods: translationEvent?.modifierFlags
        )
        keyEvent.composing = composing

        // Only send UTF-8 text for non-control characters: libghostty encodes
        // control characters itself, and sending both breaks e.g. ctrl+enter.
        if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
            return text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        }
        return ghostty_surface_key(surface, keyEvent)
    }

    /// True when this is a bare control character produced while an IME is
    /// composing. That input belongs to the IME, not the terminal.
    private static func isComposingControlInput(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.count == 1,
              let scalar = text.unicodeScalars.first
        else { return false }
        return scalar.value < 0x20
    }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            return
        }

        // Outside a keyDown (e.g. layout change mid-composition) push it now.
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else {
            return NSRect(origin: frame.origin, size: .zero)
        }

        var x: Double = 0
        var y: Double = 0
        var width: Double = cellSize.width
        var height: Double = cellSize.height
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        // libghostty gives us top-left origin view coordinates.
        let viewRect = NSRect(x: x, y: frame.height - y - height, width: width, height: height)
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        guard !chars.isEmpty else { return }

        // Committing text ends any composition.
        if hasMarkedText() {
            markedText.mutableString.setString("")
        }

        if keyTextAccumulator != nil {
            // Inside keyDown: let keyDown encode it along with the key event.
            keyTextAccumulator?.append(chars)
        } else if let surface {
            // Outside keyDown (e.g. dictation, Emoji picker): send as text.
            ghostty_surface_text(surface, chars, UInt(chars.utf8.count))
        }
    }

    override func doCommand(by selector: Selector) {
        // Swallow AppKit's default text-editing commands. Real key encoding
        // happens in keyDown; without this, keys like Escape would beep.
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }

        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8.count
            if len > 0 {
                str.withCString { ptr in
                    ghostty_surface_preedit(surface, ptr, UInt(len))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: - Dropping files and text

    /// Tabs dragged from the tab bar carry only their own type, so they pass
    /// straight through to the split container behind us.
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [.string, .fileURL, .URL]

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types,
              !Set(types).isDisjoint(with: Self.dropTypes)
        else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        // Same order and escaping as Ghostty: links as-is but escaped, files
        // as escaped paths, and plain text untouched since it may be a command.
        let content: String?
        if let url = pasteboard.string(forType: .URL) {
            content = Ghostty.Shell.escape(url)
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
                  !urls.isEmpty {
            content = urls.map { Ghostty.Shell.escape($0.path) }.joined(separator: " ")
        } else {
            content = pasteboard.string(forType: .string)
        }

        guard let content, !content.isEmpty else { return false }

        // Outside keyDown this goes to libghostty as a paste, which is how
        // Claude Code spots a dropped image path and attaches the image.
        DispatchQueue.main.async { [weak self] in
            self?.insertText(content, replacementRange: NSRange(location: 0, length: 0))
        }
        return true
    }

    // MARK: - Menu actions

    @objc func copy(_ sender: Any?) {
        performBinding("copy_to_clipboard")
    }

    @objc func paste(_ sender: Any?) {
        performBinding("paste_from_clipboard")
    }

    @objc override func selectAll(_ sender: Any?) {
        performBinding("select_all")
    }

    private func performBinding(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }
}
