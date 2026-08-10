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
        // Our own process only, mirroring `paste`. Elsewhere ⌘C is the source
        // of truth: an app that reports a stale kAXSelectedText would have us
        // rewrite text the user is no longer looking at, which is a worse
        // failure than the extra 30 ms a synthetic copy costs.
        if let element = AXBridge.focusedElement() {
            var pid: pid_t = 0
            var value: CFTypeRef?
            if AXUIElementGetPid(element, &pid) == .success,
               pid == ProcessInfo.processInfo.processIdentifier,
               AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
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

        // The Accessibility write is for Stark's own windows and nothing else.
        //
        // It exists for one reason: a synthetic ⌘V does not reach our own text
        // views, so the onboarding "try it" step produced a rewrite that landed
        // nowhere. Letting it run against every app was a mistake — Gmail and
        // other web editors report kAXSelectedText as settable, accept the
        // write, return .success, and then ignore it. The rewrite vanished with
        // no error anywhere, in the apps people use most.
        //
        // Checking the pid is the honest test. "Does this app implement AX text
        // writing properly" has no reliable answer; "is this our own process"
        // has an exact one.
        if let element = AXBridge.focusedElement() {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success,
               pid == ProcessInfo.processInfo.processIdentifier,
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
