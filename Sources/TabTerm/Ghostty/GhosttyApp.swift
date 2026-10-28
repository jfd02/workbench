import AppKit
import GhosttyKit
import OSLog

/// Namespace shared with the input-translation sources vendored from Ghostty.
enum Ghostty {
    static let logger = Logger(subsystem: "com.tabterm.TabTerm", category: "ghostty")
}

// libghostty's split enums, in our own terms. Unknown values mean a newer
// libghostty grew a case we don't know about, so the action goes unhandled.

private extension SplitDirection {
    init?(_ direction: ghostty_action_split_direction_e) {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: self = .right
        case GHOSTTY_SPLIT_DIRECTION_DOWN: self = .down
        case GHOSTTY_SPLIT_DIRECTION_LEFT: self = .left
        case GHOSTTY_SPLIT_DIRECTION_UP: self = .up
        default: return nil
        }
    }
}

private extension SplitFocusTarget {
    init?(_ target: ghostty_action_goto_split_e) {
        switch target {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: self = .previous
        case GHOSTTY_GOTO_SPLIT_NEXT: self = .next
        case GHOSTTY_GOTO_SPLIT_UP: self = .up
        case GHOSTTY_GOTO_SPLIT_LEFT: self = .left
        case GHOSTTY_GOTO_SPLIT_DOWN: self = .down
        case GHOSTTY_GOTO_SPLIT_RIGHT: self = .right
        default: return nil
        }
    }
}

/// Owns the process-wide libghostty instance.
///
/// libghostty keeps a single `ghostty_app_t` per process and every terminal
/// surface is created from it. The C callbacks in `runtimeConfig` are the
/// "app runtime": the hooks libghostty calls back into for clipboard access,
/// window/tab actions, and surface lifecycle.
final class GhosttyApp {
    static let shared = GhosttyApp()

    /// Non-nil once libghostty has initialized successfully.
    private(set) var app: ghostty_app_t?

    /// The loaded configuration (from ~/.config/ghostty/config and friends).
    private(set) var config: ghostty_config_t?

    /// Set when startup failed so the UI can show something useful.
    private(set) var startupError: String?

    private init() {
        // ghostty_init has to run before any other libghostty call.
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            startupError = "ghostty_init failed"
            Ghostty.logger.critical("ghostty_init failed")
            return
        }

