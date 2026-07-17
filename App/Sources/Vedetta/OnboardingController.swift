import AppKit
import SwiftUI

/// First-launch wizard in the retro-terminal style: welcome, one-click
/// hook setup, done. Shown once (UserDefaults), reopenable from the menu.
@MainActor
final class OnboardingController {
    static let shared = OnboardingController()
    private var window: NSWindow?
    private let completedKey = "hasCompletedOnboarding"

    var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: completedKey)
    }

    func showIfNeeded() {
        guard shouldShow else { return }
        show()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(true, forKey: self.completedKey)
            self.window?.close()
        })
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct OnboardingView: View {
    var onFinish: () -> Void
    @State private var step = 0
    @State private var hooksInstalled = VedettaSetup.claudeHooksInstalled()
    @State private var installError: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)
            PixelSprite(
                pattern: PixelSprite.lookout,
                color: Theme.color(for: .waitingForInput),
                pixelSize: 7
            )
            Text("VEDETTA")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .kerning(8)
                .foregroundStyle(Theme.primaryText)

            Group {
                switch step {
                case 0:
                    VStack(spacing: 10) {
                        Text("La vedetta dei tuoi coding agent, nel notch.")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(Theme.primaryText)
                        Text("> sessioni live · approvazioni · jump al terminale _")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                    }
                case 1:
                    VStack(spacing: 12) {
                        Text("Collega Claude Code")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.primaryText)
                        Text("Aggiunge gli hook a ~/.claude/settings.json\n(backup automatico, i tuoi hook restano intatti).")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                        if hooksInstalled {
                            Label("Hook installati", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.color(for: .waitingForInput))
                        } else {
                            Button("Installa hook") {
                                do {
                                    try VedettaSetup.ensureRuntimeLayout()
                                    try VedettaSetup.installClaudeHooks()
                                    hooksInstalled = true
                                } catch {
                                    installError = error.localizedDescription
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if let installError {
                            Text(installError)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                    }
                default:
                    VStack(spacing: 10) {
                        Text("Tutto pronto.")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.primaryText)
                        Text("Gli hook valgono per le sessioni avviate da ora.\nRiavvia le sessioni in corso per vederle nel notch.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .transition(.opacity)
            .id(step)

            Spacer()

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(index == step ? Theme.primaryText : Theme.secondaryText.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()
                Button(step < 2 ? "Avanti" : "Start") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if step < 2 { step += 1 } else { onFinish() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
        }
        .frame(width: 520, height: 440)
        .background(Color.black)
        .animation(.easeInOut(duration: 0.25), value: step)
    }
}
