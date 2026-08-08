import AppKit
import CoreGraphics

/// System-wide keyboard observer for predictive typing.
///
/// This is an *active* `CGEventTap` (`.defaultTap`), unlike the listen-only one
/// `HotKeyCenter` uses, because accepting a suggestion means swallowing the Tab
/// keypress so the app never sees it. Tab is only ever swallowed while a
/// suggestion is actually on screen; the rest of the time every key passes
/// through untouched. Requires Accessibility.
final class KeystrokeTap {

    /// What the engine wants done with a key it recognises.
    enum Decision {
        case swallow       // we acted on it; the app must not see it
        case passthrough   // let it through, and don't treat it as typing
        case typing        // ordinary text input
    }

    /// Called on the main actor for every keyDown. Returning `.swallow`
    /// consumes the event.
    var onKey: ((_ keyCode: Int64, _ flags: CGEventFlags, _ characters: String) -> Decision)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Stamped onto events we synthesize so the tap can ignore its own output —
    /// otherwise inserting a suggestion looks exactly like the user typing it,
    /// and the engine immediately predicts from its own prediction.
    static let injectedMarker: Int64 = 0x57A2_C0DE

    private let kVKDelete: Int64 = 51
    private let kVKForwardDelete: Int64 = 117

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeystrokeTap>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else { return false }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        source = src
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that takes too long in its callback. Re-arm
        // rather than silently dying — this is why the callback below does no
        // work beyond a dictionary lookup.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        if event.getIntegerValueField(.eventSourceUserData) == Self.injectedMarker {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        var characters = ""
        let hasCommandLike = flags.contains(.maskCommand) || flags.contains(.maskControl)
        if !hasCommandLike, keyCode != kVKDelete, keyCode != kVKForwardDelete {
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8,
                                           actualStringLength: &length,
                                           unicodeString: &buffer)
            if length > 0 { characters = String(utf16CodeUnits: buffer, count: length) }
        }

        // The tap callback runs on the main run loop, so the handler is already
        // on the main actor — it must stay synchronous to decide swallow vs pass.
        let decision = MainActor.assumeIsolated {
            onKey?(keyCode, flags, characters) ?? .typing
        }
        return decision == .swallow ? nil : Unmanaged.passUnretained(event)
    }
}

/// Types text into the frontmost app by synthesising key events that carry the
/// Unicode string directly. Unlike the rewrite path this never touches the
/// pasteboard — accepting a word-by-word suggestion shouldn't clobber whatever
/// the user copied earlier.
@MainActor
enum TextTyper {
    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        // Chunked: CGEvent's unicode payload is bounded, and long strings sent
        // as one event get truncated by some apps.
        for chunk in text.chunked(into: 16) {
            var utf16 = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.setIntegerValueField(.eventSourceUserData, value: KeystrokeTap.injectedMarker)
            up.setIntegerValueField(.eventSourceUserData, value: KeystrokeTap.injectedMarker)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        guard count > size else { return [self] }
        var out: [String] = []
        var idx = startIndex
        while idx < endIndex {
            let end = index(idx, offsetBy: size, limitedBy: endIndex) ?? endIndex
            out.append(String(self[idx..<end]))
            idx = end
        }
        return out
    }
}
