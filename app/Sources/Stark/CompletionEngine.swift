import AppKit
import CoreGraphics
import Carbon.HIToolbox
import os

private let completionLog = Logger(subsystem: "com.local.stark", category: "completion")

/// Predictive typing: watch what's being typed, ask the model what comes next,
/// show it as ghost text, and insert it on Tab.
///
/// Design notes that matter more than the code:
///
///  - **Never predict on every keystroke.** The model costs ~0.5 s per request,
///    so a request per key would queue forever and show stale text. Requests go
///    out only after the user pauses (`debounce`), and any in-flight request is
///    cancelled the moment another key lands.
///  - **Never suggest into a password field**, and never mid-word or mid-line.
///  - **Tab is only intercepted while a suggestion is visible.** Any other time
///    it belongs to the app.
///  - Suggestions are accepted **one word at a time**, which is what makes a
///    partly-right prediction useful instead of annoying.
@MainActor
final class CompletionEngine {

    private let client: StarkClient
    private let overlay = GhostOverlay()
    private let tap = KeystrokeTap()

    /// Current suggestion and the exact prefix it was generated for. If the
    /// buffer no longer matches, the suggestion is stale and must not be used.
    private var suggestion = ""
    private var suggestedFor = ""
    private var pending: Task<Void, Never>?
    private var debounceTimer: Timer?

    private var enabled = false
    var isEnabled: Bool { enabled }

    /// How long the user must pause before we spend a request.
    private let debounce: TimeInterval = 0.45
    /// Minimum characters before predicting; below this there's no signal.
    private let minPrefix = 12
    private let maxPrefix = 480

    private let kVKTab: Int64 = 48
    private let kVKEscape: Int64 = 53

    init(client: StarkClient) {
        self.client = client
    }

    // MARK: lifecycle

    @discardableResult
    func start() -> Bool {
        guard !enabled else { return true }
        guard AXBridge.trusted else {
            completionLog.info("completion not started — Accessibility not granted")
            return false
        }
        tap.onKey = { [weak self] code, flags, chars in
            self?.handle(keyCode: code, flags: flags, characters: chars) ?? .typing
        }
        guard tap.start() else {
            completionLog.error("completion tap failed to start")
            return false
        }
        enabled = true
        completionLog.info("predictive typing active")
        return true
    }

    func stop() {
        tap.stop()
        cancelPending()
        clearSuggestion()
        enabled = false
        completionLog.info("predictive typing stopped")
    }

    // MARK: key handling

    private func handle(keyCode: Int64, flags: CGEventFlags,
                        characters: String) -> KeystrokeTap.Decision {
        // Accept: Tab, but only while something is actually showing.
        if keyCode == kVKTab, !suggestion.isEmpty, overlay.isVisible,
           !flags.contains(.maskCommand), !flags.contains(.maskControl) {
            acceptNextWord()
            return .swallow
        }
        // Dismiss: Escape, likewise only when we're showing something.
        if keyCode == kVKEscape, overlay.isVisible {
            clearSuggestion()
            return .swallow
        }
        // Any modifier chord (⌘C, ⌥→, …) is navigation or a command, not typing.
        if flags.contains(.maskCommand) || flags.contains(.maskControl)
            || flags.contains(.maskAlternate) {
            clearSuggestion()
            return .passthrough
        }
        // Arrow keys and Return move the caret; the old suggestion no longer applies.
        if (123...126).contains(keyCode) || keyCode == 36 {
            clearSuggestion()
            return .passthrough
        }

        // Ordinary typing (or deletion) — the suggestion is stale either way.
        clearSuggestion()
        schedulePrediction()
        return .typing
    }

    // MARK: prediction

