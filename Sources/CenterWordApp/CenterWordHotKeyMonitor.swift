import AppKit
import Carbon
import CoreGraphics

enum CenterWordHotKeyRegistrationStatus: Equatable {
    case registered
    case unavailable(String)

    var isRegistered: Bool {
        if case .registered = self {
            return true
        }
        return false
    }

    var message: String {
        switch self {
        case .registered:
            return "Cmd+Option+S is ready."
        case let .unavailable(message):
            return message
        }
    }
}

@MainActor
final class CenterWordHotKeyMonitor {
    var onPress: (() -> Void)?

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var commandIsDown = false
    private var optionIsDown = false
    private var lastTriggerTime = Date.distantPast
    private let debounceInterval: TimeInterval = 0.35

    @discardableResult
    func install() -> CenterWordHotKeyRegistrationStatus {
        uninstall()

        guard CGPreflightListenEventAccess() else {
            CenterWordDiagnostics.record("hotkey_install unavailable input_monitoring")
            return .unavailable("CenterWord needs Input Monitoring permission to detect Cmd+Option+S globally.")
        }

        let eventsOfInterest =
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue) |
            CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventsOfInterest,
            callback: centerWordEventTapCallback,
            userInfo: userInfo
        ) else {
            CenterWordDiagnostics.record("hotkey_install unavailable tap_create_failed")
            return .unavailable("CenterWord could not start its global shortcut listener.")
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        self.eventTap = eventTap
        eventTapSource = source
        CenterWordDiagnostics.record("hotkey_install registered")
        return .registered
    }

    @discardableResult
    func refresh() -> CenterWordHotKeyRegistrationStatus {
        install()
    }

    func uninstall() {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }

        eventTapSource = nil
        eventTap = nil
        commandIsDown = false
        optionIsDown = false
        CenterWordDiagnostics.record("hotkey_uninstall")
    }

    fileprivate func handleEvent(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        if type == .flagsChanged {
            updateModifierState(keyCode: keyCode)
            CenterWordDiagnostics.record(
                "hotkey_flags_changed keyCode=\(keyCode) commandIsDown=\(commandIsDown) optionIsDown=\(optionIsDown)"
            )
            return
        }

        if keyCode == Int64(kVK_ANSI_S) {
            CenterWordDiagnostics.record(
                "hotkey_raw type=\(type.rawValue) keyCode=\(keyCode) flags.command=\(flags.contains(.maskCommand)) flags.option=\(flags.contains(.maskAlternate)) tracked.command=\(commandIsDown) tracked.option=\(optionIsDown) shift=\(flags.contains(.maskShift)) control=\(flags.contains(.maskControl))"
            )
        }

        guard keyCode == Int64(kVK_ANSI_S), type == .keyDown || type == .keyUp else {
            return
        }

        let commandActive = commandIsDown || flags.contains(.maskCommand)
        let optionActive = optionIsDown || flags.contains(.maskAlternate)
        guard commandActive, optionActive else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastTriggerTime) > debounceInterval else {
            CenterWordDiagnostics.record("hotkey_event ignored_debounce")
            return
        }

        lastTriggerTime = now
        CenterWordDiagnostics.record("hotkey_event matched type=\(type.rawValue) cmd+opt+s")
        onPress?()
    }

    private func updateModifierState(keyCode: Int64) {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand:
            commandIsDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
        case kVK_Option, kVK_RightOption:
            optionIsDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
        default:
            break
        }
    }
}

private func centerWordEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let monitor = Unmanaged<CenterWordHotKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    Task { @MainActor in
        monitor.handleEvent(type: type, keyCode: keyCode, flags: flags)
    }

    return Unmanaged.passUnretained(event)
}
