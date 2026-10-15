import AppKit
import ServiceManagement
import SwiftUI
import VedettaKit

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
        // The wizard is always night-sky black; light-mode controls on it
        // render as white slabs.
        window.appearance = NSAppearance(named: .darkAqua)
        // Dark aqua draws the disabled minimize/zoom lights; a wizard has
        // no use for them.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(true, forKey: self.completedKey)
            self.window?.close()
        })
        self.window = window
        ScreenPrivacy.shared.register(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Wizard

private enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, agents, allSet

    /// Splash steps center in the window; setup steps anchor to the top.
    var isSplash: Bool { self == .welcome || self == .allSet }

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
    @AppStorage(SettingsKey.updateAutoCheck) private var autoUpdate = true

    var body: some View {
        ZStack {
            Color.black
            StarfieldView(driftSpeed: 2.0, starCount: 90)

            VStack(spacing: 0) {
                // Splash steps float in the middle; setup steps hang from a
                // fixed line so their headers don't jump between pages.
                if step.isSplash {
                    Spacer(minLength: 30)
                } else {
                    Spacer().frame(height: 96)
                }
                content
                    .frame(width: Layout.contentWidth)
                    .transition(.opacity)
                    .id(step)
                Spacer(minLength: 16)
                footer
            }
        }
        .frame(width: 560, height: 620)
        .environment(\.colorScheme, .dark)
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
        VStack(spacing: 0) {
            PixelSprite(
                pattern: MascotFrame.base,
                color: step.accent,
                pixelSize: 9
            )
            .padding(.bottom, 28)
            Text("MEOWTCH")
                .font(.system(size: 26, weight: .black, design: .monospaced))
                .kerning(10)
                .foregroundStyle(Theme.primaryText)
                .padding(.bottom, 12)
            Text("Your coding agents, watched from the notch.")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
                .padding(.bottom, 22)
            TypewriterText(
                text: "> live sessions · approvals · questions · jump to terminal",
                color: Theme.secondaryText
            )
        }
    }

    private var permissions: some View {
        VStack(spacing: 0) {
            stepHeader(
                "PERMISSIONS",
                prompt: "> the cat needs to raise the right window"
            )
            bodyText("Accessibility lets Meowtch bring the exact terminal\nwindow to the front when you jump to a session.")
                .padding(.bottom, 20)
            card {
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
            }
            .padding(.bottom, 12)
            caption("You can grant it later. Everything else works without it.")
        }
        .onAppear { axTrusted = AXIsProcessTrusted() }
    }

    private var agents: some View {
        VStack(spacing: 0) {
            stepHeader(
                "CONNECT AGENTS",
                prompt: "> hooking into the agents found on this Mac"
            )
            card {
                setupRow(
                    title: "Claude Code",
                    note: FileManager.default.fileExists(
                        atPath: NSHomeDirectory() + "/.claude"
                    ) ? nil : "not detected",
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
                rowDivider
                setupRow(
                    title: "Codex",
                    note: VedettaSetup.codexHomes.contains(where: \.isAvailable)
                        ? nil : "not detected",
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
                rowDivider
                setupRow(
                    title: "VS Code jump extension",
                    ok: extensionInstalled,
                    okLabel: "installed",
                    actionLabel: "Install"
                ) {
                    JumpService.installVSCodeExtension()
                    extensionInstalled = JumpService.vsCodeExtensionInstalled()
                }
            }
            .padding(.bottom, 12)
            caption("Hooks merge additively, with a timestamped backup.\nCodex asks you to trust them with /hooks on first use.")
            if let setupError {
                Text(setupError)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            card {
                toggleRow("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        try? enabled
                            ? SMAppService.mainApp.register()
                            : SMAppService.mainApp.unregister()
                    }
            }
            .padding(.top, 24)
        }
    }

    private var allSet: some View {
        VStack(spacing: 0) {
            PixelSprite(
                pattern: MascotFrame.base,
                color: step.accent,
                pixelSize: 7
            )
            .padding(.bottom, 24)
            stepHeader("ALL SET", prompt: "> hooks armed for new sessions")
            bodyText("Hooks apply to sessions started from now on.\nRestart any running agent to bring it aboard,\nthen hover the notch.")
                .padding(.bottom, 24)
            card {
                toggleRow("Check for updates automatically", isOn: $autoUpdate)
            }
            .padding(.bottom, 12)
            caption("Asks GitHub once a day whether a newer release exists.\nNo account, no telemetry. Off means it never calls home.")
        }
    }

    // MARK: Shared pieces

    private enum Layout {
        static let contentWidth: CGFloat = 400
        static let rowHeight: CGFloat = 44
    }

    private func stepHeader(_ title: String, prompt: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .black, design: .monospaced))
                .kerning(5)
                .foregroundStyle(step.accent)
            TypewriterText(text: prompt, color: Theme.secondaryText)
        }
        .padding(.bottom, 24)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .lineSpacing(3)
            .foregroundStyle(Color.white.opacity(0.72))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .lineSpacing(2)
            .foregroundStyle(Theme.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Rows sit in one panel so their left and right edges read as a list,
    /// not as loose labels floating under centered text.
    private func card<Content: View>(@ViewBuilder _ rows: () -> Content) -> some View {
        VStack(spacing: 0, content: rows)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    private func setupRow(
        title: String,
        note: String? = nil,
        ok: Bool,
        okLabel: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
            if let note {
                Text(note)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 12)
            if ok {
                Label(okLabel, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.color(for: .waitingForInput))
            } else {
                Button(actionLabel, action: action)
                    .buttonStyle(PixelButtonStyle(color: step.accent))
            }
        }
        .frame(height: Layout.rowHeight)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(step.accent)
                .labelsHidden()
        }
        .frame(height: Layout.rowHeight)
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

/// Outlined, monospaced action button: reads as part of the terminal
/// palette instead of a stock AppKit capsule.
private struct PixelButtonStyle: ButtonStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(configuration.isPressed ? 0.28 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(color.opacity(0.6), lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}