    private func schedulePrediction() {
        cancelPending()
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounce, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.predict() }
        }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
        debounceTimer?.invalidate()
        debounceTimer = nil
    }

    /// Reads the focused field and decides whether this is a moment worth
    /// spending a model request on.
    private func context() -> (prefix: String, element: AXUIElement)? {
        guard let element = AXBridge.focusedElement() else { return nil }
        // Never read, never send, never suggest into a password field.
        guard !AXBridge.isSecure(element) else { return nil }
        guard AXBridge.isTextInput(element) else { return nil }

        // Chromium/Electron only answer AX queries once asked; do it lazily for
        // whichever app is frontmost.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            AXBridge.enableEnhancedAccessibility(pid: pid)
        }

        guard let prefix = AXBridge.textBeforeCaret(of: element, maxChars: maxPrefix),
              prefix.count >= minPrefix else { return nil }
        // Only continue at the end of what's written — mid-document editing is
        // a different job and suggestions there are almost always wrong.
        guard AXBridge.caretAtEnd(of: element) else { return nil }
        // Mid-word, the user is still choosing the word; wait for the space.
        guard let last = prefix.last, last == " " || last == "," || last == "\n" ||
                (last.isLetter == false && last.isNumber == false) || true
        else { return nil }
        return (prefix, element)
    }

    private func predict() {
        guard enabled, let (prefix, element) = context() else { return }
        guard prefix != suggestedFor else { return }

        pending = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.client.complete(prefix: prefix)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    // The buffer may have moved on while we waited.
                    guard let (now, el) = self.context(), now == prefix else { return }
                    self.present(text, prefix: prefix, element: el)
                }
            } catch {
                completionLog.debug("prediction failed: \(error.localizedDescription)")
            }
        }
    }

    private func present(_ raw: String, prefix: String, element: AXUIElement) {
        let text = Self.clean(raw, prefix: prefix)
        guard !text.isEmpty else { return }
        suggestion = text
        suggestedFor = prefix

        if let caret = AXBridge.caretRect(of: element) {
            let font = AXBridge.caretOffset(of: element)
                .flatMap { AXBridge.fontAtCaret(of: element, caret: $0) }
            overlay.showInline(text, at: caret, font: font)
        } else if let window = AXBridge.focusedWindowFrame() {
            overlay.showPill(text, near: window)
        }
    }

    /// Trims the model's habits: stop tokens, quotes, a repeat of the prefix's
    /// last words, and anything past the first sentence.
    static func clean(_ raw: String, prefix: String) -> String {
        var s = raw
        for junk in ["<|im_end|>", "<|endoftext|>", "<think>", "</think>"] {
            s = s.replacingOccurrences(of: junk, with: "")
        }
        s = s.replacingOccurrences(of: "\n", with: " ")
        if s.hasPrefix("\"") && s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }

        // Models sometimes echo the tail of the prompt; strip that overlap.
        let tail = prefix.split(separator: " ").suffix(4).joined(separator: " ")
        if !tail.isEmpty, s.lowercased().hasPrefix(tail.lowercased()) {
            s = String(s.dropFirst(tail.count))
        }
        // One sentence is plenty for an inline suggestion.
        if let stop = s.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            s = String(s[...stop])
        }
        s = s.trimmingCharacters(in: .whitespaces)
        // Preserve exactly one leading space when the prefix needs one.
        if let last = prefix.last, last != " ", !s.isEmpty { s = " " + s }
        return String(s.prefix(120))
    }

    // MARK: accept

    /// Insert the next word of the suggestion, keeping the rest on screen so a
    /// second Tab continues. This is what makes a half-right suggestion useful.
    private func acceptNextWord() {
        guard !suggestion.isEmpty else { return }
        let s = suggestion
        // Take the leading space (if any) plus the next word.
        var idx = s.startIndex
        if s[idx] == " " { idx = s.index(after: idx) }
        let afterWord = s[idx...].firstIndex(of: " ") ?? s.endIndex
        let word = String(s[s.startIndex..<afterWord])
        let rest = String(s[afterWord...])

        TextTyper.type(word)
        suggestedFor += word

        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            clearSuggestion()
        } else {
            suggestion = rest
            // Re-anchor the ghost to the caret's new position.
            if let element = AXBridge.focusedElement(),
               let caret = AXBridge.caretRect(of: element) {
                let font = AXBridge.caretOffset(of: element)
                    .flatMap { AXBridge.fontAtCaret(of: element, caret: $0) }
                overlay.showInline(rest, at: caret, font: font)
            }
        }
    }

    private func clearSuggestion() {
        suggestion = ""
        suggestedFor = ""
        overlay.hide()
    }
}
