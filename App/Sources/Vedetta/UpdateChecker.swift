import AppKit
import Foundation
import VedettaKit

/// Auto-update against the project's GitHub Releases: asks for the latest
/// release, compares versions, and installs a signature-verified archive
/// on the user's word. Network only with explicit consent (the update
/// check and the usage probe are the app's only traffic).
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// EdDSA public key matching the private key in the maintainer's
    /// Keychain (see Scripts/update-keygen.sh). An archive that doesn't
    /// verify against this is never unpacked.
    static let publicKey = "v93cyw2a1MhPMnM6A8bB8ucCk7ZhNxZ24ChIB0bQaNM="

    static let repository = "taurinexd/meowtch"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    private static let latestEndpoint = URL(
        string: "https://api.github.com/repos/\(repository)/releases/latest"
    )!
    private static let interval: TimeInterval = 24 * 3600

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case installing(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Why automatic installation is impossible here (dev build, read-only
    /// location); nil when the app can update itself.
    @Published private(set) var installBlockedReason: String?

    private var timer: Timer?
    private var lastCheck: Date?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private init() {
        installBlockedReason = Self.blockedReason()
    }

    /// Starts the daily schedule when consent is on. Safe to call again
    /// after the toggle flips.
    func start() {
        timer?.invalidate()
        timer = nil
        guard UserDefaults.standard.bool(forKey: SettingsKey.updateAutoCheck) else { return }
        Task { await check(userInitiated: false) }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkIfDue() async {
        guard UserDefaults.standard.bool(forKey: SettingsKey.updateAutoCheck) else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.interval { return }
        await check(userInitiated: false)
    }

    /// Queries the Releases API. A user-initiated check reports "up to
    /// date" and errors; the scheduled one stays silent unless there is
    /// something to install.
    func check(userInitiated: Bool) async {
        if userInitiated { phase = .checking }
        var request = URLRequest(url: Self.latestEndpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Meowtch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            if userInitiated { phase = .failed("Couldn't reach GitHub.") }
            return
        }
        lastCheck = Date()
        guard http.statusCode == 200, let release = UpdateFeed.parse(latestReleaseJSON: data) else {
            if userInitiated {
                phase = .failed(
                    http.statusCode == 404
                        ? "No published release yet."
                        : "GitHub replied \(http.statusCode)."
                )
            }
            return
        }
        if SemVer.isNewer(release.version, than: currentVersion) {
            phase = .available(release)
        } else if userInitiated {
            phase = .upToDate
        } else {
            phase = .idle
        }
    }

    /// Downloads, verifies and swaps in the release, then relaunches.
    func install(_ release: AppRelease) async {
        guard installBlockedReason == nil else { return }
        do {
            phase = .installing("Downloading…")
            let archive = try await download(release.zipURL)
            let signature = try await download(release.sigURL)
            phase = .installing("Verifying…")
            guard UpdateSignature.verify(
                archive: archive,
                signatureBase64: String(decoding: signature, as: UTF8.self),
                publicKeyBase64: Self.publicKey
            ) else {
                phase = .failed("Signature check failed — update refused.")
                return
            }
            phase = .installing("Installing…")
            try UpdateInstaller.install(
                archive: archive, expectedVersion: release.version
            )
            phase = .installing("Restarting…")
            UpdateInstaller.relaunch()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Meowtch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateInstaller.Failure("Download failed: \(url.lastPathComponent)")
        }
        return data
    }

    /// In-place update needs a writable app in /Applications. A dev build
    /// run from the repo, or a translocated copy, must be replaced by hand.
    private static func blockedReason() -> String? {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") {
            return "Move Meowtch to your Applications folder to enable updates."
        }
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        else { return "Development build — updates install only from Applications." }
        guard FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
        else { return "Applications folder isn't writable by this user." }
        return nil
    }
}
