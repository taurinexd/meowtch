import CryptoKit
import Foundation

/// A published Vedetta release, as the auto-updater sees it: the version,
/// where its signed archive lives, and the notes to show the user.
public struct AppRelease: Equatable, Sendable {
    public let version: String
    public let tagName: String
    public let zipURL: URL
    public let sigURL: URL
    public let notes: String?

    public init(version: String, tagName: String, zipURL: URL, sigURL: URL, notes: String?) {
        self.version = version
        self.tagName = tagName
        self.zipURL = zipURL
        self.sigURL = sigURL
        self.notes = notes
    }
}

/// Parses the GitHub Releases API (`GET /releases/latest`). A release is
/// eligible only when it is a real, published one AND ships both the
/// archive and its EdDSA signature — without the signature there is no
/// safe update, so the release is treated as nonexistent.
public enum UpdateFeed {
    public static let archiveAssetName = "Meowtch.zip"
    public static let signatureAssetName = "Meowtch.zip.sig"

    public static func parse(latestReleaseJSON: Data) -> AppRelease? {
        guard let root = try? JSONSerialization.jsonObject(with: latestReleaseJSON)
                as? [String: Any],
              let tag = root["tag_name"] as? String, !tag.isEmpty,
              root["draft"] as? Bool != true,
              root["prerelease"] as? Bool != true,
              let assets = root["assets"] as? [[String: Any]]
        else { return nil }

        func assetURL(named name: String) -> URL? {
            assets.first { $0["name"] as? String == name }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        guard let zipURL = assetURL(named: archiveAssetName),
              let sigURL = assetURL(named: signatureAssetName) else { return nil }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = (root["body"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AppRelease(
            version: version, tagName: tag, zipURL: zipURL, sigURL: sigURL, notes: notes
        )
    }
}

/// Numeric dotted-version comparison, tolerant of a leading `v` and of
/// different component counts ("1.0" == "1.0.0").
public enum SemVer {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate)
        let b = components(current)
        for index in 0..<max(a.count, b.count) {
            let lhs = index < a.count ? a[index] : 0
            let rhs = index < b.count ? b[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        var trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") { trimmed = String(trimmed.dropFirst()) }
        return trimmed.split(separator: ".").map { Int($0) ?? 0 }
    }
}

/// EdDSA (Curve25519) verification of a release archive against the
/// public key compiled into the app. The `.sig` asset is the base64 of
/// the raw signature; verification happens BEFORE the archive is ever
/// unpacked.
public enum UpdateSignature {
    public static func verify(
        archive: Data, signatureBase64: String, publicKeyBase64: String
    ) -> Bool {
        guard let signature = Data(
                base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              let keyRaw = Data(
                base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyRaw)
        else { return false }
        return key.isValidSignature(signature, for: archive)
    }
}
