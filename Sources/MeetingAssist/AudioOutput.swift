import CoreAudio
import Foundation

struct AudioOutput: Equatable {
    let id: AudioDeviceID
    let name: String
    let headphoneLike: Bool
    static let unavailable = Self(id: 0, name: "No audio output", headphoneLike: false)
    static func displayName(_ name: String, source: String) -> String {
        let selected = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty || selected.caseInsensitiveCompare(name) == .orderedSame
            ? name : name + " · " + selected
    }
    static func isHeadphoneLike(name: String, source: String, transport: UInt32, terminals: [UInt32] = [])
        -> Bool
    {
        let text = (name + " " + source).lowercased()
        // Generic USB/Bluetooth outputs may also be speakers; show the selected route in the UI.
        return ["airpods", "headphone", "headset", "earbud", "beats"].contains(where: text.contains)
            || transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
            || transport == kAudioDeviceTransportTypeUSB
            || terminals.contains(kAudioStreamTerminalTypeHeadphones)
    }
    private static func outputTerminals(_ device: AudioDeviceID) -> [UInt32] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        let result = streams.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { return [] }
        return streams.compactMap { stream in
            var terminal: UInt32 = 0
            var bytes = UInt32(MemoryLayout<UInt32>.size)
            var property = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyTerminalType, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(stream, &property, 0, nil, &bytes, &terminal) == noErr else {
                return nil
            }
            return terminal
        }
    }
    static func current() -> Self {
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
            device != 0
        else { return .unavailable }
        return describe(device)
    }
    static func deviceIDs() -> [AudioDeviceID] {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size)
                == noErr, size > 0
        else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!)
        }
        return result == noErr ? devices : []
    }
    static func connected() -> [Self] {
        deviceIDs().map(describe).filter { $0.id != 0 }
    }
    static func preferred(defaultOutput: Self, connected: [Self]) -> Self {
        if defaultOutput.headphoneLike { return defaultOutput }
        return connected.filter(\.headphoneLike).sorted {
            let named: (Self) -> Bool = { route in
                ["airpods", "headphone", "headset", "earbud", "beats"].contains {
                    route.name.lowercased().contains($0)
                }
            }
            if named($0) != named($1) { return named($0) }
            return $0.id < $1.id
        }.first ?? defaultOutput
    }
    static func preferredHeadphones() -> Self { preferred(defaultOutput: current(), connected: connected()) }
    private static func describe(_ device: AudioDeviceID) -> Self {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return .unavailable
        }
        address.mScope = kAudioObjectPropertyScopeGlobal
        var alive: UInt32 = 0
        address.mSelector = kAudioDevicePropertyDeviceIsAlive
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr,
            alive != 0
        else { return .unavailable }
        var name: CFString = "Audio output" as CFString
        address.mSelector = kAudioObjectPropertyName
        size = UInt32(MemoryLayout<CFString>.size)
        withUnsafeMutablePointer(to: &name) {
            _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        var transport: UInt32 = 0
        address.mSelector = kAudioDevicePropertyTransportType
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        var source: UInt32 = 0
        address.mSelector = kAudioDevicePropertyDataSource
        address.mScope = kAudioDevicePropertyScopeOutput
        size = UInt32(MemoryLayout<UInt32>.size)
        var sourceName: CFString = "" as CFString
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source) == noErr {
            withUnsafeMutablePointer(to: &source) { input in
                withUnsafeMutablePointer(to: &sourceName) { output in
                    var translation = AudioValueTranslation(
                        mInputData: input, mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                        mOutputData: output, mOutputDataSize: UInt32(MemoryLayout<CFString>.size))
                    address.mSelector = kAudioDevicePropertyDataSourceNameForIDCFString
                    size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                    _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &translation)
                }
            }
        }
        let deviceName = name as String
        let selectedSource = sourceName as String
        return Self(
            id: device, name: displayName(deviceName, source: selectedSource),
            headphoneLike: isHeadphoneLike(
                name: name as String, source: sourceName as String, transport: transport,
                terminals: outputTerminals(device)))
    }
}

final class AudioOutputListener {
    let block: AudioObjectPropertyListenerBlock
    init(_ block: @escaping AudioObjectPropertyListenerBlock) { self.block = block }
}

final class AudioOutputMonitor {
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var listener: AudioOutputListener?
    private var watchedDevice: AudioDeviceID?
    private var watchedInventory: [AudioDeviceID] = []
    private let deviceIDs: () -> [AudioDeviceID]
    private let add: (AudioObjectID, inout AudioObjectPropertyAddress, AudioOutputListener) -> OSStatus
    private let remove: (AudioObjectID, inout AudioObjectPropertyAddress, AudioOutputListener) -> Void
    init(
        deviceIDs: @escaping () -> [AudioDeviceID] = AudioOutput.deviceIDs,
        add:
            @escaping (AudioObjectID, inout AudioObjectPropertyAddress, AudioOutputListener) ->
            OSStatus = { object, address, block in
                guard AudioObjectHasProperty(object, &address) else {
                    return kAudioHardwareUnknownPropertyError
                }
                return AudioObjectAddPropertyListenerBlock(object, &address, .main, block.block)
            },
        remove:
            @escaping (AudioObjectID, inout AudioObjectPropertyAddress, AudioOutputListener) ->
            Void = { object, address, block in
                AudioObjectRemovePropertyListenerBlock(object, &address, .main, block.block)
            }
    ) {
        self.deviceIDs = deviceIDs
        self.add = add
        self.remove = remove
    }
    func start(device: AudioDeviceID, changed: @escaping () -> Void) {
        let inventory = deviceIDs().sorted()
        // CoreAudio can emit notifications when listeners attach. Reattaching for every notification
        // creates a feedback loop that starves the UI; keep registrations stable until the topology changes.
        guard listener == nil || watchedDevice != device || watchedInventory != inventory else { return }
        stop()
        watchedDevice = device
        watchedInventory = inventory
        let block = AudioOutputListener { _, _ in changed() }
        listener = block
        var addresses: [(AudioObjectID, AudioObjectPropertyAddress)] = [
            (
                AudioObjectID(kAudioObjectSystemObject),
                AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
            ),
            (
                AudioObjectID(kAudioObjectSystemObject),
                AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            ),
            (
                device,
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain)
            ),
            (
                device,
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
            ),
        ]
        for candidate in inventory where candidate != device {
            addresses.append(
                (
                    candidate,
                    AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain)
                ))
        }
        for (object, var address) in addresses {
            if add(object, &address, block) == noErr {
                registrations.append((object, address))
            }
        }
    }
    func stop() {
        if let listener {
            for (object, var address) in registrations {
                remove(object, &address, listener)
            }
        }
        registrations.removeAll()
        listener = nil
        watchedDevice = nil
        watchedInventory = []
    }
    deinit { stop() }
}
