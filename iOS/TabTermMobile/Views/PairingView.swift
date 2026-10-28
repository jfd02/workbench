import SwiftUI
import TabTermKit
import VisionKit

/// First run: connect this phone to Workbench on a Mac by scanning the code the
/// Mac shows. The code is a `tabterm://pair` link, so the Camera app works
/// too; pasting the link is the fallback when neither camera will do.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var scanning = false
    @State private var pasting = false
    @State private var pastedLink = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 18) {
                Image("Mark")
                    .resizable()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 6)

                Text("Your Mac's terminals,\non your iPhone")
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("Pick up any Workbench terminal where you left it — answer Claude, check a build, send a message — and put it down again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, text: "Install Tailscale on this iPhone and your Mac, signed in to the same account.")
                Step(number: 2, text: "On the Mac, choose **Workbench ▸ Pair iPhone…** to show a pairing code.")
                Step(number: 3, text: "Scan it here, or with the Camera app.")
            }
            .padding(18)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Spacer(minLength: 24)

            if let error = model.pairingError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.bottom, 14)
            }

            VStack(spacing: 10) {
                Button {
                    model.pairingError = nil
                    scanning = true
                } label: {
                    HStack {
                        if model.isPairing {
                            ProgressView().tint(.black)
                            Text("Pairing…")
                        } else {
                            Image(systemName: "qrcode.viewfinder")
                            Text("Scan Pairing Code")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .disabled(model.isPairing || !QRScannerView.isAvailable)

                if !QRScannerView.isAvailable {
                    Text("No camera available here. Scan the code with another device's Camera app, or paste the link.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("Paste Pairing Link") {
                    pastedLink = UIPasteboard.general.string ?? ""
                    pasting = true
                }
                .font(.subheadline)
                .disabled(model.isPairing)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: TerminalTheme.background).ignoresSafeArea())
        .sheet(isPresented: $scanning) {
            ScannerSheet { link in
                scanning = false
                model.pair(with: link)
            }
        }
        .alert("Paste Pairing Link", isPresented: $pasting) {
            TextField("tabterm://pair?…", text: $pastedLink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Pair") {
                if let url = URL(string: pastedLink.trimmingCharacters(in: .whitespacesAndNewlines)),
                   let link = PairingLink(url: url) {
                    model.pair(with: link)
                } else {
                    model.pairingError = "That isn't a Workbench pairing link."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copy the link under the code on your Mac, then paste it here.")
        }
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold).monospacedDigit())
                .frame(width: 22, height: 22)
                .background(TerminalTheme.claude.opacity(0.9), in: Circle())
                .foregroundStyle(.black)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The camera, looking for a pairing code.
private struct ScannerSheet: View {
    let found: (PairingLink) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QRScannerView { payload in
                guard let url = URL(string: payload), let link = PairingLink(url: url) else { return false }
                found(link)
                return true
            }
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                Text("Point at the code on your Mac")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 40)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
