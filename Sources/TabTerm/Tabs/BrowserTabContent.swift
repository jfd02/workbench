import AppKit
import WebKit

/// A tab holding an embedded web view with a minimal navigation bar.
final class BrowserTabContent: NSObject, TabContent, WKNavigationDelegate, NSTextFieldDelegate {
    let kind: TabKind = .browser
    private(set) var title: String = "New Tab"
    private(set) var icon: NSImage?

    var onTitleChange: ((String) -> Void)?
    var onIconChange: ((NSImage?) -> Void)?
    var onRequestClose: ((Bool) -> Void)?

    /// The host `icon` belongs to. Navigating within a site keeps the icon;
    /// navigating away drops it rather than mislabelling the new page.
    private var iconHost: String?

    /// Closing a page loses nothing you can't get back by reopening it.
    var isDisposable: Bool { true }

    var closeConfirmationDetail: String {
        if let host = webView.url?.host {
            return "You'll leave \(host)."
        }
        return "This page will be closed."
    }

    private let container = NSView()
    private let webView: WKWebView
    private let urlField = NSTextField()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let pinButton = NSButton()
    private let progressBar = NSProgressIndicator()

    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?

    var view: NSView { container }

    /// Where a browser tab goes when no URL was specified.
    static let defaultHome = URL(string: "https://www.google.com")!

    init(initialURL: URL?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        buildLayout()
        observeWebView()

        webView.load(URLRequest(url: initialURL ?? Self.defaultHome))
    }

    deinit {
        titleObservation?.invalidate()
        urlObservation?.invalidate()
        loadingObservation?.invalidate()
    }

    // MARK: - Layout

    private func buildLayout() {
        container.translatesAutoresizingMaskIntoConstraints = false

        configureNavButton(backButton, symbol: "chevron.left", fallback: "<", action: #selector(goBack))
        configureNavButton(forwardButton, symbol: "chevron.right", fallback: ">", action: #selector(goForward))
        configureNavButton(reloadButton, symbol: "arrow.clockwise", fallback: "⟳", action: #selector(reload))
        backButton.isEnabled = false
        forwardButton.isEnabled = false

        urlField.placeholderString = "Search or enter address"
        urlField.font = .systemFont(ofSize: 13)
        urlField.bezelStyle = .roundedBezel
        urlField.focusRingType = .none
        urlField.delegate = self
        urlField.target = self
        urlField.action = #selector(urlFieldSubmitted)
        urlField.translatesAutoresizingMaskIntoConstraints = false

        configureNavButton(pinButton, symbol: "pin", fallback: "Pin", action: #selector(togglePin))
        pinButton.toolTip = "Pin this page to the new-tab list"
        pinButton.setAccessibilityIdentifier("pinButton")
        pinButton.setAccessibilityLabel("Pin this page")

        let bar = NSStackView(views: [backButton, forwardButton, reloadButton, urlField, pinButton])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.setHuggingPriority(.defaultLow, for: .horizontal)

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        webView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(bar)
        container.addSubview(progressBar)
        container.addSubview(separator)
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            progressBar.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: -2),
            progressBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            separator.topAnchor.constraint(equalTo: bar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            webView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func configureNavButton(
        _ button: NSButton,
        symbol: String,
        fallback: String,
        action: Selector
    ) {
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            button.image = image
            button.title = ""
        } else {
            button.title = fallback
        }
        button.bezelStyle = .texturedRounded
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: - Observation

    private func observeWebView() {
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            self?.updateTitle()
        }
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            guard let self else { return }
            if let url = webView.url, !self.urlFieldIsEditing {
                self.urlField.stringValue = url.absoluteString
            }
            self.updateNavButtons()
            self.hostDidChange()
        }
        loadingObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            guard let self else { return }
            let progress = webView.estimatedProgress
            self.progressBar.doubleValue = progress
            self.progressBar.isHidden = !webView.isLoading || progress >= 1.0
        }
    }

    private var urlFieldIsEditing: Bool {
        urlField.currentEditor() != nil
    }

    private func updateTitle() {
        let newTitle: String
        if let pageTitle = webView.title, !pageTitle.isEmpty {
            newTitle = pageTitle
        } else if let host = webView.url?.host {
            newTitle = host
        } else {
            newTitle = "New Tab"
        }
        guard newTitle != title else { return }
        title = newTitle
        onTitleChange?(newTitle)
    }

    // MARK: - Favicon

    /// Icons a page declares in its head, in the order it lists them.
    private static let iconLinksScript = """
    Array.from(document.querySelectorAll(
        'link[rel~="icon" i], link[rel~="shortcut" i], link[rel~="apple-touch-icon" i]'
    )).map(element => element.href)
    """

    /// Called as the URL changes: show the icon we already have for the new
    /// host, or nothing until the page settles. No fetching here — a load in
    /// progress can still be redirected somewhere else.
    private func hostDidChange() {
        guard let url = webView.url, let host = FaviconStore.host(of: url) else {
            return setIcon(nil, host: nil)
        }
        guard host != iconHost else { return }
        setIcon(FaviconStore.cached(for: url), host: host)
    }

    /// Ask the loaded page which icons it declares, then let the store fetch
    /// one — falling back to /favicon.ico for the pages that declare none.
    private func resolveFavicon() {
        guard let url = webView.url, let host = FaviconStore.host(of: url) else { return }
        if icon != nil, host == iconHost { return }

        webView.evaluateJavaScript(Self.iconLinksScript) { [weak self] result, _ in
            guard let self else { return }
            let hints = (result as? [String] ?? []).compactMap { URL(string: $0) }
            FaviconStore.icon(for: url, hints: hints) { [weak self] image in
                guard let self, let image, self.iconHost == host else { return }
                self.setIcon(image, host: host)
            }
        }
    }

    private func setIcon(_ image: NSImage?, host: String?) {
        iconHost = host
        guard image !== icon else { return }
        icon = image
        onIconChange?(image)
    }

    private func updateNavButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        updatePinButton()
    }

    private func updatePinButton() {
        guard let url = webView.url else {
            pinButton.isEnabled = false
            return
        }
        pinButton.isEnabled = true

        let pinned = PinnedSites.isPinned(url)
        pinButton.image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: pinned ? "Unpin" : "Pin"
        )
        pinButton.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
        pinButton.toolTip = pinned
            ? "Remove from the new-tab list"
            : "Pin this page to the new-tab list"
    }

