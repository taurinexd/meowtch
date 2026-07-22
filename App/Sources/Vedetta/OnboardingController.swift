import AppKit
import ServiceManagement
import SwiftUI

/// First-launch wizard in the retro-terminal style: welcome, permissions,
/// agents, the shareable sighting card, all-set. Shown once (UserDefaults),
/// reopenable from Settings → About.
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
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

// MARK: - Wizard

private enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, agents, allSet

    /// Each step borrows the state color of what it is about: green for
    /// the watch itself, orange for the permission decision, blue for the
    /// working agents, green again to sail.
    var accent: Color {
        switch self {
        case .welcome, .allSet: Theme.color(for: .waitingForInput)
        case .permissions: Theme.color(for: .needsApproval)
        case .agents: Theme.color(for: .running)
        }
    }
}

private struct OnboardingView: View {
    var onFinish: () -> Void
    @State private var step: OnboardingStep = .welcome

    // Live setup state, re-read whenever the relevant step appears.
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var claudeInstalled = VedettaSetup.claudeHooksInstalled()
    @State private var codexInstalled = VedettaSetup.codexHooksInstalled()
    @State private var extensionInstalled = JumpService.vsCodeExtensionInstalled()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var setupError: String?

    var body: some View {
        ZStack {
            Color.black
            StarfieldView(driftSpeed: 2.0, starCount: 90)

            VStack(spacing: 0) {
                Spacer(minLength: 30)
                content
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                    .id(step)
                Spacer(minLength: 16)
                footer
            }
        }
        .frame(width: 560, height: 620)
        .animation(.easeInOut(duration: 0.3), value: step)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .permissions: permissions
        case .agents: agents
        case .allSet: allSet
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            PixelSprite(
                pattern: PixelSprite.lookout,
                color: step.accent,
                pixelSize: 9
            )
            Text("VEDETTA")
                .font(.system(size: 26, weight: .black, design: .monospaced))
                .kerning(10)
                .foregroundStyle(Theme.primaryText)
            Text("Your coding agents, watched from the notch.")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
            TypewriterText(
                text: "> live sessions · approvals · questions · jump to terminal",
                color: Theme.secondaryText
            )
        }
    }

    private var permissions: some View {
        VStack(spacing: 18) {
            stepHeader(
                "PERMISSIONS",
                prompt: "> the lookout needs to raise the right window"
            )
            Text("Accessibility lets Vedetta bring the exact terminal window\nto the front when you jump to a session.")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            setupRow(
                title: "Accessibility",
                ok: axTrusted,
                okLabel: "granted",
                actionLabel: "Grant…"
            ) {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                axTrusted = AXIsProcessTrusted()
            }
            Text("You can grant it later — everything else works without it.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondaryText.opacity(0.7))
        }
        .onAppear { axTrusted = AXIsProcessTrusted() }
    }

    private var agents: some View {
        VStack(spacing: 14) {
            stepHeader(
                "CONNECT AGENTS",
                prompt: "> hooking into the agents found on this Mac"
            )
            VStack(spacing: 10) {
                setupRow(
                    title: agentLabel(
                        "Claude Code",
                        detected: FileManager.default.fileExists(
                            atPath: NSHomeDirectory() + "/.claude"
                        )
                    ),
                    ok: claudeInstalled,
                    okLabel: "hooked",
                    actionLabel: "Hook"
                ) {
                    perform {
                        try VedettaSetup.ensureRuntimeLayout()
                        try VedettaSetup.installClaudeHooks()
                        claudeInstalled = VedettaSetup.claudeHooksInstalled()
                    }
                }
                setupRow(
                    title: agentLabel(
                        "Codex",
                        detected: VedettaSetup.codexHomes.contains(where: \.isAvailable)
                    ),
                    ok: codexInstalled,
                    okLabel: "hooked",
                    actionLabel: "Hook"
                ) {
                    perform {
                        try VedettaSetup.ensureRuntimeLayout()
                        try VedettaSetup.installCodexHooks()
                        codexInstalled = VedettaSetup.codexHooksInstalled()
                    }
                }
                setupRow(
                    title: "VS Code jump extension",
                    ok: extensionInstalled,
                    okLabel: "installed",
                    actionLabel: "Install"
                ) {
                    JumpService.installVSCodeExtension()
                    extensionInstalled = JumpService.vsCodeExtensionInstalled()
                }
                HStack {
                    Text("Launch at Login")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.primaryText)
                    Spacer()
                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, enabled in
                            try? enabled
                                ? SMAppService.mainApp.register()
                                : SMAppService.mainApp.unregister()
                        }
                }
                .frame(maxWidth: 400)
            }
            if let setupError {
                Text(setupError)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
            }
            Text("Hooks merge additively with a timestamped backup.\nCodex asks you to trust them with /hooks on first use.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondaryText.opacity(0.7))
                .multilineTextAlignment(.center)
        }
    }

    private var allSet: some View {
        VStack(spacing: 18) {
            PixelSprite(
                pattern: PixelSprite.lookout,
                color: step.accent,
                pixelSize: 7
            )
            stepHeader("ALL SET", prompt: "> hooks armed for new sessions")
            Text("Hooks apply to sessions started from now on.\nRestart any running agent to bring it aboard,\nthen hover the notch.")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Shared pieces

    private func stepHeader(_ title: String, prompt: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .black, design: .monospaced))
                .kerning(5)
                .foregroundStyle(step.accent)
            TypewriterText(text: prompt, color: Theme.secondaryText)
        }
    }

    private func agentLabel(_ name: String, detected: Bool) -> String {
        detected ? name : "\(name) (not detected)"
    }

    private func setupRow(
        title: String,
        ok: Bool,
        okLabel: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
            Spacer()
            if ok {
                Label(okLabel, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.color(for: .waitingForInput))
            } else {
                Button(actionLabel, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: 400)
    }

    private var footer: some View {
        HStack {
            // Pixel-square progress, one per step (8-bit, not dots).
            HStack(spacing: 7) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                    Rectangle()
                        .fill(s == step
                            ? step.accent
                            : Theme.secondaryText.opacity(s.rawValue < step.rawValue ? 0.6 : 0.25))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step != .welcome {
                Button("Back") {
                    step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
            }
            Button(step == .allSet ? "Start watching" : "Continue") {
                if step == .allSet {
                    onFinish()
                } else {
                    step = OnboardingStep(rawValue: step.rawValue + 1) ?? .allSet
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(step.accent.opacity(0.8))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 24)
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            setupError = nil
        } catch {
            setupError = error.localizedDescription
        }
    }

}