        // Load the user's real Ghostty config so the embedded terminal matches
        // whatever they already run in Ghostty.app.
        guard let config = ghostty_config_new() else {
            startupError = "ghostty_config_new failed"
            return
        }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        self.config = config

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in GhosttyApp.wakeup(userdata) },
            action_cb: { app, target, action in GhosttyApp.action(app, target, action) },
            read_clipboard_cb: { userdata, loc, state in
                GhosttyApp.readClipboard(userdata, loc, state)
            },
            confirm_read_clipboard_cb: { userdata, str, state, request in
                GhosttyApp.confirmReadClipboard(userdata, str, state, request)
            },
            write_clipboard_cb: { userdata, loc, content, len, confirm in
                GhosttyApp.writeClipboard(userdata, loc, content, len, confirm)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyApp.closeSurface(userdata, processAlive)
            }
        )

        guard let app = ghostty_app_new(&runtime, config) else {
            startupError = "ghostty_app_new failed"
            Ghostty.logger.critical("ghostty_app_new failed")
            return
        }
        self.app = app
        // NSApp can still be nil very early in startup.
        ghostty_app_set_focus(app, NSApp?.isActive ?? false)
    }

    /// Pump libghostty's event loop. Safe to call on the main thread only.
    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    func keyboardChanged() {
        guard let app else { return }
        ghostty_app_keyboard_changed(app)
    }

    // MARK: - Config

    /// Read one config value by key, the way Ghostty's own apprt does.
    private func configValue<T>(_ key: String, _ initial: T) -> T? {
        guard let config else { return nil }
        var value = initial
        let ok = withUnsafeMutablePointer(to: &value) { pointer in
            ghostty_config_get(config, pointer, key, UInt(key.utf8.count))
        }
        return ok ? value : nil
    }

    private func configColor(_ key: String) -> NSColor? {
        guard let color = configValue(key, ghostty_config_color_s(r: 0, g: 0, b: 0)) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1
        )
    }

    /// What an unfocused split is washed with, and how strongly — the same two
    /// settings Ghostty dims its own inactive splits with.
    ///
    /// `unfocused-split-fill` defaults to the terminal background, so unfocused
    /// panes fade towards the background rather than towards black.
    var unfocusedSplitFill: NSColor {
        configColor("unfocused-split-fill")
            ?? configColor("background")
            ?? .black
    }

    /// `shell-integration`: `detect`, `none`, or a shell to force. Sessions
    /// inject the integration themselves, so they have to honour this.
    var shellIntegrationMode: String? {
        guard let config else { return nil }
        var value: UnsafePointer<CChar>?
        let key = "shell-integration"
        let ok = ghostty_config_get(config, &value, key, UInt(key.utf8.count))
        guard ok, let value else { return nil }
        return String(cString: value)
    }

    /// 1 means no dimming; Ghostty's default is 0.7.
    var unfocusedSplitOpacity: Double {
        guard let value = configValue("unfocused-split-opacity", Double(0)), value > 0 else {
            return 0.7
        }
        return min(max(value, 0), 1)
    }

    // MARK: - C callbacks
    //
    // These are @convention(c) trampolines, so they can't be actor-isolated and
    // may arrive on libghostty's IO threads. Anything touching AppKit hops to
    // the main queue.

    /// Resolve the surface view a surface-scoped callback belongs to.
    private static func surfaceView(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Resolve the surface view for an action target.
    private static func surfaceView(from target: ghostty_target_s) -> GhosttySurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface)
        else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()

        // Wakeup can fire from any thread; tick on the main thread.
        DispatchQueue.main.async { app.tick() }
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
        guard let view = surfaceView(from: userdata) else { return }
        DispatchQueue.main.async { view.requestClose(processAlive: processAlive) }
    }

    /// Handle an action libghostty wants the runtime to perform.
    ///
    /// Returning false tells libghostty the action was not handled, which lets
    /// it fall back to its own behavior where one exists.
    private static func action(
        _ app: ghostty_app_t?,
        _ target: ghostty_target_s,
        _ action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let view = surfaceView(from: target),
                  let cTitle = action.action.set_title.title
            else { return false }
            let title = String(cString: cTitle)
            DispatchQueue.main.async { view.titleDidChange(title) }
            return true

        case GHOSTTY_ACTION_PWD:
            guard let view = surfaceView(from: target),
                  let cPwd = action.action.pwd.pwd
            else { return false }
            let pwd = String(cString: cPwd)
            DispatchQueue.main.async { view.pwdDidChange(pwd) }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let view = surfaceView(from: target) else { return false }
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { view.setMouseShape(shape) }
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            guard let view = surfaceView(from: target) else { return false }
            let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
            DispatchQueue.main.async { view.setMouseVisibility(visible) }
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            guard let view = surfaceView(from: target) else { return false }
            let size = CGSize(
                width: Double(action.action.cell_size.width),
                height: Double(action.action.cell_size.height)
            )
            DispatchQueue.main.async { view.cellSize = size }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            DispatchQueue.main.async { NSSound.beep() }
            return true

        case GHOSTTY_ACTION_NEW_TAB:
            DispatchQueue.main.async {
                MainWindowController.current?.addTab()
            }
            return true

        case GHOSTTY_ACTION_CLOSE_TAB:
            guard let view = surfaceView(from: target) else { return false }
            DispatchQueue.main.async { view.requestUserClose() }
            return true

        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let view = surfaceView(from: target),
                  let direction = SplitDirection(action.action.new_split)
            else { return false }
            DispatchQueue.main.async { view.requestSplit(direction) }
            return true

        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let view = surfaceView(from: target),
                  let focus = SplitFocusTarget(action.action.goto_split)
            else { return false }
            DispatchQueue.main.async { view.requestFocusSplit(focus) }
            return true

        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            guard let view = surfaceView(from: target) else { return false }
            DispatchQueue.main.async { view.requestEqualizeSplits() }
            return true

        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true

        default:
            // Everything else (inspector, quick terminal, new window, ...) is
            // deliberately unhandled: this app models tabs and splits only.
            return false
        }
    }

    // MARK: Clipboard

    private static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        // We report supports_selection_clipboard: false, so this shouldn't be
        // reached, but map it to the general pasteboard rather than dropping it.
        default: return nil
        }
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let view = surfaceView(from: userdata),
              let surface = view.surface,
              let pasteboard = pasteboard(location),
              let str = pasteboard.terminalStringContents()
        else { return false }

        str.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        }
        return true
    }

    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ string: UnsafePointer<CChar>?,
        _ state: UnsafeMutableRawPointer?,
        _ request: ghostty_clipboard_request_e
    ) {
        guard let view = surfaceView(from: userdata),
              let string,
              let value = String(cString: string, encoding: .utf8)
        else { return }

        DispatchQueue.main.async {
            view.confirmClipboardRead(value, state: state, request: request)
        }
    }

    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ content: UnsafePointer<ghostty_clipboard_content_s>?,
        _ len: Int,
        _ confirm: Bool
    ) {
        guard let pasteboard = pasteboard(location), let content, len > 0 else { return }

        // We only mirror text/plain onto the macOS pasteboard.
        for i in 0..<len {
            let item = content[i]
            guard let cMime = item.mime, let cData = item.data else { continue }
            guard String(cString: cMime) == "text/plain" else { continue }
            let text = String(cString: cData)

            DispatchQueue.main.async {
                if confirm {
                    let alert = NSAlert()
                    alert.messageText = "Allow clipboard write?"
                    alert.informativeText =
                        "An application in the terminal is trying to write to the clipboard:\n\n\(text)"
                    alert.addButton(withTitle: "Allow")
                    alert.addButton(withTitle: "Deny")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString(text, forType: .string)
            }
            return
        }
    }
}
