import SwiftUI
import VedettaKit

/// The CALL surface for now: start/stop listening, why it cannot, and the
/// last lines of the conversation (client in blue, Matteo in green, the
/// line still being spoken in italics). Suggestions come in a later step.
struct CallListenView: View {
    @ObservedObject private var session = CallSession.shared
    private let clientColor = Color(red: 0.36, green: 0.61, blue: 1.0)
    private let meColor = Color(red: 0.42, green: 0.78, blue: 0.48)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if session.isListening {
                    Circle().fill(Color(red: 0.92, green: 0.34, blue: 0.34)).frame(width: 7, height: 7)
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
            if session.isListening, !session.headphones {
                notice("Not on headphones: the meeting can leak into the microphone.", color: Theme.claudeOrange)
            }
            if let problem = session.problem {
                notice(problem.message, color: Color(red: 0.92, green: 0.34, blue: 0.34))
            }
            let lines = session.transcript.recent(6)
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
        .padding(.leading, 18)
        .padding(.trailing, 15)
    }

    private func notice(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
