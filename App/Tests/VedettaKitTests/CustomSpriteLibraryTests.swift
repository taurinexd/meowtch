import Foundation
import Testing
@testable import VedettaKit

struct CustomSpriteLibraryTests {
    private func makeLibrary() -> (CustomSpriteLibrary, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedetta-sprites-\(UUID().uuidString)", isDirectory: true)
        return (CustomSpriteLibrary(directory: dir), dir)
    }

    @Test func fileNamesUseCaseNames() {
        #expect(CustomSpriteLibrary.fileName(for: .running) == "running.gif")
        #expect(CustomSpriteLibrary.fileName(for: .waitingForInput) == "waitingForInput.gif")
        #expect(CustomSpriteLibrary.fileName(for: .needsApproval) == "needsApproval.gif")
        #expect(CustomSpriteLibrary.fileName(for: .compacting) == "compacting.gif")
        #expect(CustomSpriteLibrary.fileName(for: .completed) == "completed.gif")
    }

    @Test func urlIsNilWithoutFile() {
        let (library, _) = makeLibrary()
        #expect(library.url(for: .running) == nil)
    }

    @Test func installCopiesAndResolves() throws {
        let (library, dir) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-\(UUID().uuidString).gif")
        try Data([0x47, 0x49, 0x46]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let dest = try library.install(source, for: .running)
        #expect(library.url(for: .running) == dest)
        #expect(dest.lastPathComponent == "running.gif")
        #expect(library.url(for: .waitingForInput) == nil)   // gli altri stati restano fallback
    }

    @Test func installReplacesAndRemoveClears() throws {
        let (library, dir) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-\(UUID().uuidString).gif")
        try Data([0x01]).write(to: source)
        try library.install(source, for: .completed)
        try Data([0x02, 0x03]).write(to: source)
        try library.install(source, for: .completed)          // rimpiazza senza errore
        defer { try? FileManager.default.removeItem(at: source) }

        let installed = try #require(library.url(for: .completed))
        #expect(try Data(contentsOf: installed) == Data([0x02, 0x03]))
        try library.remove(for: .completed)
        #expect(library.url(for: .completed) == nil)
        try library.remove(for: .completed)                   // idempotente
    }
}
