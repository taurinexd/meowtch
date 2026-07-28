import CryptoKit
import Foundation
import Testing
@testable import VedettaKit

struct UpdateFeedTests {
    // Forma reale (ridotta) di GET /repos/<owner>/<repo>/releases/latest.
    private func releaseJSON(
        tag: String = "v0.1.0", draft: Bool = false, prerelease: Bool = false,
        assets: [String] = ["Meowtch.zip", "Meowtch.zip.sig", "Meowtch.dmg"]
    ) -> Data {
        let assetList = assets.map {
            """
            {"name":"\($0)","browser_download_url":"https://github.com/x/vedetta/releases/download/\(tag)/\($0)","size":123}
            """
        }.joined(separator: ",")
        return Data("""
        {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease),
         "name":"Vedetta \(tag)","body":"Release notes here.",
         "assets":[\(assetList)]}
        """.utf8)
    }

    @Test func parsesLatestRelease() throws {
        let release = try #require(UpdateFeed.parse(latestReleaseJSON: releaseJSON()))
        #expect(release.version == "0.1.0")
        #expect(release.tagName == "v0.1.0")
        #expect(release.zipURL.absoluteString.hasSuffix("/v0.1.0/Meowtch.zip"))
        #expect(release.sigURL.absoluteString.hasSuffix("/v0.1.0/Meowtch.zip.sig"))
        #expect(release.notes == "Release notes here.")
    }

    @Test func rejectsDraftsPrereleasesAndIncompleteAssets() {
        #expect(UpdateFeed.parse(latestReleaseJSON: releaseJSON(draft: true)) == nil)
        #expect(UpdateFeed.parse(latestReleaseJSON: releaseJSON(prerelease: true)) == nil)
        // Senza la firma non c'è update sicuro: l'app deve ignorare la release.
        #expect(UpdateFeed.parse(
            latestReleaseJSON: releaseJSON(assets: ["Meowtch.zip", "Meowtch.dmg"])
        ) == nil)
        #expect(UpdateFeed.parse(latestReleaseJSON: Data("not json".utf8)) == nil)
    }

    @Test func semverComparison() {
        #expect(SemVer.isNewer("0.1.1", than: "0.1.0"))
        #expect(SemVer.isNewer("v0.2.0", than: "0.1.9"))
        #expect(SemVer.isNewer("1.0.0", than: "0.9.9"))
        // Componenti numerici, non lessicografici.
        #expect(!SemVer.isNewer("0.2.0", than: "0.10.0"))
        #expect(!SemVer.isNewer("0.1.0", than: "0.1.0"))
        #expect(!SemVer.isNewer("v1.0", than: "1.0.0"))
        #expect(SemVer.isNewer("1.0.1", than: "1.0"))
    }

    @Test func signatureRoundTrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let archive = Data("the update payload".utf8)
        let signature = try key.signature(for: archive)
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        #expect(UpdateSignature.verify(
            archive: archive,
            signatureBase64: signature.base64EncodedString(),
            publicKeyBase64: publicKey
        ))
        // Il .sig su disco finisce con newline: tollerata.
        #expect(UpdateSignature.verify(
            archive: archive,
            signatureBase64: signature.base64EncodedString() + "\n",
            publicKeyBase64: publicKey
        ))
        // Archivio manomesso, firma altrui o input non-base64: rifiutati.
        #expect(!UpdateSignature.verify(
            archive: archive + Data([0]),
            signatureBase64: signature.base64EncodedString(),
            publicKeyBase64: publicKey
        ))
        let otherKey = Curve25519.Signing.PrivateKey()
        #expect(!UpdateSignature.verify(
            archive: archive,
            signatureBase64: signature.base64EncodedString(),
            publicKeyBase64: otherKey.publicKey.rawRepresentation.base64EncodedString()
        ))
        #expect(!UpdateSignature.verify(
            archive: archive, signatureBase64: "%%%", publicKeyBase64: publicKey
        ))
    }
}
