import SwiftUI
import TabTermKit

/// The keys a phone keyboard doesn't have, always in reach: under the terminal
/// when reading, above the keyboard when typing.
struct QuickKeysBar: View {
    let keyboardVisible: Bool
    let send: (TerminalKey) -> Void
    let toggleKeyboard: () -> Void

    private let feedback = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    key("esc", .escape)
                    key(symbol: "return", .enter, label: "Return")
                    key("tab", .tab)
                    key("⇧tab", .backTab)
                    divider
                    key(symbol: "arrow.up", .up, label: "Up")
                    key(symbol: "arrow.down", .down, label: "Down")
                    key(symbol: "arrow.left", .left, label: "Left")
                    key(symbol: "arrow.right", .right, label: "Right")
                    divider
                    key("^C", .ctrlC)
                    moreKeys
                }
                .padding(.horizontal, 10)
            }

            Rectangle()
                .fill(TerminalTheme.hairline)
                .frame(width: 1, height: 26)

            Button(action: toggleKeyboard) {
                Image(systemName: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 48, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(keyboardVisible ? "Hide keyboard" : "Type into the terminal")
        }
        .frame(height: 46)
        .background(TerminalTheme.chrome)
        .overlay(alignment: .top) {
            Rectangle().fill(TerminalTheme.hairline).frame(height: 1)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(TerminalTheme.hairline)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 2)
    }

    private func key(_ text: String, _ key: TerminalKey) -> some View {
        KeyButton(action: { press(key) }) {
            Text(text)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
        }
        .accessibilityLabel(text)
    }

    private func key(symbol: String, _ key: TerminalKey, label: String) -> some View {
        KeyButton(action: { press(key) }) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
        }
        .accessibilityLabel(label)
    }

    private var moreKeys: some View {
        Menu {
            Section("Control") {
                Button("⌃D  End of input") { press(.ctrlD) }
                Button("⌃Z  Suspend") { press(.ctrlZ) }
                Button("⌃L  Clear screen") { press(.ctrlL) }
                Button("⌃R  Search history") { press(.ctrlR) }
            }
            Section("Move") {
                Button("Home") { press(.home) }
                Button("End") { press(.end) }
                Button("Page Up") { press(.pageUp) }
                Button("Page Down") { press(.pageDown) }
            }
        } label: {
            Text("⌃…")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .frame(minWidth: 40, minHeight: 32)
                .padding(.horizontal, 4)
                .background(TerminalTheme.key, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("More keys")
    }

    private func press(_ key: TerminalKey) {
        feedback.impactOccurred()
        send(key)
    }
}

/// A key cap: dark, rounded, lighter while held.
private struct KeyButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .frame(minWidth: 40, minHeight: 32)
                .padding(.horizontal, 4)
        }
        .buttonStyle(KeyCapStyle())
    }
}

private struct KeyCapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                configuration.isPressed ? TerminalTheme.keyPressed : TerminalTheme.key,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }
}
