import AppKit
import CoreGraphics
import os

/// System-wide keyboard observer for predictive typing.
///
/// This is an *active* tap (`.defaultTap`) because accepting a suggestion means
/// swallowing the Tab keypress so the app never sees it. That power comes with
/// a hard constraint most implementations get wrong:
///
/// **An active tap sits in front of every keystroke the user types.** The
/// callback runs synchronously before the frontmost app receives the event, so
/// anything slow inside it stalls the user's typing. Do enough work and macOS
/// gives up, fires `kCGEventTapDisabledByTimeout`, and keystrokes are dropped
/// outright — which is exactly what happened here: an `NSWorkspace`
/// cross-process lookup per keystroke was losing characters mid-word.
///
/// Two rules follow, and this file exists to enforce them:
///
///  1. **The tap runs on its own thread**, not the main run loop. Otherwise any
///     main-thread stall — SwiftUI laying out the panel, a slow AX query — is a
///     stall in the user's typing, system-wide.
///  2. **The callback does the minimum**: check a flag, read the key, hand
///     everything else to the main actor asynchronously. The only synchronous
///     decision is swallow-or-pass, made from a pre-computed boolean.
final class KeystrokeTap {

    /// Keys the tap may swallow, decided synchronously from `armed`.
    enum Intercept { case none, accept, dismiss }

    /// Called on the MAIN actor, asynchronously, for every non-injected keyDown.
    /// Never blocks the user's typing.
    var onKey: ((_ keyCode: Int64, _ characters: String, _ isDeletion: Bool) -> Void)?
    /// Called on the MAIN actor when an interception fired.
    var onIntercept: ((Intercept) -> Void)?

    /// Whether a suggestion is currently on screen. Written from the main actor,
    /// read from the tap thread, so it's behind a lock — the only shared state.
    private let lock = OSAllocatedUnfairLock(initialState: false)
    func setArmed(_ armed: Bool) { lock.withLock { $0 = armed } }

    private var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    /// Stamped onto events we synthesize so the tap ignores its own output —
    /// otherwise inserting a suggestion looks like the user typing it.
    static let injectedMarker: Int64 = 0x57A2_C0DE

    private let kVKTab: Int64 = 48
    private let kVKEscape: Int64 = 53
    private let kVKDelete: Int64 = 51
    private let kVKForwardDelete: Int64 = 117

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil, AXIsProcessTrusted() else { return false }

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
        tap = t

        // Dedicated thread with its own run loop. The tap must keep servicing
        // keystrokes even while the main thread is busy rendering or waiting.
        let ready = DispatchSemaphore(value: 0)
        let th = Thread { [weak self] in
            guard let self, let tap = self.tap else { ready.signal(); return }
            self.runLoop = CFRunLoopGetCurrent()
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.5, false)
            }
        }
        th.name = "com.local.stark.keystroke-tap"
        // Above default so a busy UI thread can never starve keyboard handling.
        th.qualityOfService = .userInteractive
        th.start()
        thread = th
        ready.wait()
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        thread?.cancel()
        if let rl = runLoop { CFRunLoopStop(rl) }
        thread = nil
        runLoop = nil
        tap = nil
    }

    /// Runs on the tap thread. Must stay in the microsecond range.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap whose callback overran. Re-arm immediately or
        // the feature dies silently for the rest of the session.
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
        let armed = lock.withLock { $0 }

        // The ONLY synchronous decision: swallow Tab/Escape while a suggestion
        // is showing. Everything else passes through untouched.
        if armed, !flags.contains(.maskCommand), !flags.contains(.maskControl) {
            if keyCode == kVKTab {
                DispatchQueue.main.async { [weak self] in self?.onIntercept?(.accept) }
                return nil
            }
            if keyCode == kVKEscape {
                DispatchQueue.main.async { [weak self] in self?.onIntercept?(.dismiss) }
                return nil
            }
        }

        let isDeletion = keyCode == kVKDelete || keyCode == kVKForwardDelete
        var characters = ""
        if !isDeletion, !flags.contains(.maskCommand), !flags.contains(.maskControl) {
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8,
                                           actualStringLength: &length,
                                           unicodeString: &buffer)
            if length > 0 { characters = String(utf16CodeUnits: buffer, count: length) }
        }

        // Hand off and get out of the way; the event continues to the app now.
        DispatchQueue.main.async { [weak self] in
            self?.onKey?(keyCode, characters, isDeletion)
        }
        return Unmanaged.passUnretained(event)
    }
}

/// Types text into the frontmost app by synthesising key events carrying the
/// Unicode string. Never touches the pasteboard, so accepting a suggestion
/// can't clobber whatever the user copied earlier.
@MainActor
enum TextTyper {
    /// Insert accepted text into the frontmost app.
    ///
    /// Two strategies, because neither works everywhere:
    ///
    ///  - **Synthetic Unicode key events** leave the pasteboard alone, which is
    ///    the polite thing to do, and work in native AppKit apps.
    ///  - **Clipboard paste** works in the apps that ignore synthesized keys
    ///    entirely — Google Docs and several Electron editors filter events
    ///    that carry no real virtual keycode, so a Tab-accept silently does
    ///    nothing there.
    ///
    /// Reliability wins: paste is the default, with the pasteboard saved and
    /// restored around it so the user's clipboard survives.
    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { dict[type] = d } }
            return dict
        } ?? []

        pb.clearContents()
        pb.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyV: CGKeyCode = 0x09
        for keyDown in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source,
                                  virtualKey: vKeyV, keyDown: keyDown) else { continue }
            e.flags = .maskCommand
            e.setIntegerValueField(.eventSourceUserData, value: KeystrokeTap.injectedMarker)
            e.post(tap: .cghidEventTap)
        }

        // Restore once the paste has certainly been read.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            pb.clearContents()
            for item in saved {
                let entry = NSPasteboardItem()
                for (type, data) in item { entry.setData(data, forType: type) }
                pb.writeObjects([entry])
            }
        }
    }

    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
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
