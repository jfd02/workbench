import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TabTermKit
import UniformTypeIdentifiers

/// Workbench ▸ Pair iPhone…: the QR code, the phones already paired, and the
/// notification key.
final class PairingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PairingWindowController()

    private let model = PairingModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pair iPhone"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PairingView(model: model))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        model.appear()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // The code is only meaningful while it's on screen.
        model.disappear()
    }
}

@MainActor
final class PairingModel: ObservableObject {
    @Published var status: RemoteServer.Status = .stopped
    @Published var link: PairingLink?
    @Published var devices: [PairedDevice] = []
    @Published var connected: Set<String> = []

    @Published var keyID = ""
    @Published var teamID = ""
    @Published var keyFile: URL?
    @Published var hasSavedKey = false
    @Published var pushMessage: String?

    private var observers: [NSObjectProtocol] = []
    private var expiryTimer: Timer?

    func appear() {
        if observers.isEmpty {
            for name in [RemoteServer.didChange, PairingStore.didChange] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
        }
        let saved = APNsConfiguration.current
        keyID = saved?.keyID ?? ""
        teamID = saved?.teamID ?? ""
        hasSavedKey = saved != nil
        keyFile = nil
        pushMessage = nil
        newCode()
    }

    func disappear() {
        PairingStore.cancelCode()
        link = nil
        expiryTimer?.invalidate()
    }

    func refresh() {
        status = RemoteServer.shared.status
        devices = PairingStore.devices
        connected = RemoteServer.shared.connectedDeviceIDs
        if link == nil || link?.hosts != hosts {
            // Tailscale came up, or its name arrived: the old code is still
            // good, but the link has to say where to find the Mac.
            if let link { self.link = makeLink(code: link.code) }
        }
        if link == nil, case .listening = status { newCode() }
    }

    private var hosts: [String] {
        guard case .listening(let address, _) = status else { return [] }
        return [address.ip] + (address.dnsName.map { [$0] } ?? [])
    }

    private func makeLink(code: String) -> PairingLink? {
        guard case .listening(_, let port) = status else { return nil }
        return PairingLink(
            name: Host.current().localizedName ?? "Mac",
            hosts: hosts,
            port: port,
            code: code
        )
    }

    func newCode() {
        status = RemoteServer.shared.status
        devices = PairingStore.devices
        connected = RemoteServer.shared.connectedDeviceIDs
        guard case .listening = status else {
            link = nil
            return
        }
        link = makeLink(code: PairingStore.makeCode())
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: PairingStore.codeLifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.link = nil }
        }
    }

    func copyLink() {
        guard let link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
    }

    func forget(_ device: PairedDevice) {
        PairingStore.forget(device.id)
        RemoteServer.shared.disconnect(deviceID: device.id)
        refresh()
    }

    func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "Choose your APNs key"
        panel.message = "The AuthKey_XXXXXXXXXX.p8 file you downloaded from the Apple Developer site."
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        keyFile = url
        // AuthKey_ABC123DEF4.p8 names its own key id.
        let name = url.deletingPathExtension().lastPathComponent
        if keyID.isEmpty, name.hasPrefix("AuthKey_") {
            keyID = String(name.dropFirst("AuthKey_".count))
        }
    }

    func savePush() {
        guard !keyID.isEmpty, !teamID.isEmpty, keyFile != nil || hasSavedKey else {
            pushMessage = "Choose the .p8 key and fill in both ids."
            return
        }
        do {
            try APNsConfiguration.save(keyFile: keyFile, keyID: keyID, teamID: teamID)
            hasSavedKey = true
            keyFile = nil
            pushMessage = "Saved. Your iPhone will be notified when an agent needs you and you're away from this Mac."
        } catch {
            pushMessage = "That file isn't a usable APNs key: \(error.localizedDescription)"
        }
    }

    func removePush() {
        APNsConfiguration.remove()
        keyID = ""
        teamID = ""
        hasSavedKey = false
        pushMessage = nil
    }
}

