import Carbon.HIToolbox
import AppKit
import Foundation
import os

let hotkeyLog = Logger(subsystem: "com.local.stark", category: "hotkey")

/// A shortcut parsed from a "ctrl+alt+s"-style spec (config `hotkey` field).
struct HotKeySpec {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String

    static let fallback = HotKeySpec(keyCode: UInt32(kVK_ANSI_D),
                                     modifiers: UInt32(cmdKey),
                                     display: "⌘D")

    /// Accepts modifiers cmd/command, ctrl/control, alt/opt/option, shift
    /// plus one letter or digit key; at least one modifier is required.
    static func parse(_ spec: String) -> HotKeySpec? {
        var modifiers: UInt32 = 0
        var key: String?
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "alt", "opt", "option": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default:
                guard key == nil else { return nil }
                key = part
            }
        }
        guard let key, let keyCode = keyCodes[key], modifiers != 0 else { return nil }
        var display = ""
        if modifiers & UInt32(controlKey) != 0 { display += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { display += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { display += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { display += "⌘" }
        display += displayNames[key] ?? key.uppercased()
        return HotKeySpec(keyCode: keyCode, modifiers: modifiers, display: display)
    }

    static func keyName(for keyCode: UInt32) -> String? {
        keyCodes.first { $0.value == keyCode }?.key
    }

    /// Combos Stark refuses outright: taking these over would break the app the
    /// user is writing in (or Stark's own paste-back, which needs ⌘V/⌘C).
    /// `modifiers` is the recorder's part list, e.g. ["cmd"].
    static func reservedReason(modifiers: [String], key: String) -> String? {
        guard modifiers == ["cmd"] else { return nil } // only plain-⌘ is dangerous
        switch key {
        case "c", "v", "x":
            return "⌘\(key.uppercased()) is copy/paste. Stark needs it to move your text."
        case "q", "w":
            return "⌘\(key.uppercased()) quits or closes windows. Pick another key."
        case "z":
            return "⌘Z is undo. Stark uses it to revert a rewrite."
        default:
            return nil
        }
    }

    /// Allowed, but worth a heads-up: Stark will take the combo over globally.
    static func cautionReason(modifiers: [String], key: String) -> String? {
        guard modifiers == ["cmd"] else { return nil }
        let common = ["a": "Select All", "s": "Save", "f": "Find", "n": "New",
                      "o": "Open", "p": "Print", "t": "New Tab", "b": "Bold",
                      "i": "Italic", "u": "Underline"]
        guard let what = common[key] else { return nil }
        return "Heads-up: ⌘\(key.uppercased()) is \(what) in most apps. Stark will take it over everywhere."
    }

    /// The same combo expressed as Cocoa/CoreGraphics modifier flags, for the
    /// event-tap path (Carbon's cmdKey/optionKey/… are a different encoding).
    var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.maskCommand) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.maskControl) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.maskAlternate) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.maskShift) }
        return f
    }

    private static let keyCodes: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C),
        "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
        "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I),
        "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
        "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
        "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T), "u": UInt32(kVK_ANSI_U),
        "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
        "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
        "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
        "9": UInt32(kVK_ANSI_9),
        // Non-alphanumerics that make good one-modifier combos (⌥Space, ⌃Return).
        "space": UInt32(kVK_Space),
        "return": UInt32(kVK_Return),
        "tab": UInt32(kVK_Tab),
        "`": UInt32(kVK_ANSI_Grave),
    ]

    /// Chip labels for keys whose name isn't just an uppercased letter.
    private static let displayNames: [String: String] = [
        "space": "␣", "return": "⏎", "tab": "⇥", "`": "`",
    ]
}

// MARK: - Delivery