    /// The page currently shown, if any. Exposed for the self-test.
    var currentURL: URL? { webView.url }

    @objc func togglePin() {
        guard let url = webView.url else { return }
        if PinnedSites.isPinned(url) {
            PinnedSites.remove(url)
        } else {
            PinnedSites.add(title: title, url: url)
        }
        updatePinButton()
    }

    // MARK: - Actions

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reload() { webView.reload() }

    @objc private func urlFieldSubmitted() {
        let text = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = BrowserTabContent.normalizeURL(text) else { return }
        webView.load(URLRequest(url: url))
        // Hand focus back to the page so typing goes to the site.
        container.window?.makeFirstResponder(webView)
    }

    /// Turn user input into a URL: a bare host becomes https://, anything that
    /// isn't URL-ish becomes a web search.
    static func normalizeURL(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return address(text) ?? searchURL(for: text)
    }

    /// The address this text names, or nil when it doesn't name one.
    ///
    /// Separate from `normalizeURL` because a search is the right answer in
    /// the address bar and the wrong one when saving a site to the new-tab
    /// list: "figma" should be rejected there, not pinned to a search result.
    static func address(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), url.scheme != nil, url.host != nil {
            return url
        }

        // Looks like a domain or localhost[:port] with no scheme.
        let firstComponent = text.split(separator: "/").first.map(String.init) ?? text
        let hostPart = firstComponent.split(separator: ":").first.map(String.init) ?? firstComponent
        let looksLikeHost =
            (hostPart.contains(".") && !hostPart.hasSuffix(".") && !text.contains(" "))
            || hostPart == "localhost"
        if looksLikeHost, let url = URL(string: "https://\(text)"), url.host != nil {
            return url
        }

        return nil
    }

    private static func searchURL(for text: String) -> URL? {
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }

    // MARK: - TabContent

    func takeFocus() {
        container.window?.makeFirstResponder(webView)
    }

    /// A web view has nothing to change: it renders the same either way.
    func setFocused(_ focused: Bool) {}

    func setVisible(_ visible: Bool) {}

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateTitle()
        updateNavButtons()
        resolveFavicon()
        progressBar.isHidden = true
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        progressBar.isHidden = true
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        progressBar.isHidden = true
        // Ignore cancellations, which happen on normal redirects/stop.
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }

        let html = """
        <html><head><meta name="color-scheme" content="light dark"></head>
        <body style="font-family:-apple-system;display:flex;align-items:center;
        justify-content:center;height:90vh;margin:0;color:#888;text-align:center">
        <div><h2 style="font-weight:600">Can't open this page</h2>
        <p>\(nsError.localizedDescription)</p></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}
