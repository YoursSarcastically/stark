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
    /// A suggestion that outlives the moment it was made is clutter: the user
    /// has moved on, but a card is still sitting over their screen claiming to
    /// describe what they were typing.
    private var expiryTimer: Timer?
    /// Long enough to read a sentence and decide, not so long that a suggestion
    /// you have already typed past is still sitting there. Two seconds was not
    /// enough to finish reading one.
    private let suggestionLifetime: TimeInterval = 8
    private let streamingBackstop: TimeInterval = 12
    /// Deliberate pointer input — a click, a scroll, a pinch — means attention
    /// has left the keyboard, so the suggestion is stale.
    private var mouseMonitor: Any?

    private var enabled = false
    var isEnabled: Bool { enabled }
    /// Set by Escape, cleared when the focus moves or the field is emptied.
    private var suppressed = false

    /// What we have watched the user type since the last reset.
    ///
    /// The Accessibility API is the *preferred* source for the text before the
    /// caret, but plenty of apps lie: terminals, custom editors and some
    /// Electron surfaces report an empty kAXValue or a caret offset of 0 while
    /// the field visibly contains a sentence. Typing "hi how are you" into one
    /// of those yielded "0 chars" from AX, so nothing was ever predicted.
    ///
    /// The keystroke tap sees every character regardless of what the app is
    /// willing to admit, so this buffer works everywhere the tap does — which
    /// is everywhere. AX is used when it returns MORE than we have (it knows
    /// about text typed before Stark started watching, or pasted in); otherwise
    /// this wins.
    private var typed = ""
    /// Last length AX reported for the focused field, used to spot the field
    /// being emptied (message sent, document cleared) without trusting AX's
    /// absolute values, which several apps get wrong.
    private var lastAXLength: Int?
    /// When the buffer last grew, and the frame of the field it was typed into.
    /// Both exist to answer one question: is what I remember typing still on
    /// the screen in front of the user?
    private var lastKeystrokeAt = Date.distantPast
    private var lastFieldFrame: CGRect?
    /// A sentence typed half a minute ago and left behind is not context, it is
    /// a ghost. Clearing the app's buffer on app switch was not enough: moving
    /// between two fields *inside* one app kept it, which is how a LinkedIn
    /// composer with nothing in it was offered the end of a message typed in a
    /// different box entirely.
    private let bufferLifetime: TimeInterval = 25

    /// How long the user must pause before we spend a request.
    private let debounce: TimeInterval = 0.12
    /// Minimum characters before predicting.
    ///
    /// This started at 12 and was simply wrong: real messages are short, and
    /// "Hi how are" is 10 characters, so the engine sat silent through exactly
    /// the sentences people actually type. Four is about the point where a
    /// continuation stops being a coin flip — "Hi h" has no signal, "Hi how"
    /// does.
    private let minPrefix = 3
    private let maxPrefix = 480

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
        tap.onKey = { [weak self] code, chars, isDeletion in
            self?.handle(keyCode: code, characters: chars, isDeletion: isDeletion)
        }
        tap.onIntercept = { [weak self] which in
            guard let self else { return }
            switch which {
            case .accept:
                completionLog.info("tab accept: \(self.suggestion, privacy: .public)")
                self.acceptAll()
            case .dismiss:
                // Rule 4: Escape dismisses for the rest of this field, not just
                // for this one suggestion — otherwise it reappears on the next
                // keystroke and the gesture means nothing.
                self.suppressed = true
                completionLog.debug("suppressed for this field (esc)")
                self.clearSuggestion()
            case .none: break
            }
        }
        // Watch focus changes here instead of asking NSWorkspace on every
        // keystroke: that lookup is cross-process, and doing it inside the tap
        // callback was slow enough to drop characters mid-word.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication
                    completionLog.debug("focus -> \(app?.bundleIdentifier ?? "?", privacy: .public), buffer cleared")
                    self.typed = ""
                    self.suppressed = false
                    self.clearSuggestion()
                    // Electron/Chromium expose nothing until asked; do it once
                    // per app, on activation, not per keystroke.
                    if let pid = app?.processIdentifier {
                        AXBridge.enableEnhancedAccessibility(pid: pid)
                    }
                }
            }
        // Listen-only, on the main thread: a global NSEvent monitor never sits in
        // front of the event like the keyboard tap does, so watching every mouse
        // move here costs nothing the user can feel.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            // Clicks and scrolls only. Plain movement was too noisy a signal —
            // the pointer drifts while reading, and killing the suggestion for
            // that made it feel like it was vanishing at random.
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                       .scrollWheel, .magnify, .swipe]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.overlay.isVisible else { return }
                completionLog.debug("dismissed: pointer input")
                self.clearSuggestion()
            }
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
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        cancelPending()
        clearSuggestion()
        enabled = false
        completionLog.info("predictive typing stopped")
    }

    // MARK: key handling

    /// Runs on the main actor, AFTER the keystroke has already reached the app.
    /// Nothing here can delay typing.
    private func handle(keyCode: Int64, characters: String, isDeletion: Bool) {
        // Arrow keys and Return move the caret; any suggestion is now stale.
        // Return sends/commits in most apps and Escape abandons; either way the
        // text the buffer describes is gone. Arrows move the caret elsewhere.
        if (123...126).contains(keyCode) || keyCode == 36 || keyCode == 53 {
            typed = ""
            clearSuggestion()
            return
        }
        clearSuggestion()
        updateTypedBuffer(characters: characters, isDeletion: isDeletion)
        schedulePrediction()
    }

    /// Keep `typed` in step with the keystroke stream. Deliberately simple:
    /// this is a hint for the model, not a model of the document. Focus changes
    /// reset it via the workspace notification rather than a per-keystroke
    /// lookup, which is what used to stall typing.
    private func updateTypedBuffer(characters: String, isDeletion: Bool) {
        if isDeletion {
            if !typed.isEmpty { typed.removeLast() }
            return
        }
        guard !characters.isEmpty else { return }
        // Return/newline starts a fresh thought.
        if characters == "\r" || characters == "\n" {
            typed = ""
            return
        }
        typed += characters
        lastKeystrokeAt = Date()
        if typed.count > maxPrefix { typed.removeFirst(typed.count - maxPrefix) }
        completionLog.debug("buffer[\(self.typed.count)] = \(self.typed, privacy: .public)")
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
    /// Why the last attempt produced nothing. Predictive typing fails silently
    /// by nature — there is no error, just no suggestion — so the reason has to
    /// be recoverable from the log or it's undebuggable in the field.
    private var lastBail = ""
    private func bail(_ reason: String) -> (prefix: String, element: AXUIElement?)? {
        if reason != lastBail {
            lastBail = reason
            completionLog.info("no suggestion: \(reason, privacy: .public)")
        }
        return nil
    }

    private func context() -> (prefix: String, element: AXUIElement?)? {
        // Optional by design: apps that expose no accessibility tree still get
        // suggestions from the keystroke buffer, shown as a chip rather than
        // inline ghost text.
        let element = AXBridge.focusedElement()

        // Field changed under us, or the app says the field is now empty.
        // `stringValue` distinguishes "" (definitely empty) from nil (the app
        // won't say), so this fires only on real evidence and never punishes
        // the apps that report nothing. Without it, sending a message left the
        // buffer intact and the next suggestion came from text no longer on
        // screen — a suggestion appearing over an empty field.
        // Detecting "the field was emptied" has to be done on a CHANGE, never on
        // an absolute reading. Google Docs reports an empty AX value even with a
        // sentence on screen, so treating empty-as-empty cleared the buffer on
        // every prediction and nothing was ever suggested. Likewise element
        // identity: web content hands back a fresh AXUIElement each query, so
        // CFEqual comparisons fire constantly and are useless here.
        //
        // A DROP is real evidence: AX said 20 characters a moment ago and says 0
        // now, so the message was sent or the field cleared. An app that always
        // says 0 never triggers it.
        // Stale by time. Nothing else here can catch a buffer whose field was
        // closed, scrolled away, or replaced by one the app reports nothing for.
        if !typed.isEmpty, Date().timeIntervalSince(lastKeystrokeAt) > bufferLifetime {
            completionLog.debug("buffer expired after \(self.bufferLifetime)s — cleared")
            typed = ""
            return bail("buffer went stale")
        }

        // Stale by place. A different field is a different rectangle, and that
        // survives web content handing back a fresh AXUIElement every query,
        // which makes identity comparisons useless.
        if let frame = element.flatMap({ AXBridge.elementFrame(of: $0) }) {
            if let previous = lastFieldFrame, !typed.isEmpty,
               abs(previous.origin.x - frame.origin.x) > 6
                || abs(previous.origin.y - frame.origin.y) > 6
                || abs(previous.width - frame.width) > 6
                || abs(previous.height - frame.height) > 24 {
                completionLog.debug("field moved — buffer cleared")
                typed = ""
                lastFieldFrame = frame
                lastAXLength = nil
                return bail("focus moved to another field")
            }
            lastFieldFrame = frame
        }

        let axLength = element.flatMap { AXBridge.stringValue(of: $0)?.count }
        if let axLength, let previous = lastAXLength, previous > 2, axLength == 0, !typed.isEmpty {
            completionLog.debug("field emptied (\(previous) -> 0) — buffer cleared")
            typed = ""
            suppressed = false
            lastAXLength = axLength
            return bail("field was cleared")
        }
        if let axLength { lastAXLength = axLength }

        // Never read, never send, never suggest into a password field.
        if let element, AXBridge.isSecure(element) {
            typed = ""
            return bail("secure field")
        }

        // Trust whichever source has seen more of the sentence. AX wins when it
        // works (it knows about text that predates Stark, and about pastes);
        // the keystroke buffer covers every app where AX lies.
        let axPrefix = element.flatMap {
            AXBridge.textBeforeCaret(of: $0, maxChars: maxPrefix)
        } ?? ""
        // Whichever source saw more of the sentence wins. Google Docs and
        // similar report a stale or truncated value (1 char while 4 were
        // typed), so this is usually the keystroke buffer.
        let useAX = axPrefix.count > typed.count
        let prefix = useAX ? axPrefix : typed
        guard prefix.count >= minPrefix else {
            return bail("only \(prefix.count) chars available (ax \(axPrefix.count), typed \(typed.count)), need \(minPrefix)")
        }
        // The caret check may ONLY be applied to the source we actually used.
        // Applying it to AX while predicting from the keystroke buffer is what
        // silenced Google Docs: its caret data is as unreliable as its text, so
        // a check against it rejected perfectly good buffer-derived prefixes.
        if useAX, let element, !AXBridge.caretAtEnd(of: element) {
            return bail("caret is mid-text, not at the end")
        }
        lastBail = ""
        return (prefix, element)
    }

    private func predict() {
        guard enabled, !suppressed, let (prefix, element) = context() else { return }
        guard prefix != suggestedFor else { return }


        pending = Task { [weak self] in
            guard let self else { return }
            do {
                // Stream it: the card appears with the first token instead of
                // after the whole generation, which is most of the perceived
                // latency on a machine where a request takes ~0.5s.
                let text = try await self.client.completeStreaming(prefix: prefix) { partial in
                    guard !Task.isCancelled else { return }
                    // Only keep streaming into the card if the user hasn't moved on.
                    guard let (now, el) = self.context(), now == prefix else { return }
                    self.present(partial, prefix: prefix, element: el, streaming: true)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let (now, el) = self.context(), now == prefix else { return }
                    self.present(text, prefix: prefix, element: el, streaming: false)
                }
            } catch {
                completionLog.debug("prediction failed: \(error.localizedDescription)")
            }
        }
    }

    private func present(_ raw: String, prefix: String, element: AXUIElement?,
                         streaming: Bool = false) {
        let text = Self.clean(raw, prefix: prefix)
        // While streaming, an empty cleaned string just means the first token
        // was the overlap being stripped — keep the card up rather than
        // flickering it away. Once finished, empty means there is nothing to
        // offer, so the placeholder must come down.
        guard !text.isEmpty || streaming else {
            clearSuggestion()
            return
        }
        suggestion = text
        suggestedFor = prefix
        // Tab may only be swallowed once there is something to accept.
        tap.setArmed(!text.isEmpty)
        // Anchor the pointer where it is now, and start the clock once the
        // model has actually finished — expiring mid-stream would kill a
        // suggestion the user never got to see.
        expiryTimer?.invalidate()
        // A finished suggestion gets the short lifetime; one still streaming
        // gets a long backstop, because a stream that errors or stalls would
        // otherwise leave the card on screen forever.
        let lifetime = streaming ? streamingBackstop : suggestionLifetime
        expiryTimer = Timer.scheduledTimer(withTimeInterval: lifetime,
                                           repeats: false) { _ in
            Task { @MainActor [weak self] in
                completionLog.debug("dismissed: suggestion expired")
                self?.clearSuggestion()
            }
        }

        // At the caret where the app reports it, so the pill grows out of the
        // cursor. Apps that won't report caret geometry (Docs, much of Electron)
        // fall back to a fixed position low in the window.
        // The glass card, positioned clear of the field it belongs to.
        overlay.showCard(text,
                         caret: element.flatMap { AXBridge.caretRect(of: $0) },
                         field: element.flatMap { AXBridge.elementFrame(of: $0) },
                         window: AXBridge.focusedWindowFrame(),
                         streaming: streaming)
    }

    /// A fixed position over the focused window rather than a caret- or
    /// field-relative one.
    ///
    /// Chasing the caret sounds better than it reads: the panel jumps on every
    /// keystroke, and the apps that most need suggestions are exactly the ones
    /// that report caret geometry badly or not at all — Google Docs claimed one
    /// character while four had been typed. Anchoring to the field instead put
    /// the panel over the composer being typed into. A steady position over the
    /// document is somewhere the eye learns once and can then ignore.
    /// Trims the model's habits: stop tokens, quotes, a repeat of the prefix's
    /// last words, and anything past the first sentence.
    static func clean(_ raw: String, prefix: String) -> String {
        var s = raw
        for junk in ["<|im_end|>", "<|endoftext|>", "<think>", "</think>"] {
            s = s.replacingOccurrences(of: junk, with: "")
        }
        s = s.replacingOccurrences(of: "\n", with: " ")
        if s.hasPrefix("\"") && s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }

        // Models very often restate the last words of the prompt: the prefix
        // "hi how are you" comes back as "are you doing fine?", which would
        // paste as "hi how are you are you doing fine?". Strip the LONGEST
        // suffix of the prefix that the suggestion begins with — an exact
        // fixed-width match misses every partial overlap like this one.
        let lowerPrefix = prefix.lowercased()
        let lowerSuggestion = s.lowercased()
        var overlap = 0
        let maxOverlap = min(lowerPrefix.count, lowerSuggestion.count)
        if maxOverlap > 0 {
            for n in stride(from: maxOverlap, through: 2, by: -1) {
                let tail = String(lowerPrefix.suffix(n))
                if lowerSuggestion.hasPrefix(tail) {
                    overlap = n
                    break
                }
            }
        }
        if overlap > 0 { s = String(s.dropFirst(overlap)) }
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
    /// One Tab takes the whole suggestion. Word-by-word acceptance sounds
    /// considerate but in practice means three or four Tabs for one sentence,
    /// each with a clipboard round trip, and the card re-anchoring underneath
    /// the user between them.
    private func acceptAll() {
        let text = suggestion
        guard !text.isEmpty else { return }
        // Acknowledge the keypress, then let the capsule fade on its own — the
        // press-in has to be visible before the panel goes away.
        // Clear FIRST: insertion is asynchronous, and leaving the tap armed
        // means a second Tab lands on a suggestion that is already being typed.
        clearSuggestion()
        typed += text
        suggestedFor = typed
        TextTyper.insert(text)
    }

    private func clearSuggestion() {
        suggestion = ""
        suggestedFor = ""
        expiryTimer?.invalidate()
        expiryTimer = nil
        overlay.hide()
        tap.setArmed(false)
    }
}
