import Testing
@testable import VedettaKit

struct CallAudioRulesTests {
    private func p(_ id: UInt32, _ bundle: String?, pid: Int32? = nil, out: Bool) -> AudioProcessInfo {
        AudioProcessInfo(objectID: id, pid: pid ?? Int32(id) + 100, bundleID: bundle, isRunningOutput: out)
    }

    private func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    @Test func chromeHelperIsTheMeeting() {
        let all = [p(1, "com.google.Chrome", out: false), p(2, "com.google.Chrome.helper", out: true), p(3, "com.spotify.client", out: true)]
        #expect(CallAudioRules.meetingProcesses(all, excludingPID: 99) == [2])
    }

    @Test func withNoActiveOutputAllMatchingProcessesAreTapped() {
        let all = [p(1, "com.google.Chrome", out: false), p(2, "com.google.Chrome.helper", out: false), p(3, "com.spotify.client", out: true)]
        #expect(CallAudioRules.meetingProcesses(all, excludingPID: 99) == [1, 2])
    }

    @Test func ownProcessIsNeverTapped() {
        let all = [p(1, "com.google.Chrome.helper", pid: 99, out: true), p(2, "us.zoom.xos", out: true)]
        #expect(CallAudioRules.meetingProcesses(all, excludingPID: 99) == [2])
    }

    @Test func unknownAppsOnlyMeansGlobalFallback() {
        let all = [p(3, "com.spotify.client", out: true), p(4, nil, out: true)]
        #expect(CallAudioRules.meetingProcesses(all, excludingPID: 99).isEmpty)
    }

    @Test func headphoneDetection() {
        #expect(CallAudioRules.isHeadphoneOutput(transportType: fourCC("blue"), dataSource: nil))
        #expect(CallAudioRules.isHeadphoneOutput(transportType: fourCC("blea"), dataSource: nil))
        #expect(CallAudioRules.isHeadphoneOutput(transportType: fourCC("usb "), dataSource: nil))
        #expect(CallAudioRules.isHeadphoneOutput(transportType: fourCC("bltn"), dataSource: fourCC("hdpn")))
        #expect(!CallAudioRules.isHeadphoneOutput(transportType: fourCC("bltn"), dataSource: fourCC("ispk")))
        #expect(!CallAudioRules.isHeadphoneOutput(transportType: fourCC("bltn"), dataSource: nil))
        #expect(!CallAudioRules.isHeadphoneOutput(transportType: fourCC("hdmi"), dataSource: nil))
    }

    @Test func permissionMessagesNameTheSettingsPath() {
        #expect(CallListenProblem.microphoneDenied.message.contains("Privacy & Security › Microphone"))
        #expect(CallListenProblem.systemAudioDenied.message.contains("System Audio Recording Only"))
        #expect(CallListenProblem.speechAssetDownloading(fraction: 0.42).message.hasSuffix("42%"))
        #expect(CallListenProblem.requiresMacOS26.message == "Listening requires macOS 26.")
    }
}
