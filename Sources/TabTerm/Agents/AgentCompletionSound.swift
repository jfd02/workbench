import AppKit

/// A local completion chime, independent of phone pairing and notification permission.
final class AgentCompletionSound {
    static let shared = AgentCompletionSound()

    static let presets = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse",
        "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    static var selectedSound: String {
        AppState.string(forKey: "agentCompletionSoundName") ?? "Glass"
    }

    static var customName: String? { AppState.string(forKey: "agentCompletionSoundCustomName") }

    private static var customURL: URL? {
        AppState.string(forKey: "agentCompletionSoundCustomFile").map { URL(fileURLWithPath: $0) }
    }

    private static var playingSound: NSSound?

    static func select(_ name: String) {
        guard presets.contains(name) || (name == "custom" && customURL != nil) else { return }
        AppState.set(name, forKey: "agentCompletionSoundName")
        isEnabled = true
    }

    /// Keep our own copy so moving the original file does not break the chime.
    static func importCustomSound(from url: URL) throws {
        guard NSSound(contentsOf: url, byReference: false) != nil else {
            throw NSError(domain: "WorkbenchSound", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This file could not be read as a sound. Try an AIFF, WAV, MP3, or M4A file."
            ])
        }
        let directory = AppSupport.directory.appendingPathComponent("sounds", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: destination)
        let previous = customURL
        AppState.set(destination.path, forKey: "agentCompletionSoundCustomFile")
        AppState.set(url.lastPathComponent, forKey: "agentCompletionSoundCustomName")
        select("custom")
        if let previous, previous.deletingLastPathComponent() == directory {
            try? FileManager.default.removeItem(at: previous)
        }
    }

    static func playSelectedSound() {
        let sound: NSSound?
        if selectedSound == "custom", let url = customURL {
            sound = NSSound(contentsOf: url, byReference: false)
        } else {
            sound = NSSound(named: NSSound.Name(selectedSound))
        }
        playingSound?.stop()
        // A deleted or unreadable custom file must not make completions silent.
        playingSound = sound ?? NSSound(named: "Glass")
        playingSound?.play()
    }

    static var isEnabled: Bool {
        get { AppState.string(forKey: "agentCompletionSound") != "off" }
        set { AppState.set(newValue ? "on" : "off", forKey: "agentCompletionSound") }
    }

    private var previousReports: [String: AgentReport] = [:]
    private var observer: NSObjectProtocol?
    private let isEnabled: () -> Bool
    private let play: () -> Void

    init(
        isEnabled: @escaping () -> Bool = { AgentCompletionSound.isEnabled },
        play: @escaping () -> Void = { AgentCompletionSound.playSelectedSound() }
    ) {
        self.isEnabled = isEnabled
        self.play = play
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        guard observer == nil else { return }
        previousReports = AgentActivityStore.shared.reports
        observer = NotificationCenter.default.addObserver(
            forName: AgentActivityStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.update(AgentActivityStore.shared.reports)
        }
    }

    /// Consume reports even while muted, so enabling sound never replays old turns.
    /// Several agents finishing in one directory update need only one chime.
    func update(_ reports: [String: AgentReport]) {
        let hasCompletion = reports.contains { id, report in
            report.isNewCompletion(after: previousReports[id])
        }
        previousReports = reports
        if hasCompletion, isEnabled() { play() }
    }
}