private struct PairingView: View {
    @ObservedObject var model: PairingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pairingSection
                .padding(24)
            Divider()
            devicesSection
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            Divider()
            pushSection
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            Spacer(minLength: 0)
        }
        .frame(width: 560)
        .frame(minHeight: 560)
    }

    // MARK: Pairing

    @ViewBuilder
    private var pairingSection: some View {
        HStack(alignment: .top, spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white)
                if let link = model.link, let image = QRCode.image(for: link.url.absoluteString) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .padding(12)
                } else {
                    Image(systemName: "qrcode")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 200, height: 200)

            VStack(alignment: .leading, spacing: 10) {
                Text("Scan with your iPhone")
                    .font(.title3.weight(.semibold))
                Text("Point the iPhone's Camera at the code and tap the Workbench link, or scan it from inside the app.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The code works once, for ten minutes, and only while this window is open.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Copy Link") { model.copyLink() }
                        .disabled(model.link == nil)
                    Button("New Code") { model.newCode() }
                        .disabled(!isListening)
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
                reachability
            }
        }
        .frame(height: 200)
    }

    private var isListening: Bool {
        if case .listening = model.status { return true }
        return false
    }

    @ViewBuilder
    private var reachability: some View {
        switch model.status {
        case .listening(let address, let port):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reachable over Tailscale")
                    Text("\(address.dnsName ?? address.ip) · \(address.ip):\(String(port))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } icon: {
                Circle().fill(Color.green).frame(width: 8, height: 8)
            }
        case .waitingForTailscale:
            Label {
                Text("Tailscale isn't running on this Mac. Workbench only lets phones in over Tailscale — start it, and this updates.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
            }
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .stopped:
            Label("Not accepting phones.", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paired iPhones")
                .font(.headline)
            if model.devices.isEmpty {
                Text("None yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.devices) { device in
                    HStack {
                        Image(systemName: "iphone")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(detail(for: device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget") { model.forget(device) }
                    }
                }
            }
            Text("While an iPhone is paired, Workbench keeps this Mac from sleeping on its own so the phone can reach it. The display still sleeps and the screen still locks.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detail(for device: PairedDevice) -> String {
        var parts: [String] = []
        if model.connected.contains(device.id) {
            parts.append("Connected")
        } else if let seen = device.lastSeenAt {
            let formatter = RelativeDateTimeFormatter()
            parts.append("Last seen \(formatter.localizedString(for: Date(timeIntervalSince1970: seen), relativeTo: Date()))")
        }
        parts.append(device.pushToken == nil ? "notifications off" : "notifications on")
        return parts.joined(separator: " · ")
    }

    // MARK: Notifications

    private var pushSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notifications")
                .font(.headline)
            Text("To be told on your iPhone when an agent needs you, give Workbench an APNs key from the team the iPhone app is signed with (Certificates, Identifiers & Profiles ▸ Keys, with Apple Push Notifications enabled).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Key")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(model.keyFile == nil ? "Choose .p8…" : model.keyFile!.lastPathComponent) {
                            model.chooseKey()
                        }
                        if model.hasSavedKey, model.keyFile == nil {
                            Text("A key is saved.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    Text("Key ID")
                        .foregroundStyle(.secondary)
                    TextField("ABC123DEF4", text: $model.keyID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                GridRow {
                    Text("Team ID")
                        .foregroundStyle(.secondary)
                    TextField("ABCDE12345", text: $model.teamID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            }

            HStack {
                Button("Save") { model.savePush() }
                    .keyboardShortcut(.defaultAction)
                if model.hasSavedKey {
                    Button("Remove Key") { model.removePush() }
                }
                Spacer()
            }
            if let message = model.pushMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// QR codes, rendered crisp at any size by drawing one pixel per module and
/// leaving the scaling to `interpolation(.none)`.
enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
