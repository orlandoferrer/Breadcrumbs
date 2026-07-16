import Carbon
import Foundation

/// Thin protocol over Carbon C functions, allowing registration behavior to be
/// tested without reserving a real system-wide shortcut.
protocol HotKeyRegistering {
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        hotKeyID: EventHotKeyID,
        target: EventTargetRef?,
        hotKeyRef: UnsafeMutablePointer<EventHotKeyRef?>
    ) -> OSStatus
    func installHandler(
        target: EventTargetRef?,
        handler: EventHandlerUPP,
        eventSpec: UnsafePointer<EventTypeSpec>,
        userData: UnsafeMutableRawPointer?,
        eventHandlerRef: UnsafeMutablePointer<EventHandlerRef?>
    ) -> OSStatus
    func unregister(_ hotKeyRef: EventHotKeyRef) -> OSStatus
    func removeHandler(_ eventHandlerRef: EventHandlerRef) -> OSStatus
}

struct CarbonHotKeyRegistrar: HotKeyRegistering {
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        hotKeyID: EventHotKeyID,
        target: EventTargetRef?,
        hotKeyRef: UnsafeMutablePointer<EventHotKeyRef?>
    ) -> OSStatus {
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, target, 0, hotKeyRef)
    }

    func installHandler(
        target: EventTargetRef?,
        handler: EventHandlerUPP,
        eventSpec: UnsafePointer<EventTypeSpec>,
        userData: UnsafeMutableRawPointer?,
        eventHandlerRef: UnsafeMutablePointer<EventHandlerRef?>
    ) -> OSStatus {
        InstallEventHandler(target, handler, 1, eventSpec, userData, eventHandlerRef)
    }

    func unregister(_ hotKeyRef: EventHotKeyRef) -> OSStatus {
        UnregisterEventHotKey(hotKeyRef)
    }

    func removeHandler(_ eventHandlerRef: EventHandlerRef) -> OSStatus {
        RemoveEventHandler(eventHandlerRef)
    }
}

/// Invalidates superseded asynchronous hotkey requests and consumes each valid
/// request at most once.
struct HotKeyEditRequestGate {
    private var generation: UInt = 0

    mutating func begin() -> UInt {
        generation &+= 1
        return generation
    }

    mutating func cancel() {
        generation &+= 1
    }

    mutating func cancel(requestID: UInt) {
        guard requestID == generation else { return }
        generation &+= 1
    }

    mutating func consume(
        requestID: UInt,
        finderIsFrontmost: Bool,
        hasFreshSnapshot: Bool
    ) -> Bool {
        guard requestID == generation else { return false }
        generation &+= 1
        return finderIsFrontmost && hasFreshSnapshot
    }
}

/// Registers the configured system-wide shortcut only while Finder is active.
///
/// Carbon remains useful here because `RegisterEventHotKey` can reserve a key
/// without requiring Input Monitoring permission.
final class HotKeyManager {
    var onActivate: (() -> Void)?

    private let registrar: HotKeyRegistering
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var registeredShortcut: AppConfig.Shortcut?
    private static let registeredHotKeyID: UInt32 = 1

    init(registrar: HotKeyRegistering = CarbonHotKeyRegistrar()) {
        self.registrar = registrar
    }

    deinit {
        unregister()
    }

    @discardableResult
    func setRegistrationEnabled(_ isEnabled: Bool, shortcut: AppConfig.Shortcut) -> OSStatus {
        guard isEnabled else {
            deactivate()
            return noErr
        }

        return register(shortcut: shortcut)
    }

    @discardableResult
    func register(shortcut: AppConfig.Shortcut) -> OSStatus {
        if hotKeyRef != nil, registeredShortcut == shortcut {
            return noErr
        }

        deactivate()

        let eventHotKeyID = EventHotKeyID(signature: OSType(0x46425244), id: Self.registeredHotKeyID)
        let registerStatus = registrar.register(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers,
            hotKeyID: eventHotKeyID,
            target: GetApplicationEventTarget(),
            hotKeyRef: &hotKeyRef
        )
        guard registerStatus == noErr else {
            return registerStatus
        }

        if eventHandlerRef == nil {
            var eventSpec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let handlerStatus = registrar.installHandler(
                target: GetApplicationEventTarget(),
                handler: hotKeyEventHandler,
                eventSpec: &eventSpec,
                userData: Unmanaged.passUnretained(self).toOpaque(),
                eventHandlerRef: &eventHandlerRef
            )
            guard handlerStatus == noErr else {
                deactivate()
                return handlerStatus
            }
        }

        registeredShortcut = shortcut
        return noErr
    }

    func deactivate() {
        if let hotKeyRef {
            _ = registrar.unregister(hotKeyRef)
            self.hotKeyRef = nil
        }
        registeredShortcut = nil
    }

    func unregister() {
        deactivate()
        if let eventHandlerRef {
            _ = registrar.removeHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    fileprivate func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event else { return noErr }

        var hotKeyID = EventHotKeyID()
        GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard hotKeyID.id == Self.registeredHotKeyID else {
            return noErr
        }

        onActivate?()
        return noErr
    }
}

private func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    // C callbacks cannot capture Swift objects. Carbon returns the opaque pointer
    // supplied during registration, which is converted back without taking ownership.
    guard let userData else { return noErr }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    return manager.handleHotKeyEvent(event)
}
