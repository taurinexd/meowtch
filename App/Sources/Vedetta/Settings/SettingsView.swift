import AppKit
import ServiceManagement
import SwiftUI
import VedettaKit

/// Sidebar + pages, mirroring the original's Settings anatomy (General,
/// Integrations, Notifications, Display, Sound, Usage, About) — but every
/// control here is wired to behavior that actually exists.
struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case general, integrations, notifications, display, sound, usage, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .integrations: "Integrations"
            case .notifications: "Notifications"
            case .display: "Display"
            case .sound: "Sound"
            case .usage: "Usage"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .integrations: "puzzlepiece.extension.fill"
            case .notifications: "bell.badge.fill"
            case .display: "textformat.size"
            case .sound: "speaker.wave.2.fill"
            case .usage: "gauge.with.needle.fill"
            case .about: "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .general: Color(nsColor: .systemGray)
            case .integrations: .blue
            case .notifications: .red
            case .display: .purple
            case .sound: .green
            case .usage: .pink
            case .about: .blue
            }
        }
    }

    @ObservedObject private var router = SettingsRouter.shared
    private var selection: Page { router.page }

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $router.page) { page in
                Label {
                    Text(page.title)
                } icon: {
                    PageIcon(symbol: page.symbol, tint: page.tint)
                }
                .tag(page)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        PageIcon(symbol: selection.symbol, tint: selection.tint, side: 26)
                        Text(selection.title)
                            .font(.system(size: 22, weight: .bold))
                    }
                    .padding(.bottom, 18)

                    switch selection {
                    case .general: GeneralSettingsPage()
                    case .integrations: IntegrationsSettingsPage()
                    case .notifications: NotificationsSettingsPage()
                    case .display: DisplaySettingsPage()
                    case .sound: SoundSettingsPage()
                    case .usage: UsageSettingsPage()
                    case .about: AboutSettingsPage()
                    }
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Rounded-rect colored icon, System Settings style.
private struct PageIcon: View {
    let symbol: String
    let tint: Color
    var side: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: side * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(tint.gradient)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.24))
    }
}

// MARK: - Shared section building blocks

private struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .background(Color(nsColor: .quaternarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.bottom, 22)
    }
}

private struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            accessory
        }
        .padding(.vertical, 10)
    }
}

private struct RowDivider: View {
    var body: some View { Divider() }
}

// MARK: - General

