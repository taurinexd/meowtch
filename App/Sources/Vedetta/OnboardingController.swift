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
    @State private var claudeInstalled = VedettaSetup.claudeHooksInstalled()
    @State private var codexInstalled = VedettaSetup.codexHooksInstalled()
    @State private var claudeError: String?
    @State private var codexError: String?

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
                        Text("Collega i coding agent")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.primaryText)
                        Text("Aggiunge gli hook di Claude Code e Codex\n(backup automatico; Codex chiederà conferma in /hooks).")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                        agentHookRow(
                            name: "Claude Code",
                            installed: claudeInstalled,
                            error: claudeError
                        ) {
                            do {
                                try VedettaSetup.ensureRuntimeLayout()
                                try VedettaSetup.installClaudeHooks()
                                claudeInstalled = true
                                claudeError = nil
                            } catch {
                                claudeError = error.localizedDescription
                            }
                        }
                        agentHookRow(
                            name: "Codex (\(VedettaSetup.codexHomes.count) config)",
                            installed: codexInstalled,
                            error: codexError
                        ) {
                            do {
                                try VedettaSetup.ensureRuntimeLayout()
                                try VedettaSetup.installCodexHooks()
                                codexInstalled = VedettaSetup.codexHooksInstalled()
                                codexError = VedettaSetup.codexHomes.contains {
                                    VedettaSetup.codexHooksExplicitlyDisabled(at: $0)
                                } ? "Hooks disabilitati esplicitamente in almeno un config.toml." : nil
                            } catch {
                                codexError = error.localizedDescription
                            }
                        }
                        Button("Aggiungi config Codex…") {
                            let picker = NSOpenPanel()
                            picker.canChooseDirectories = true
                            picker.canChooseFiles = false
                            picker.allowsMultipleSelection = false
                            guard picker.runModal() == .OK, let url = picker.url else { return }
                            let codexHome = VedettaSetup.registerCodexHome(url.path)
                            do {
                                try VedettaSetup.installCodexHooks(at: codexHome)
                                codexInstalled = VedettaSetup.codexHooksInstalled()
                                codexError = VedettaSetup.codexHooksExplicitlyDisabled(at: codexHome)
                                    ? "Hooks disabilitati in \(codexHome.configPath); file non modificato."
                                    : nil
                                NotificationCenter.default.post(
                                    name: .vedettaCodexHomesChanged,
                                    object: nil
                                )
                            } catch {
                                codexError = error.localizedDescription
                            }
                        }
                        .buttonStyle(.bordered)
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

    @ViewBuilder
    private func agentHookRow(
        name: String,
        installed: Bool,
        error: String?,
        install: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                if installed {
                    Label("Installato", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.color(for: .waitingForInput))
                } else {
                    Button("Installa", action: install)
                        .buttonStyle(.bordered)
                }
            }
            if let error {
                Text(error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: 360)
    }
}
