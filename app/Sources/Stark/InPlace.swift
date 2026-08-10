import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Grabs the selection from the frontmost app and pastes rewrites back over
/// it via synthetic ⌘C/⌘V. Both directions preserve the user's clipboard.
/// Requires the Accessibility permission (System Settings → Privacy &
/// Security → Accessibility → Stark); without it Stark falls back to
/// clipboard mode.
@MainActor
enum InPlace {
    static var trusted: Bool { AXIsProcessTrusted() }

    private static var didPrompt = false

    /// Shows the system Accessibility prompt at most once per app run.
    static func promptOnce() {
        guard !didPrompt else { return }
        didPrompt = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Synthetic ⌘C to the frontmost app; nil when nothing is selected
    /// (the app never touches the pasteboard, so changeCount stays put).
    static func copySelection() async -> String? {
        // Ask the focused element what is selected before resorting to a
        // synthetic ⌘C. It is faster, never touches the pasteboard, and works
        // in the one place the keystroke reliably fails: Stark's own windows,
        // where posting ⌘C to ourselves does not reach the text view — which is
        // why the onboarding "try it" step showed clipboard contents instead of
        // the sentence the user had just selected.
        if let element = AXBridge.focusedElement() {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                             &value) == .success,
               let text = value as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }

        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let before = pb.changeCount
        postKey(UInt16(kVK_ANSI_C), flags: .maskCommand)
        var waited = 0
        while pb.changeCount == before && waited < 600 {
            try? await Task.sleep(for: .milliseconds(30))
            waited += 30
        }
        guard pb.changeCount != before else { return nil }
        let selection = pb.string(forType: .string)
        pb.clearContents()
        if let saved { pb.setString(saved, forType: .string) }
        guard let selection,
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return selection
    }

    /// Replaces the original selection: refocus the app, ⌘V the rewrite,
    /// then put the user's clipboard back.
    static func paste(_ text: String, into app: NSRunningApplication?) async {
        app?.activate()
        try? await Task.sleep(for: .milliseconds(250))

        // Write over the selection through the Accessibility API when the
        // focused element accepts it. This is the mirror of the read side: a
        // synthetic ⌘V does not reach Stark's own text views, so the onboarding
        // "try it" step produced a rewrite that never landed anywhere. It also
        // spares the pasteboard entirely in every app that supports it.
        // The settable check matters: several apps answer .success to a write
        // they then ignore, and silently swallowing the rewrite is worse than
        // falling through to ⌘V.
        if let element = AXBridge.focusedElement() {
            var settable = DarwinBoolean(false)
            let asked = AXUIElementIsAttributeSettable(element,
                                                       kAXSelectedTextAttribute as CFString,
                                                       &settable)
            if asked == .success, settable.boolValue,
               AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            text as CFTypeRef) == .success {
                return
            }
        }

        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        try? await Task.sleep(for: .milliseconds(50))
        postKey(UInt16(kVK_ANSI_V), flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(400))
        pb.clearContents()
        if let saved { pb.setString(saved, forType: .string) }
    }

    /// Undo the last paste-back: refocus the app and send its native ⌘Z —
    /// the paste is a single undo step in virtually every text view.
    static func undo(in app: NSRunningApplication) async {
        app.activate()
        try? await Task.sleep(for: .milliseconds(250))
        postKey(UInt16(kVK_ANSI_Z), flags: .maskCommand)
    }

    private static func postKey(_ key: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