/// Global hotkeys, delivered by whichever of two independent mechanisms works:
///
///  1. **Carbon `RegisterEventHotKey`** — needs no permission, but its events
///     are routed to whichever Carbon event target the hotkey was registered
///     on, and for `LSUIElement` apps launched through LaunchServices that
///     delivery is unreliable (the key gets swallowed system-wide while the
///     handler stays silent). We register on the application target and
///     install handlers on *both* plausible targets.
///  2. **A `CGEvent` tap** — rock solid and the same machinery the predictive
///     typing needs, but only usable once Accessibility is granted.
///
/// Both run at once; `Dispatcher` drops the duplicate when they both land.
/// Every fire is logged with its source so `log show` can tell them apart.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Binding {
        let spec: HotKeySpec
        let action: () -> Void
    }

    private var bindings: [UInt32: Binding] = [:]
    private var carbonRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [EventHandlerRef] = []
    private var nextID: UInt32 = 1

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// Guards against the Carbon and tap paths both firing for one press.
    private var lastFire: (id: UInt32, at: CFAbsoluteTime) = (0, 0)

    private(set) var carbonEverFired = false
    private(set) var tapEverFired = false
    var tapActive: Bool { tap != nil }

    private init() { installCarbonHandlers() }

    // MARK: registration

    @discardableResult
    func register(_ spec: HotKeySpec, action: @escaping () -> Void) -> UInt32 {
        let id = nextID
        nextID += 1
        bindings[id] = Binding(spec: spec, action: action)

        let hotKeyID = EventHotKeyID(signature: OSType(0x5354_524B), id: id) // 'STRK'
        var ref: EventHotKeyRef?
        // The application target is the documented one; fall back to the
        // dispatcher target if it refuses the registration outright.
        var err = RegisterEventHotKey(spec.keyCode, spec.modifiers, hotKeyID,
                                      GetApplicationEventTarget(), 0, &ref)
        if err != noErr {
            err = RegisterEventHotKey(spec.keyCode, spec.modifiers, hotKeyID,
                                      GetEventDispatcherTarget(), 0, &ref)
        }
        if err == noErr, let ref {
            carbonRefs[id] = ref
            hotkeyLog.info("registered \(spec.display, privacy: .public) id=\(id) via Carbon")
        } else {
            // err -9878 (eventHotKeyExistsErr) means another app owns the combo.
            hotkeyLog.error("Carbon registration FAILED for \(spec.display, privacy: .public) err=\(err)")
        }
        return id
    }

    func unregisterAll() {
        for (_, ref) in carbonRefs { UnregisterEventHotKey(ref) }
        carbonRefs.removeAll()
        bindings.removeAll()
    }

    // MARK: dispatch

    /// Runs the binding, ignoring a second delivery of the same press.
    fileprivate func fire(id: UInt32, source: String) {
        let now = CFAbsoluteTimeGetCurrent()
        if lastFire.id == id, now - lastFire.at < 0.25 {
            hotkeyLog.debug("ignored duplicate \(source, privacy: .public) fire id=\(id)")
            return
        }
        lastFire = (id, now)
        if source == "carbon" { carbonEverFired = true } else { tapEverFired = true }
        hotkeyLog.info("FIRE id=\(id) via \(source, privacy: .public)")
        bindings[id]?.action()
    }

    // MARK: Carbon path

    private func installCarbonHandlers() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.fire(id: id, source: "carbon") }
            }
            return noErr
        }
        // Cover both targets: whichever the registration ends up on, one of
        // these sees the event.
        for target in [GetApplicationEventTarget(), GetEventDispatcherTarget()] {
            var ref: EventHandlerRef?
            let err = InstallEventHandler(target, callback, 1, &eventType, nil, &ref)
            if err == noErr, let ref { handlers.append(ref) }
        }
        hotkeyLog.info("installed \(self.handlers.count) Carbon handler(s)")
    }

    // MARK: event-tap path

    /// Starts the CGEvent tap. Requires Accessibility; safe to call repeatedly.
    @discardableResult
    func startTapIfPossible() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else {
            hotkeyLog.info("event tap not started — Accessibility not granted")
            return false
        }
        let mask = (1 << CGEventType.keyDown.rawValue)
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,          // observe only; never swallow keys
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in
                if type == .keyDown {
                    let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                    // Only the modifier bits users can actually press.
                    let flags = event.flags.intersection([.maskCommand, .maskControl,
                                                          .maskAlternate, .maskShift])
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            HotKeyCenter.shared.tapSaw(keyCode: code, flags: flags)
                        }
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            hotkeyLog.error("CGEvent.tapCreate returned nil despite Accessibility")
            return false
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        tapSource = src
        hotkeyLog.info("event tap active")
        return true
    }

    func stopTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let src = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        tapSource = nil
    }

    fileprivate func tapSaw(keyCode: UInt32, flags: CGEventFlags) {
        for (id, b) in bindings where b.spec.keyCode == keyCode && b.spec.cgFlags == flags {
            fire(id: id, source: "tap")
            return
        }
    }
}
