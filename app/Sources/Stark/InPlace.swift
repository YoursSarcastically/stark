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
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        app?.activate()
        try? await Task.sleep(for: .milliseconds(250))
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
