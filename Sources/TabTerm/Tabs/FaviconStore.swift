import AppKit
import GRDB
import ImageIO

/// Site icons for browser tabs and the new-tab list.
///
/// Icons are keyed by **host**: one icon per site, shared by every page on it
/// and by any pin that points there. Successful lookups are written to SQLite,
/// so a pinned site draws its icon the moment the launcher opens rather than
/// after a round trip.
///
/// Everything here is main-thread only. Downloads happen on a URLSession queue
/// but hand their results back to the main thread before touching the caches.
enum FaviconStore {
    /// Icons are drawn at 16pt, so 32px is enough for a Retina display.
    static let pixelSize = 32

    /// Turned off by the self-test: no step of it should touch the network.
    static var networkEnabled = true

    private static var memory: [String: NSImage] = [:]
    /// Hosts we looked for and didn't find, so a list rebuild doesn't retry
    /// them all over again. Session-scoped: a relaunch gives them another go.
    private static var missing: Set<String> = []
    /// Callbacks waiting on a fetch already in flight for the same host.
    private static var waiting: [String: [(NSImage?) -> Void]] = [:]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    // MARK: - Lookup

    /// The icon we already have for this URL's host, without going near the
    /// network. Nil means "not fetched yet", not "this site has none".
    static func cached(for url: URL) -> NSImage? {
        guard let host = host(of: url) else { return nil }
        if let image = memory[host] { return image }
        guard let data = storedData(host: host), let image = decode(data) else { return nil }
        memory[host] = image
        return image
    }

    /// Find the icon for a page, fetching it the first time we see the host.
    ///
    /// - Parameter hints: absolute hrefs from the page's `<link rel="icon">`
    ///   tags, when the caller has a loaded page to ask. Tried before the
    ///   conventional `/favicon.ico`.
    /// - Note: The completion runs on the main thread, and runs immediately
    ///   when the icon is already cached.
    static func icon(for url: URL, hints: [URL] = [], completion: @escaping (NSImage?) -> Void) {
        if let image = cached(for: url) { return completion(image) }

        guard let host = host(of: url), networkEnabled, !missing.contains(host) else {
            return completion(nil)
        }

        // Fold in behind a fetch that's already running for this host.
        if waiting[host] != nil {
            waiting[host]?.append(completion)
            return
        }
        waiting[host] = [completion]

        fetch(candidates(for: url, hints: hints), pageURL: url, triedPage: !hints.isEmpty) { data in
            let image = data.flatMap(decode)
            if let data, let image {
                memory[host] = image
                store(data, host: host)
            } else {
                missing.insert(host)
            }
            let callbacks = waiting.removeValue(forKey: host) ?? []
            for callback in callbacks { callback(image) }
        }
    }

