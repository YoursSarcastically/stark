import AppKit
import ApplicationServices

/// What the user is writing *in*, so suggestions can sound like it.
///
/// A sentence half-typed into Slack wants a different ending from the same
/// sentence half-typed into Mail, and neither wants what LinkedIn wants. The
/// model sees only the words, so without this it averages every register it was
/// trained on and lands somewhere between all of them.
///
/// Browsers are the hard case and the important one: the frontmost app is
/// "Google Chrome" whether you are in Gmail or on LinkedIn. The window title is
/// the only cheap signal that distinguishes them, and it is usually enough —
/// "(20) Feed | LinkedIn", "Inbox (3) - you@gmail.com - Gmail".
@MainActor
enum AppContext {

    /// A short phrase naming the register, or nil when there is nothing useful
    /// to say. Nil is a real answer: a wrong hint is worse than none, so
    /// anything unrecognised gets no hint at all rather than a guess.
    static func hint() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundle = app.bundleIdentifier ?? ""

        if browsers.contains(bundle) {
            return windowTitle(of: app).flatMap(site(from:))
        }
        return native[bundle]
    }

    // MARK: - Native apps

    private static let native: [String: String] = [
        "com.tinyspeck.slackmacgap":  "a Slack message",
        "com.hnc.Discord":            "a Discord message",
        "com.apple.MobileSMS":        "a text message",
        "com.apple.mail":             "an email",
        "com.microsoft.Outlook":      "an email",
        "com.readdle.smartemail-Mac": "an email",
        "com.superhuman.electron":    "an email",
        "com.apple.Notes":            "a personal note",
        "md.obsidian":                "a personal note",
        "notion.id":                  "a Notion document",
        "com.linear":                 "a Linear issue",
        "com.atlassian.jira":         "a Jira ticket",
        "com.apple.dt.Xcode":         "code and code comments",
        "com.microsoft.VSCode":       "code and code comments",
        "com.apple.Terminal":         "a shell command",
        "com.googlecode.iterm2":      "a shell command",
        "com.apple.Music":            "a music search",
        "com.spotify.client":         "a music search",
        "com.whatsapp.desktop":       "a WhatsApp message",
        "net.whatsapp.WhatsApp":      "a WhatsApp message",
        "com.tinyspeck.slackmacgap.helper": "a Slack message",
    ]

    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser",
        "com.google.Chrome.canary", "com.operasoftware.Opera",
    ]

    // MARK: - Sites

    /// Ordered longest-signal-first so "mail.google" beats a bare "google".
    private static let sites: [(needle: String, hint: String)] = [
        ("linkedin",        "a LinkedIn post"),
        ("gmail",           "an email"),
        ("outlook",         "an email"),
        ("mail.google",     "an email"),
        ("superhuman",      "an email"),
        ("slack",           "a Slack message"),
        ("discord",         "a Discord message"),
        ("whatsapp",        "a WhatsApp message"),
        ("messenger",       "a chat message"),
        ("x.com",           "a post on X"),
        ("twitter",         "a post on X"),
        ("reddit",          "a Reddit comment"),
        ("github",          "a GitHub issue or pull request"),
        ("stack overflow",  "a technical question"),
        ("notion",          "a Notion document"),
        ("google docs",     "a document"),
        ("jira",            "a Jira ticket"),
        ("linear",          "a Linear issue"),
        ("youtube",         "a YouTube search"),
        ("spotify",         "a music search"),
        ("substack",        "a newsletter post"),
        ("medium",          "a blog post"),
    ]

    private static func site(from title: String) -> String? {
        let lower = title.lowercased()
        return sites.first { lower.contains($0.needle) }?.hint
    }

    /// The focused window's title. Cheap enough to ask per suggestion — it is a
    /// single attribute read on an element we already hold a reference to.
    private static func windowTitle(of app: NSRunningApplication) -> String? {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString,
                                            &window) == .success,
              let window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement,
                                            kAXTitleAttribute as CFString,
                                            &title) == .success else { return nil }
        return title as? String
    }
}
