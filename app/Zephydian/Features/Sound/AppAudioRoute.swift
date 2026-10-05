import AudioToolbox
import CoreAudio
import Foundation

/// The level a route plays at, shared with the audio thread. A plain float read and written whole,
/// so the audio thread never waits on a lock.
nonisolated final class AudioGain: @unchecked Sendable {
    var value: Float
    init(_ value: Float) { self.value = value }
}

/// One app's sound passed through Zephydian at its own level and to its own output (macOS 14.2+).
/// A process tap takes the app's sound and silences its normal path; a private aggregate device
/// made of the tap and the chosen output plays it again, scaled, through a small audio callback.
/// It exists only while the app has a level other than 100% or an output of its own.
@available(macOS 14.2, *)
nonisolated final class AppAudioRoute: @unchecked Sendable {
    enum Failure: Error { case tap(OSStatus), aggregate(OSStatus), start(OSStatus) }

    let bundleID: String
    let processes: [AudioObjectID]
    let outputUID: String
    let gain: AudioGain

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// Builds and starts the route. Slow-ish (tens of ms) and may show macOS's permission prompt,
    /// so call it off the main thread.
    init(bundleID: String, name: String, processes: [AudioObjectID], outputUID: String, gain: Float) throws {
        self.bundleID = bundleID
        self.processes = processes
        self.outputUID = outputUID
        self.gain = AudioGain(gain)

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Zephydian \(name)"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else { throw Failure.tap(tapStatus) }
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Zephydian \(name)",
            kAudioAggregateDeviceUIDKey: "com.ahmastan.zephydian.route.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard aggregateStatus == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw Failure.aggregate(aggregateStatus)
        }
        aggregateID = device

        let level = self.gain
        var proc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, output, _ in
            Self.render(input, output, gain: level.value)
        }
        guard ioStatus == noErr, let proc else {
            stop()
            throw Failure.start(ioStatus)
        }
        procID = proc
        let startStatus = AudioDeviceStart(device, proc)
        guard startStatus == noErr else {
            stop()
            throw Failure.start(startStatus)
        }
    }

    /// Copies the tapped sound to the output at the route's level. Above 100% a soft limiter keeps
    /// loud parts from cracking. Runs on the audio thread: no allocation, no locks.
    private static func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for index in 0..<outputs.count {
            let out = outputs[index]
            guard let destination = out.mData?.assumingMemoryBound(to: Float32.self) else { continue }
            let count = Int(out.mDataByteSize) / MemoryLayout<Float32>.size
            var written = 0
            if inputs.count > 0 {
                let source = inputs[min(index, inputs.count - 1)]
                if let samples = source.mData?.assumingMemoryBound(to: Float32.self) {
                    let available = min(count, Int(source.mDataByteSize) / MemoryLayout<Float32>.size)
                    if gain <= 1 {
                        for i in 0..<available { destination[i] = samples[i] * gain }
                    } else {
                        for i in 0..<available {
                            let v = samples[i] * gain
                            // Soft knee above 0.8: smoothly approaches ±1 instead of clipping.
                            let a = abs(v)
                            destination[i] = a <= 0.8 ? v : (v < 0 ? -1 : 1) * (0.8 + 0.2 * tanh((a - 0.8) / 0.2))
                        }
                    }
                    written = available
                }
            }
            if written < count { (destination + written).update(repeating: 0, count: count - written) }
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}
