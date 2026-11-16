import AVFAudio
import CoreAudio
import Foundation
import VedettaKit

/// Errors from starting a capture: either a user-facing problem the notch
/// explains, or a raw Core Audio failure (logged, shown generically).
/// One owned buffer of captured audio. `AVAudioPCMBuffer` is not Sendable;
/// every chunk is a fresh deep copy handed to exactly one consumer, so moving
/// it across concurrency domains is safe.
struct CallAudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

enum CallAudioError: Error {
    case problem(CallListenProblem)
    case status(String, OSStatus)
}

/// The client's voice: a Core Audio process tap on the meeting app (or a
/// global tap that excludes Meowtch when no meeting app is found), read
/// through a private aggregate device. The TCC prompt ("System Audio
/// Recording") appears at `AudioDeviceStart`, so this only runs on an
/// explicit "Start listening".
@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<CallAudioChunk>.Continuation?
    private let queue = DispatchQueue(label: "app.vedetta.call.tap", qos: .userInitiated)
    private(set) var format: AVAudioFormat?

    func start() throws -> AsyncStream<CallAudioChunk> {
        let processes = Self.audioProcesses()
        let own = getpid()
        let chosen = CallAudioRules.meetingProcesses(processes, excludingPID: own)
        let description: CATapDescription
        if chosen.isEmpty {
            let mine = processes.filter { $0.pid == own }.map { AudioObjectID($0.objectID) }
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: mine)
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: chosen.map { AudioObjectID($0) })
        }
        description.uuid = UUID()
        description.name = "Meowtch call"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create tap")
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "tap format")
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw CallAudioError.status("tap format unsupported", 0)
        }
        self.format = format

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meowtch call",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "aggregate device")
        aggregateID = device

        let (stream, continuation) = AsyncStream.makeStream(of: CallAudioChunk.self, bufferingPolicy: .bufferingNewest(64))
        self.continuation = continuation
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  let copy = buffer.deepCopy() else { return }
            continuation.yield(CallAudioChunk(buffer: copy))
        }, "io proc")
        ioProcID = procID

        let started = AudioDeviceStart(aggregateID, ioProcID)
        guard started == noErr else {
            stop()
            throw CallAudioError.problem(.systemAudioDenied)
        }
        return stream
    }

    /// Tears down in reverse order of creation; safe to call twice.
    func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        continuation?.finish()
        continuation = nil
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            stop()
            throw CallAudioError.status(step, status)
        }
    }

    /// Every process the HAL knows about, with what the rules need.
    static func audioProcesses() -> [AudioProcessInfo] {
        let ids: [AudioObjectID] = arrayProperty(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList
        )
        return ids.map { id in
            let pid: pid_t = scalarProperty(id, kAudioProcessPropertyPID) ?? -1
            let running: UInt32 = scalarProperty(id, kAudioProcessPropertyIsRunningOutput) ?? 0
            return AudioProcessInfo(
                objectID: id, pid: pid,
                bundleID: stringProperty(id, kAudioProcessPropertyBundleID),
                isRunningOutput: running != 0
            )
        }
    }
}

// MARK: - Core Audio property helpers

func scalarProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { value.deallocate() }
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
    return value.pointee
}

func arrayProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    let values = UnsafeMutablePointer<T>.allocate(capacity: count)
    defer { values.deallocate() }
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, values) == noErr else { return [] }
    return Array(UnsafeBufferPointer(start: values, count: count))
}

func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
          let string = value?.takeRetainedValue() else { return nil }
    let result = string as String
    return result.isEmpty ? nil : result
}

extension AVAudioPCMBuffer {
    /// A buffer that owns its samples: IOProc and tap buffers are only
    /// valid for the duration of the callback.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let src = from.mData, let dst = to.mData else { continue }
            memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    /// Root-mean-square level of the first channel, 0…1.
    var rmsLevel: Double {
        guard let data = floatChannelData, frameLength > 0 else { return 0 }
        let samples = UnsafeBufferPointer(start: data[0], count: Int(frameLength))
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return Double((sum / Float(frameLength)).squareRoot())
    }
}
