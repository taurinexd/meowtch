import AppKit
import SwiftUI
import VedettaKit

/// The CALL surface: start/stop listening, the quick suggestion (mockup 2a:
/// «They asked» / «You can say»), the consent switch, the client folder and
/// the last lines of the conversation (client in blue, Matteo in green, the
/// line still being spoken in italics).
struct CallListenView: View {
    @ObservedObject private var session = CallSession.shared
    @ObservedObject private var copilot = CallCopilot.shared
    @ObservedObject private var usage = UsageModel.shared
    @AppStorage(SettingsKey.callSuggestionsEnabled) private var suggestionsOn = false
    @AppStorage(SettingsKey.callClientFolder) private var clientFolder = ""
    private let clientColor = Color(red: 0.36, green: 0.61, blue: 1.0)
    private let meColor = Color(red: 0.42, green: 0.78, blue: 0.48)
    private let errorColor = Color(red: 0.92, green: 0.34, blue: 0.34)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if session.isListening, !session.headphones {
                notice("Not on headphones: the meeting can leak into the microphone.", color: Theme.claudeOrange)
            }
            if let problem = session.problem {
                notice(problem.message, color: errorColor)
            }
            if suggestionsOn {
                if let question = copilot.question {
                    suggestionCard(question)
                }
                if let problem = copilot.engineProblem {
                    notice(problem, color: errorColor)
                }
            } else {
                consentRow
            }
            settingsRow
            transcript
            if suggestionsOn, session.isListening {
                footer
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 15)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if session.isListening {
                Circle().fill(errorColor).frame(width: 7, height: 7)
                Text("Listening")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
            }
            Spacer(minLength: 0)
            Button {
                session.isListening ? session.stop() : session.start()
            } label: {
                Text(session.isListening ? "Stop" : "Start listening")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(session.isListening ? Theme.primaryText : .black)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(session.isListening ? Color.white.opacity(0.12) : Theme.claudeOrange)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func suggestionCard(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                label("They asked", color: Theme.secondaryText)
                Text("«\(question)»")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primaryText.opacity(0.85))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                label("You can say", color: Theme.claudeOrange)
                Text(copilot.answer + (copilot.isStreaming ? " ▍" : ""))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var consentRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Suggestions are off. When on, the call transcript is sent to Claude (Anthropic) to suggest answers.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            pillButton("Turn on", filled: true) { suggestionsOn = true }
        }
    }

    private var settingsRow: some View {
        HStack(spacing: 8) {
            Text("Client")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondaryText)
            Text(clientFolder.isEmpty ? "none" : (clientFolder as NSString).lastPathComponent)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.primaryText.opacity(0.85))
                .lineLimit(1)
            pillButton("Choose…", filled: false) { chooseClientFolder() }
            Spacer(minLength: 0)
            if suggestionsOn {
                pillButton("Turn off suggestions", filled: false) { suggestionsOn = false }
            }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        let lines = session.transcript.recent(4)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(line.speaker == .client ? "Client" : "You")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(line.speaker == .client ? clientColor : meColor)
                            .frame(width: 38, alignment: .leading)
                        Text(line.text)
                            .font(.system(size: 11.5))
                            .italic(!line.isFinal)
                            .foregroundStyle(line.isFinal ? Theme.primaryText.opacity(0.9) : Theme.secondaryText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if session.isListening, session.problem == nil {
            Text("Waiting for someone to speak…")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("⌥ Space")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text("answer now")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 0)
            Text(meter)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    /// While streaming: seconds and tokens (Claude Code's spinner form);
    /// then the call's cost and the 5h window.
    private var meter: String {
        if copilot.isStreaming {
            return String(format: "%.1fs · ↓ %d tokens", copilot.elapsed, copilot.outputTokens)
        }
        let cost = copilot.callCostUSD
        var parts = [cost > 0 && cost < 0.01 ? "call <$0.01" : String(format: "call $%.2f", cost)]
        if let fiveHour = usage.fiveHour { parts.append("5h \(fiveHour.percent)%") }
        return parts.joined(separator: " · ")
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(color)
    }

    private func pillButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(filled ? .black : Theme.primaryText)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(filled ? Theme.claudeOrange : Color.white.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func notice(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Read-only choice of the folder whose `.meowtch/client.md` feeds the
    /// suggestions; nothing is written there.
    private func chooseClientFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Folder of the client: its .meowtch/client.md feeds the suggestions."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            clientFolder = url.path
        }
    }
}
