import CoreAudio
import Foundation

/// Routes one process through a private Core Audio aggregate device.
/// The process tap mutes the direct path only while our IO proc reads it;
/// the callback then writes a gain-adjusted copy to the physical output.
final class ProcessAudioRoute: @unchecked Sendable {
    let processObjectIDs: [AudioObjectID]
    private let state: RouteState
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var stopped = false

    var volume: Float {
        get { state.volume }
        set { state.volume = max(0, min(1, newValue)) }
    }

    var displayLevel: Float { state.takeLevel() }

    init(
        processObjectIDs: [AudioObjectID],
        processName: String,
        outputDeviceUID: String,
        volume: Float
    ) throws {
        self.processObjectIDs = processObjectIDs
        state = RouteState(volume: volume)

        let tapDescription = CATapDescription(
            processes: processObjectIDs,
            deviceUID: outputDeviceUID,
            stream: 0
        )
        tapDescription.name = "AppMixer · \(processName)"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .mutedWhenTapped

        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr else { throw AudioRouteError("create process tap", tapStatus) }

        do {
            let tapUID = try Self.stringProperty(
                objectID: tapID,
                selector: kAudioTapPropertyUID
            )
            let aggregateUID = "com.appmixer.route.\(UUID().uuidString)"
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "AppMixer · \(processName)",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputDeviceUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: tapUID]
                ]
            ]

            let aggregateStatus = AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &aggregateID
            )
            guard aggregateStatus == noErr else {
                throw AudioRouteError("create aggregate device", aggregateStatus)
            }

            let context = Unmanaged.passUnretained(state).toOpaque()
            let procStatus = AudioDeviceCreateIOProcID(
                aggregateID,
                appMixerIOProc,
                context,
                &ioProcID
            )
            guard procStatus == noErr else { throw AudioRouteError("create IO callback", procStatus) }

            let startStatus = AudioDeviceStart(aggregateID, ioProcID)
            guard startStatus == noErr else { throw AudioRouteError("start audio route", startStatus) }
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw AudioRouteError("read tap UID", status) }
        return value as String
    }
}

private final class RouteState: @unchecked Sendable {
    private let lock = NSLock()
    private var _volume: Float
    private var _level: Float = 0

    init(volume: Float) { _volume = volume }

    var volume: Float {
        get { lock.withLock { _volume } }
        set { lock.withLock { _volume = newValue } }
    }

    func publish(level: Float) {
        lock.withLock { _level = max(_level * 0.55, level) }
    }

    func takeLevel() -> Float {
        lock.withLock {
            let value = _level
            _level *= 0.76
            return value
        }
    }
}

private let appMixerIOProc: AudioDeviceIOProc = {
    _, _, inputData, _, outputData, _, clientData in
    guard let clientData else { return noErr }
    let state = Unmanaged<RouteState>.fromOpaque(clientData).takeUnretainedValue()
    let gain = state.volume

    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let outputs = UnsafeMutableAudioBufferListPointer(outputData)
    var peak: Float = 0

    for outputIndex in outputs.indices {
        let output = outputs[outputIndex]
        guard let outputPointer = output.mData else { continue }
        memset(outputPointer, 0, Int(output.mDataByteSize))

        guard !inputs.isEmpty else { continue }
        let sourceIndex = min(outputIndex, inputs.count - 1)
        let input = inputs[sourceIndex]
        guard let inputPointer = input.mData else { continue }

        let byteCount = min(Int(input.mDataByteSize), Int(output.mDataByteSize))
        let sampleCount = byteCount / MemoryLayout<Float>.size
        let source = inputPointer.assumingMemoryBound(to: Float.self)
        let destination = outputPointer.assumingMemoryBound(to: Float.self)

        for sampleIndex in 0..<sampleCount {
            let sample = source[sampleIndex]
            peak = max(peak, abs(sample))
            destination[sampleIndex] = sample * gain
        }
    }

    state.publish(level: min(1, peak * 2.4))
    return noErr
}

private struct AudioRouteError: LocalizedError {
    let operation: String
    let status: OSStatus

    init(_ operation: String, _ status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    var errorDescription: String? {
        let bits = UInt32(bitPattern: status)
        let bytes: [UInt8] = [
            UInt8((bits >> 24) & 0xff),
            UInt8((bits >> 16) & 0xff),
            UInt8((bits >> 8) & 0xff),
            UInt8(bits & 0xff)
        ]
        let printable = bytes.filter { $0 >= 32 && $0 < 127 }
        let fourCC = String(bytes: printable, encoding: .ascii) ?? ""
        let code = fourCC.isEmpty ? String(status) : fourCC
        return "Could not \(operation) (\(code))"
    }
}
