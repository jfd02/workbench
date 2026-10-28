import SwiftUI

/// Where to write a message to the terminal: a real text field, with
/// autocorrect and dictation, sent as a whole with Enter pressed after it.
/// Typing a paragraph for Claude a key at a time into a terminal is miserable;
/// this is the reason to use the phone at all.
struct ComposerBar: View {
    @Binding var text: String
    let isClaude: Bool
    var focused: FocusState<Bool>.Binding
    let send: (String) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(isClaude ? "Message Claude" : "Run a command", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .font(isClaude ? .body : .system(.body, design: .monospaced))
                .textInputAutocapitalization(isClaude ? .sentences : .never)
                .autocorrectionDisabled(!isClaude)
                .focused(focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(TerminalTheme.key, in: RoundedRectangle(cornerRadius: 19, style: .continuous))

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, canSend ? TerminalTheme.claude : Color.gray.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(TerminalTheme.chrome)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let message = text.trimmingCharacters(in: .newlines)
        guard canSend else { return }
        send(message)
        text = ""
    }
}
