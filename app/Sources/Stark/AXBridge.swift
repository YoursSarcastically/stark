import AppKit
import ApplicationServices

/// Reads the focused text field through the Accessibility API: what's been
/// typed before the caret, and where the caret sits on screen.
///
/// Everything here is best-effort. Native AppKit apps answer these queries
/// well; Chromium and Electron answer only after `AXManualAccessibility` is
/// set on them; some apps (Catalyst, custom-drawn editors, terminals) never
/// answer at all. Each accessor therefore returns nil rather than guessing,
/// and the engine degrades — inline ghost text where the caret is known, a
/// pinned HUD where only the window is known, nothing at all where neither is.
@MainActor
enum AXBridge {

    static var trusted: Bool { AXIsProcessTrusted() }

    // MARK: focus

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        return (focused as! AXUIElement)
    }

    /// Password fields must never be read, let alone sent to a model.
    static func isSecure(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        // No kAX constant for this role; the string is the documented identifier.
        if (roleRef as? String) == "AXSecureTextField" { return true }
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        return (subroleRef as? String) == "AXSecureTextField"
    }

    static func isTextInput(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString,
                                         &roleRef) == .success,
           let role = roleRef as? String {
            let texty: Set<String> = [kAXTextFieldRole as String,
                                      kAXTextAreaRole as String,
                                      kAXComboBoxRole as String,
                                      "AXSearchField"]
            if texty.contains(role) { return true }
        }
        // Web content reports generic roles, so fall back to "can I set its value".
        var settable = DarwinBoolean(false)
        let err = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    // MARK: text

    static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Caret position as a character offset, from the selection range.
    static func caretOffset(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        // A non-empty selection means the user is selecting, not typing.
        guard range.length == 0 else { return nil }
        return range.location
    }

    /// The last `maxChars` characters before the caret — the text to continue.
    static func textBeforeCaret(of element: AXUIElement, maxChars: Int) -> String? {
        guard let full = stringValue(of: element), let caret = caretOffset(of: element)
        else { return nil }
        let chars = Array(full)
        guard caret >= 0, caret <= chars.count else { return nil }
        let start = max(0, caret - maxChars)
        return String(chars[start..<caret])
    }

    /// True when the caret sits at the very end of the field's text. Suggesting
    /// mid-sentence is usually wrong — the user is editing, not composing.
    static func caretAtEnd(of element: AXUIElement) -> Bool {
        guard let full = stringValue(of: element),
              let caret = caretOffset(of: element) else { return false }
        return caret >= full.count
    }

    // MARK: geometry

    /// Screen rect of the caret, in Cocoa (bottom-left origin) coordinates.
    ///
    /// AX reports rects in "screen" coordinates with a TOP-left origin, so the
    /// y axis has to be flipped against the primary display before an NSWindow
    /// can be placed there.
    static func caretRect(of element: AXUIElement) -> CGRect? {
        guard let caret = caretOffset(of: element) else { return nil }

        // The zero-length rect at the caret is the direct answer, but many
        // implementations return an empty or nonsense rect for it. The bounds
        // of the *preceding* character are a real rendered glyph and far more
        // reliable, so they act as both fallback and sanity check.
        let zero = boundsForRange(element, location: caret, length: 0)
        let anchor = caret > 0
            ? boundsForRange(element, location: caret - 1, length: 1)
                .map { CGRect(x: $0.maxX, y: $0.minY, width: 1, height: $0.height) }
            : nil

        let chosen: CGRect?
        if let z = zero, isPlausible(z) {
            if let a = anchor, abs(z.minX - a.maxX) > 24 || abs(z.minY - a.minY) > 6 {
                chosen = a          // they disagree; trust the real glyph
            } else {
                chosen = z
            }
        } else {
            chosen = anchor
        }
        guard let rect = chosen, isPlausible(rect) else { return nil }
        return flipToCocoa(rect)
    }

    private static func boundsForRange(_ element: AXUIElement,
                                       location: Int, length: Int) -> CGRect? {
        guard location >= 0 else { return nil }
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString,
                value, &boundsRef) == .success, let boundsRef else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Rejects the empty and absurd rects AX hands back when it doesn't really
    /// know: off-screen origins, zero height, or a "line" taller than a window.
    private static func isPlausible(_ r: CGRect) -> Bool {
        guard r.height > 2, r.height < 200, r.width < 2000 else { return false }
        guard r.origin.x.isFinite, r.origin.y.isFinite else { return false }
        guard r.origin.x > -20000, r.origin.y > -20000 else { return false }
        return NSScreen.screens.contains { screen in
            screen.frame.intersects(flipToCocoa(r).insetBy(dx: -2, dy: -2))
        }
    }

    /// AX uses a top-left origin on the primary screen; Cocoa windows don't.
    /// The screen that defines the global origin — the one whose frame starts
    /// at (0,0). `NSScreen.screens.first` is *usually* this but is not
    /// guaranteed to be, and on a multi-display setup picking the wrong one
    /// offsets every caret by the height difference between the two screens.
    private static var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }

    /// Accessibility reports rects with a TOP-left origin anchored at the
    /// primary screen; Cocoa windows use a bottom-left origin in the same
    /// global space. The flip is against the primary screen's height for every
    /// display, not the display the rect happens to be on.
    private static func flipToCocoa(_ r: CGRect) -> CGRect {
        guard let primary = primaryScreen else { return r }
        let maxY = primary.frame.maxY
        return CGRect(x: r.origin.x, y: maxY - r.origin.y - r.height,
                      width: r.width, height: r.height)
    }

    /// The font actually used at the caret, so ghost text can match the field
    /// instead of guessing a system font that looks pasted-on.
    static func fontAtCaret(of element: AXUIElement, caret: Int) -> NSFont? {
        func font(at location: Int) -> NSFont? {
            guard location >= 0 else { return nil }
            var range = CFRange(location: location, length: 1)
            guard let value = AXValueCreate(.cfRange, &range) else { return nil }
            var ref: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                    element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                    value, &ref) == .success,
                  let attributed = ref as? NSAttributedString, attributed.length > 0
            else { return nil }
            return attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        }
        return font(at: caret - 1) ?? font(at: caret)
    }

    /// Screen frame of an element, in Cocoa coordinates.
    ///
    /// Reported by far more apps than caret bounds are: a field that refuses
    /// `kAXBoundsForRange` will usually still say where it *is*. That makes it
    /// a much better anchor than the window — placing relative to the window
    /// guesses at where the input sits, and guessed wrong often enough to drop
    /// the suggestion on top of the very box being typed into.
    static func elementFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString,
                                            &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString,
                                            &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width > 1, size.height > 1 else { return nil }
        return flipToCocoa(CGRect(origin: origin, size: size))
    }

    /// Frame of the focused window, as a last-resort anchor for the HUD.
    static func focusedWindowFrame() -> CGRect? {
        guard let element = focusedElement() else { return nil }
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXWindowAttribute as CFString, &winRef) == .success,
              let winRef else { return nil }
        let window = winRef as! AXUIElement
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString,
                                            &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString,
                                            &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return flipToCocoa(CGRect(origin: origin, size: size))
    }

    // MARK: Chromium / Electron

    /// Chrome, VS Code, Slack, Discord, Notion and everything else built on
    /// Chromium expose an almost empty accessibility tree until a client asks
    /// for the full one. Setting these two attributes on the *application*
    /// element is what makes `stringValue`/`caretRect` start returning real
    /// data there — without it, completion silently does nothing in half the
    /// apps people actually write in.
    private static var enabledPIDs = Set<pid_t>()

    static func enableEnhancedAccessibility(pid: pid_t) {
        guard !enabledPIDs.contains(pid) else { return }
        enabledPIDs.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
}
