import Testing
@testable import VedettaKit

struct CallModeTests {
    @Test func rawValuesAreStable() {
        // Frozen on purpose: M4 exposes the mode over the debug socket, and a
        // renamed case there would break the wire format silently.
        #expect(CallMode.code.rawValue == "code")
        #expect(CallMode.call.rawValue == "call")
        #expect(CallMode.allCases.count == 2)
    }

    @Test func onlyCallHidesFromScreenCapture() {
        #expect(CallMode.code.hidesFromScreenCapture == false)
        #expect(CallMode.call.hidesFromScreenCapture == true)
    }
}