private struct GeneralSettingsPage: View {
    @AppStorage(SettingsKey.hoverToExpandEnabled) private var hoverToExpand = true
    @AppStorage(SettingsKey.hoverExpandDelay) private var hoverDelay = 0.10
    @AppStorage(SettingsKey.autoCollapseOnMouseLeave) private var autoCollapse = true
    @AppStorage(SettingsKey.expandDwellSeconds) private var dwell = 5
    @AppStorage(SettingsKey.disableClickToJump) private var disableJump = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        SettingsSection(title: "System") {
            SettingsRow(title: "Launch at Login", subtitle: loginItemError) {
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginItemError = nil
                        } catch {
                            loginItemError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }

        SettingsSection(title: "Expansion") {
            SettingsRow(title: "Expand notch on hover") {
                Toggle("", isOn: $hoverToExpand).toggleStyle(.switch).labelsHidden()
            }
            if hoverToExpand {
                RowDivider()
                SettingsRow(title: "Hover duration",
                            subtitle: "How long the cursor rests on the notch before it opens.") {
                    HStack(spacing: 10) {
                        Slider(value: $hoverDelay, in: 0...0.5, step: 0.05)
                            .frame(width: 180)
                        Text(String(format: "%.2fs", hoverDelay))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }
        }

        SettingsSection(
            title: "Dismissal",
            footer: "The dwell applies to the auto-opened peek when a session finishes while you are elsewhere."
        ) {
            SettingsRow(title: "Auto-collapse on mouse leave") {
                Toggle("", isOn: $autoCollapse).toggleStyle(.switch).labelsHidden()
            }
            RowDivider()
            SettingsRow(title: "Auto reveal dwell") {
                Stepper(value: $dwell, in: 2...15) {
                    Text("\(dwell)s")
                        .font(.system(size: 12, design: .monospaced))
                }
            }
        }

        SettingsSection(
            title: "Interaction",
            footer: "When enabled, clicking a session card won't switch to its terminal or IDE."
        ) {
            SettingsRow(title: "Disable click-to-jump") {
                Toggle("", isOn: $disableJump).toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

// MARK: - Integrations

private struct IntegrationsSettingsPage: View {
    @State private var claudeInstalled = VedettaSetup.claudeHooksInstalled()
    @State private var codexInstalled = VedettaSetup.codexHooksInstalled()
    @State private var extensionInstalled = JumpService.vsCodeExtensionInstalled()
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var trustReport: String?
    @State private var operationError: String?
    @AppStorage("codexApprovalMode") private var codexApprovalMode = "alwaysNotch"
    @AppStorage("claudeApprovalMode") private var claudeApprovalMode =
        ClaudeApprovalPolicy.mode(
            rawValue: UserDefaults.standard.string(forKey: "claudeApprovalMode"),
            legacyDeferToNative: UserDefaults.standard.bool(
                forKey: "deferClaudeApprovalsToNative"
            )
        ).rawValue

    var body: some View {
        SettingsSection(
            title: "CLI Hooks",
            footer: operationError ?? "Hooks are merged additively with a timestamped backup in ~/.vedetta/backups; removing them restores your config."
        ) {
            hookRow(title: "Claude Code", installed: claudeInstalled) { enable in
                perform {
                    _ = enable
                        ? try VedettaSetup.installClaudeHooks()
                        : try VedettaSetup.removeClaudeHooks()
                    claudeInstalled = VedettaSetup.claudeHooksInstalled()
                }
            }
            RowDivider()
            hookRow(title: "Codex", installed: codexInstalled) { enable in
                perform {
                    _ = enable
                        ? try VedettaSetup.installCodexHooks()
                        : try VedettaSetup.removeCodexHooks()
                    codexInstalled = VedettaSetup.codexHooksInstalled()
                }
            }
            RowDivider()
            SettingsRow(title: "Codex config directories",
                        subtitle: VedettaSetup.codexHomes.map(\.path).joined(separator: "\n")) {
                Button("Add…") { addCodexHome() }
            }
            RowDivider()
            SettingsRow(title: "Codex hook trust",
                        subtitle: trustReport ?? "Codex asks you to authorize hooks with /hooks on first use.") {
                Button("Check…") { checkTrust() }
            }
        }

        SettingsSection(
            title: "Approvals",
            footer: "Always Notch (default) mirrors every approval and question as a card. Follow Focus leaves it in the terminal when you are already looking at it. Always Terminal never uses the notch. Auto-reviewed Codex requests stay silent."
        ) {
            SettingsRow(title: "When Claude needs your approval") {
                Picker("", selection: $claudeApprovalMode) {
                    Text("Always Notch").tag("alwaysNotch")
                    Text("Follow Focus").tag("followFocus")
                    Text("Always Terminal").tag("alwaysTerminal")
                }
                .labelsHidden()
                .frame(width: 170)
            }
            RowDivider()
            SettingsRow(title: "When Codex needs your approval") {
                Picker("", selection: $codexApprovalMode) {
                    Text("Always Notch").tag("alwaysNotch")
                    Text("Follow Focus").tag("followFocus")
                    Text("Always Terminal").tag("alwaysTerminal")
                    Text("Native Codex").tag("nativeCodex")
                }
                .labelsHidden()
                .frame(width: 170)
            }
        }

        SettingsSection(
            title: "IDE Extensions",
            footer: "The companion extension focuses the exact integrated-terminal tab when you click a card. VS Code needs a window reload after changes."
        ) {
            SettingsRow(title: "VS Code",
                        subtitle: extensionInstalled ? "Installed" : "Not installed") {
                Button(extensionInstalled ? "Reinstall" : "Install") {
                    JumpService.installVSCodeExtension()
                    extensionInstalled = JumpService.vsCodeExtensionInstalled()
                }
            }
        }

        SettingsSection(
            title: "Permissions",
            footer: "Accessibility lets Vedetta read terminal window titles and raise the exact window during jumps."
        ) {
            SettingsRow(title: "Accessibility",
                        subtitle: axTrusted ? "Granted" : "Not granted") {
                Button(axTrusted ? "Granted" : "Request…") {
                    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                    axTrusted = AXIsProcessTrusted()
                }
                .disabled(axTrusted)
            }
        }
    }

    private func hookRow(
        title: String,
        installed: Bool,
        action: @escaping (Bool) -> Void
    ) -> some View {
        SettingsRow(title: title) {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(installed ? .green : .secondary)
                    Text(installed ? "Active" : "Inactive")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Toggle("", isOn: Binding(get: { installed }, set: action))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try VedettaSetup.ensureRuntimeLayout()
            try work()
            operationError = nil
        } catch {
            operationError = "Operation failed: \(error.localizedDescription)"
        }
    }

    private func addCodexHome() {
        let picker = NSOpenPanel()
        picker.title = "Select a Codex config directory"
        picker.prompt = "Add"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        let codexHome = VedettaSetup.registerCodexHome(url.path)
        perform {
            _ = try VedettaSetup.installCodexHooks(at: codexHome)
            NotificationCenter.default.post(name: .vedettaCodexHomesChanged, object: nil)
            codexInstalled = VedettaSetup.codexHooksInstalled()
        }
    }

    private func checkTrust() {
        trustReport = "Checking…"
        Task { @MainActor in
            var lines: [String] = []
            for codexHome in VedettaSetup.codexHomes {
                if !codexHome.isAvailable {
                    lines.append("\(codexHome.path): unavailable")
                    continue
                }
                if VedettaSetup.codexHooksExplicitlyDisabled(at: codexHome) {
                    lines.append("\(codexHome.path): disabled in config.toml")
                    continue
                }
                let client = codexHome.isDefault
                    ? CodexAppServerClient.shared
                    : CodexAppServerClient(codexHome: codexHome.path)
                let snapshot = await client.hookTrust()
                if !codexHome.isDefault { await client.shutdown() }
                let label = switch snapshot.state {
                case .verified: "verified"
                case .manualConfirmationRequired: "review with /hooks"
                case .disabled: "disabled"
                case .unverified: "unverified — review with /hooks"
                case .unavailable: "app-server unavailable"
                }
                lines.append("\(codexHome.path): \(label)")
            }
            trustReport = lines.joined(separator: "\n")
        }
    }
}

// MARK: - Notifications

private struct NotificationsSettingsPage: View {
    @AppStorage(SettingsKey.expandPanelForCompletions) private var expandForCompletions = true

    var body: some View {
        SettingsSection(
            title: "Completion notifications",
            footer: "Approvals and questions always expand the panel, regardless of this setting. A finished session only auto-opens when you are looking at another app, at most once every two minutes per session."
        ) {
            SettingsRow(title: "Expand the panel for completion notifications") {
                Toggle("", isOn: $expandForCompletions).toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

// MARK: - Display

private struct DisplaySettingsPage: View {
    @State private var externalDisplay = NotchPanelController.preferExternalDisplay
    @AppStorage(SessionMetadataPresentation.defaultsKey) private var showMetadata = false

    var body: some View {
        SettingsSection(
            title: "Notch",
            footer: "On displays without a notch the panel renders as a floating bar at the top edge."
        ) {
            SettingsRow(title: "Panel on external display",
                        subtitle: "Keep the panel on the external screen instead of the notch display.") {
                Toggle("", isOn: $externalDisplay)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: externalDisplay) { _, value in
                        NotchPanelController.preferExternalDisplay = value
                        NotificationCenter.default.post(
                            name: .vedettaPanelDisplayChanged, object: nil
                        )
                    }
            }
        }

        SettingsSection(title: "Session card") {
            SettingsRow(title: "Show session metadata",
                        subtitle: "Branch, model and reasoning effort under the card text.") {
                Toggle("", isOn: $showMetadata).toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

// MARK: - Sound

private struct SoundSettingsPage: View {
    @State private var enabled = !SoundEngine.shared.isMuted
    @AppStorage(SettingsKey.soundVolume) private var volume = 0.5

    private static let events: [(SoundEngine.Event, String, String)] = [
        (.sessionStart, "Session Start", "New Claude or Codex session"),
        (.sessionComplete, "Task Complete", "The agent finished its turn"),
        (.taskError, "Task Error", "The turn failed"),
        (.approvalRequest, "Approval Needed", "Permission pending"),
        (.question, "Question", "The agent asked you something"),
        (.taskAcknowledge, "Task Acknowledge", "You submitted a prompt"),
        (.contextLimit, "Context Limit", "Context window almost full"),
    ]

    var body: some View {
        SettingsSection(
            title: "Sound Effects",
            footer: "8-bit chirps, synthesized in memory. Drop custom .wav files named after an event in ~/.vedetta/custom-sounds to replace them."
        ) {
            SettingsRow(title: "Enable Sound Effects") {
                Toggle("", isOn: $enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: enabled) { _, value in
                        SoundEngine.shared.isMuted = !value
                    }
            }
            if enabled {
                RowDivider()
                SettingsRow(title: "Volume") {
                    HStack(spacing: 10) {
                        Slider(
                            value: $volume, in: 0...1,
                            onEditingChanged: { editing in
                                if !editing { SoundEngine.shared.playPreview(.question) }
                            }
                        )
                        .frame(width: 180)
                        Text("\(Int(volume * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }

        if enabled {
            SettingsSection(
                title: "Events",
                footer: "Approvals and questions still show their cards when silenced — only the chirp is skipped."
            ) {
                ForEach(Array(Self.events.enumerated()), id: \.offset) { index, entry in
                    if index > 0 { RowDivider() }
                    SoundEventRow(event: entry.0, title: entry.1, subtitle: entry.2)
                }
            }
        }
    }
}

/// One silence rule: preview button + per-event toggle.
private struct SoundEventRow: View {
    let event: SoundEngine.Event
    let title: String
    let subtitle: String
    @State private var enabled: Bool

    init(event: SoundEngine.Event, title: String, subtitle: String) {
        self.event = event
        self.title = title
        self.subtitle = subtitle
        _enabled = State(initialValue: SoundEngine.shared.isEnabled(event))
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: 12) {
                Button {
                    SoundEngine.shared.playPreview(event)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Toggle("", isOn: $enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: enabled) { _, value in
                        SoundEngine.shared.setEnabled(event, value)
                    }
            }
        }
    }
}

// MARK: - Usage

private struct UsageSettingsPage: View {
    @AppStorage(SettingsKey.showUsageLimits) private var showUsage = true
    @AppStorage(SettingsKey.preferredUsageProvider) private var provider = "auto"
    @State private var statusLineOwner = VedettaSetup.claudeStatusLineOwner()
    @State private var claimError: String?

    private var claudeSourceSubtitle: String {
        switch statusLineOwner {
        case .vedetta:
            "Active: Vedetta's statusline harvests the rate limits."
        case .foreign:
            claimError ?? "Another statusline occupies the Claude Code slot, so Claude usage can't be harvested. Replacing backs the current one up first."
        case .none:
            claimError ?? "No statusline installed: Claude usage needs Vedetta's harvester."
        }
    }

    var body: some View {
        SettingsSection(
            title: "Usage Limits",
            footer: "The strip left of the physical notch shows the subscription windows; tapping it cycles providers. Claude comes from the statusline rate limits, Codex from the app-server."
        ) {
            SettingsRow(title: "Show Usage Limits",
                        subtitle: "Display subscription usage in the notch panel header.") {
                Toggle("", isOn: $showUsage).toggleStyle(.switch).labelsHidden()
            }
            if showUsage {
                RowDivider()
                SettingsRow(title: "Preferred Provider") {
                    Picker("", selection: $provider) {
                        Text("Auto (last used)").tag("auto")
                        Text("Claude").tag("claude")
                        Text("Codex").tag("codex")
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .onChange(of: provider) { _, value in
                        UsageModel.shared.applyPreferredProvider(value)
                    }
                }
                RowDivider()
                SettingsRow(title: "Claude usage source",
                            subtitle: claudeSourceSubtitle) {
                    if statusLineOwner != .vedetta {
                        Button("Use Vedetta's…") {
                            do {
                                try VedettaSetup.claimStatusLine()
                                claimError = nil
                            } catch {
                                claimError = "Replacement failed: \(error.localizedDescription)"
                            }
                            statusLineOwner = VedettaSetup.claudeStatusLineOwner()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - About

private struct AboutSettingsPage: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short ?? "dev"
    }

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 84, height: 84)
            }
            Text("Vedetta")
                .font(.system(size: 22, weight: .bold))
            Text("v\(version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Open-source notch control surface for coding agents.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 26)

        SettingsSection(title: "Resources") {
            SettingsRow(title: "Onboarding",
                        subtitle: "Replay the first-run setup steps.") {
                Button("Show") { OnboardingController.shared.show() }
            }
            RowDivider()
            SettingsRow(title: "Runtime files",
                        subtitle: "~/.vedetta — socket, hooks launcher, backups, custom sounds.") {
                Button("Reveal") {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: VedettaSetup.rootDir
                    )
                }
            }
        }

        SettingsSection(title: "License") {
            SettingsRow(title: "MIT License",
                        subtitle: "Free and open source.") {
                EmptyView()
            }
        }
    }
}