    static func host(of url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    // MARK: - Fetching

    /// Where to look, in order: what the page told us, then the conventional
    /// location every browser tries.
    private static func candidates(for url: URL, hints: [URL]) -> [URL] {
        var urls = hints.filter { $0.scheme == "http" || $0.scheme == "https" }
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.path = "/favicon.ico"
            components.query = nil
            components.fragment = nil
            if let fallback = components.url { urls.append(fallback) }
        }

        // Keep it bounded: a site that needs five requests to name its icon
        // isn't worth the traffic.
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }.prefix(4).map { $0 }
    }

    /// Try each candidate in turn, then fall back to reading the page's HTML
    /// for a `<link rel="icon">` we didn't already know about.
    private static func fetch(
        _ candidates: [URL],
        pageURL: URL,
        triedPage: Bool,
        completion: @escaping (Data?) -> Void
    ) {
        var remaining = candidates

        func attempt() {
            guard !remaining.isEmpty else {
                guard !triedPage else { return completion(nil) }
                return fetchFromPage(pageURL, completion: completion)
            }

            let url = remaining.removeFirst()
            session.dataTask(with: url) { data, response, _ in
                let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) }
                    ?? false
                // Normalize on this thread — it's the expensive part, and the
                // result is plain Data.
                let normalized = (ok ? data : nil).flatMap(normalize)
                DispatchQueue.main.async {
                    if let normalized { return completion(normalized) }
                    attempt()
                }
            }.resume()
        }

        attempt()
    }

    /// Read the page itself and try whatever icons its `<head>` declares. Only
    /// reached when `/favicon.ico` came back empty.
    private static func fetchFromPage(_ pageURL: URL, completion: @escaping (Data?) -> Void) {
        session.dataTask(with: pageURL) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) }
                ?? false
            let base = (response?.url ?? pageURL)
            let hrefs = (ok ? data : nil).map { iconLinks(inHTML: $0, base: base) } ?? []

            DispatchQueue.main.async {
                guard !hrefs.isEmpty else { return completion(nil) }
                fetch(hrefs, pageURL: pageURL, triedPage: true, completion: completion)
            }
        }.resume()
    }

    /// Absolute icon URLs declared by a page's `<link rel="...icon...">` tags.
    ///
    /// A regular expression rather than a parser: we're reading one attribute
    /// out of a handful of tags, and a wrong guess just means the next
    /// candidate gets tried.
    static func iconLinks(inHTML data: Data, base: URL) -> [URL] {
        // Icons are declared in <head>, so there's no reason to scan a whole
        // page of markup.
        let prefix = data.prefix(256 * 1024)
        guard let html = String(data: prefix, encoding: .utf8)
            ?? String(data: prefix, encoding: .isoLatin1)
        else { return [] }

        let tags = matches(of: "<link\\b[^>]*>", in: html)
        var urls: [URL] = []
        for tag in tags {
            guard let rel = attribute("rel", in: tag)?.lowercased(),
                  rel.split(separator: " ").contains(where: {
                      $0 == "icon" || $0 == "shortcut" || $0 == "apple-touch-icon"
                  }),
                  let href = attribute("href", in: tag),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL
            else { continue }
            urls.append(url)
        }
        return urls
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
        else { return nil }

        for group in 2...4 {
            guard let range = Range(match.range(at: group), in: tag) else { continue }
            let value = String(tag[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Images

    /// Turn whatever the site served — .ico, .png, .svg — into a 32×32 PNG.
    ///
    /// Storing one format at one size keeps the cache small and means the tab
    /// bar never scales a 512px image down on every redraw.
    static func normalize(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        if let cgImage = largestImage(in: data) ?? rasterizedImage(from: data) {
            return png(from: cgImage)
        }
        return nil
    }

    /// The biggest frame in the file. An .ico usually holds several sizes and
    /// the first one is not always the best.
    private static func largestImage(in data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var best: CGImage?
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            if best == nil || image.width > best!.width { best = image }
        }
        return best
    }

    /// ImageIO can't read SVG; NSImage can, so anything it declines is not an
    /// image we can use.
    private static func rasterizedImage(from data: Data) -> CGImage? {
        guard let image = NSImage(data: data), image.size.width > 0 else { return nil }
        var rect = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func png(from cgImage: CGImage) -> Data? {
        let size = pixelSize
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = context.makeImage() else { return nil }

        let rep = NSBitmapImageRep(cgImage: scaled)
        return rep.representation(using: .png, properties: [:])
    }

    /// PNG bytes as an image sized in points, so it draws crisply at 16pt.
    static func decode(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.isValid else { return nil }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = false
        return image
    }

    // MARK: - Storage

    private struct Row: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "favicon"
        var host: String
        var data: Data
        var fetchedAt: Double
    }

    private static func storedData(host: String) -> Data? {
        try? AppDatabase.shared.queue.read { db in
            try Row.filter(Column("host") == host).fetchOne(db)?.data
        }
    }

    private static func store(_ data: Data, host: String) {
        try? AppDatabase.shared.queue.write { db in
            try Row(host: host, data: data, fetchedAt: Date().timeIntervalSince1970).upsert(db)
        }
    }

    /// Drop everything we've cached. Only the self-test needs this.
    static func resetForTesting() {
        memory = [:]
        missing = []
        waiting = [:]
    }

    /// Put an icon in the store as a fetch would, without a network. The
    /// memory copy is dropped so the next lookup has to come back out of
    /// SQLite, which is the path a relaunch takes.
    @discardableResult
    static func storeForTesting(_ data: Data, for url: URL) -> Bool {
        guard let host = host(of: url), let normalized = normalize(data) else { return false }
        store(normalized, host: host)
        memory.removeValue(forKey: host)
        missing.remove(host)
        return true
    }
}
