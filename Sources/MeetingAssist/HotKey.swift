import Carbon
import Foundation

final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    private(set) var available = false
    init() {
        var event = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard id.signature == 0x4D41_5354 else { return OSStatus(eventNotHandledErr) }
                Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().action?()
                return noErr
            }, 1, &event, context, &handler)
        guard installed == noErr else { return }
        let id = EventHotKeyID(signature: 0x4D41_5354, id: 1)
        available =
            RegisterEventHotKey(
                UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0,
                &reference) == noErr
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
