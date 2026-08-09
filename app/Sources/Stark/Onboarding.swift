import AppKit
import SwiftUI

/// "First Charge" — the five-screen setup shown on first launch (and from
/// the menu's Run Setup…). Ends with the user performing a real rewrite.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var app: AppDelegate?

    init(app: AppDelegate, hotkeyDisplay: String) {
        self.app = app
        super.init()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Welcome to Stark"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: OnboardingView(
            hotkeyDisplay: hotkeyDisplay,
            onHotkey: { [weak app] raw in
                guard let spec = HotKeySpec.parse(raw) else { return nil }
                app?.applyHotkey(spec, raw: raw)
                return spec.display
            },
            onPersonas: { [weak app] personas, aura in
                app?.applyPersonas(personas, aura: aura)
            },
            onFinish: { [weak self] in
                self?.app?.finishOnboarding()
                self?.window?.close()
            }))
        window = w
    }

    func show() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        app?.finishOnboarding()
    }
}

// MARK: - View

/// The onboarding screens' mutable state. Held in an ObservableObject rather
/// than `@State` properties because `State` is a macro in recent SDKs and the
/// Command Line Tools toolchain ships no SwiftUI macro plugin to expand it.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step = 0
    @Published var trusted = InPlace.trusted
    @Published var comboDisplay = ""
    @Published var recording = false
    @Published var keyWarning: String?
    @Published var chatOn = true
    @Published var emailOn = true
    @Published var notesOn = true
    @Published var codeOn = true
    @Published var auraOn = false
    @Published var playground = OnboardingView.slop
    @Published var charged = false
    private var keyMonitor: Any?

    var builtPersonas: [String: [String]] {
        var p: [String: [String]] = [:]
        if chatOn {
            p["com.tinyspeck.slackmacgap"] = ["friendly", "concise"]
            p["com.hnc.Discord"] = ["friendly"]
            p["com.apple.MobileSMS"] = ["friendly"]
        }
        if emailOn {
            p["com.apple.mail"] = ["formal"]
            p["com.microsoft.Outlook"] = ["formal"]
        }
        if notesOn {
            p["com.apple.Notes"] = ["bullets"]
            p["md.obsidian"] = ["bullets"]
        }
        if codeOn {
            p["com.apple.dt.Xcode"] = ["typos"]
            p["com.microsoft.VSCode"] = ["typos"]
        }
        return p
    }

    func startRecording(onHotkey: @escaping (String) -> String?) {
        recording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            var parts: [String] = []
            if event.modifierFlags.contains(.control) { parts.append("ctrl") }
            if event.modifierFlags.contains(.option) { parts.append("alt") }
            if event.modifierFlags.contains(.shift) { parts.append("shift") }
            if event.modifierFlags.contains(.command) { parts.append("cmd") }
            guard !parts.isEmpty,
                  let name = HotKeySpec.keyName(for: UInt32(event.keyCode)) else { return event }
            // One modifier plus a key is enough (⌥B, ⌃Space). Only combos that
            // would break the app itself are refused; the merely-risky ones are
            // allowed with a caution, since it's the user's keyboard.
            if let blocked = HotKeySpec.reservedReason(modifiers: parts, key: name) {
                DispatchQueue.main.async {
                    self?.keyWarning = blocked
                    self?.stopRecording()
                }
                return nil
            }
            let caution = HotKeySpec.cautionReason(modifiers: parts, key: name)
            parts.append(name)
            let raw = parts.joined(separator: "+")
            DispatchQueue.main.async {
                self?.keyWarning = caution
                if let display = onHotkey(raw) { self?.comboDisplay = display }
                self?.stopRecording()
            }
            return nil
        }
    }

    func stopRecording() {
        recording = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

struct OnboardingView: View {
    let hotkeyDisplay: String
    let onHotkey: (String) -> String?
    let onPersonas: ([String: [String]], Bool) -> Void
    let onFinish: () -> Void

    @StateObject private var m = OnboardingModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let slop = "i cant beleive how fast this modle runs on my mac"
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let lastStep = 4

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content
                .frame(maxWidth: 460)
                .padding(.horizontal, 40)
            Spacer(minLength: 0)
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(backdrop)
        .onReceive(timer) { _ in m.trusted = InPlace.trusted }
        .onAppear { m.comboDisplay = hotkeyDisplay }
    }

    /// A quiet, system-adaptive backdrop: the window material with a single
    /// soft accent bloom behind the hero. Setup Assistant, not a hero image —
    /// the content should be the loudest thing on screen.
    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.background)
            RadialGradient(colors: [Color.accentColor.opacity(0.18), .clear],
                           center: .init(x: 0.5, y: 0.28),
                           startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }

    // MARK: Scaffold

    /// Every step is the same shape — hero glyph, title, one line of
    /// explanation, then its own controls — so moving between them feels like
    /// one flow rather than five screens.
    private func page<C: View>(icon: String,
                               title: String,
                               subtitle: String,
                               @ViewBuilder controls: () -> C) -> some View {
        VStack(spacing: 0) {
            hero(icon)
                .padding(.bottom, 24)
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            controls()
                .padding(.top, 26)
        }
    }

    private func hero(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 76, height: 76)
            .background(
                LinearGradient(colors: [Color.accentColor,
                                        Color.accentColor.opacity(0.72)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.32), radius: 14, y: 6)
    }

    @ViewBuilder
    private var content: some View {
        switch m.step {
        case 0: hello
        case 1: power
        case 2: key
        case 3: personas
        default: playgroundStep
        }
    }

    /// Progress dots plus the primary action, pinned to the bottom edge the way
    /// system setup panes do.
    private var footer: some View {
        VStack(spacing: 18) {
            Divider()
            HStack {
                if m.step > 0 && !m.charged {
                    Button("Back") { m.step -= 1 }
                        .buttonStyle(.link)
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0...Self.lastStep, id: \.self) { i in
                        Circle()
                            .fill(i == m.step ? Color.accentColor
                                              : Color.secondary.opacity(0.28))
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()
                primaryAction
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: m.step)
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch m.step {
        case 0: primary("Continue") { m.step = 1 }
        case 1: primary(m.trusted ? "Continue" : "Skip for Now") { m.step = 2 }
        case 2: primary("Continue") { m.stopRecording(); m.step = 3 }
        case 3: primary("Continue") { onPersonas(m.builtPersonas, m.auraOn); m.step = 4 }
        default:
            if m.charged { primary("Done") { onFinish() } }
            else { Button("Skip") { onFinish() }.buttonStyle(.link) }
        }
    }

    // MARK: Steps

    private var hello: some View {
        page(icon: "bolt.fill",
             title: "Welcome to Stark",
             subtitle: "Your words, only better. A small model, fine-tuned and running entirely on this Mac. No account, no cloud, no subscription.") {
            VStack(spacing: 14) {
                bullet("lock.fill", "Nothing you type ever leaves this Mac.")
                bullet("bolt.horizontal.fill", "Rewrites land in about a second.")
                bullet("keyboard", "Works in every app, on one keystroke.")
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var power: some View {
        page(icon: "hand.raised.fill",
             title: "Grant Accessibility",
             subtitle: "Stark rewrites text where it lives, which means copying your selection and pasting the result back. macOS requires your permission for that. Nothing is watched or recorded.") {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: m.trusted ? "checkmark.circle.fill"
                                                : "exclamationmark.circle.fill")
                        .foregroundStyle(m.trusted ? Color.green : Color.orange)
                    Text(m.trusted ? "Permission granted."
                                   : "Not granted yet — Stark can't paste without it.")
                        .font(.system(size: 13))
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(.quaternary.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if !m.trusted {
                    Button("Open Accessibility Settings…") {
                        InPlace.promptOnce()
                        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                        NSWorkspace.shared.open(URL(string: url)!)
                    }
                    .controlSize(.large)
                }
            }
        }
    }

    private var key: some View {
        page(icon: "command",
             title: "Pick Your Shortcut",
             subtitle: "This combo triggers Stark anywhere. Two keys is plenty — ⌥B or ⌃Space work fine.") {
            VStack(spacing: 16) {
                HStack(spacing: 7) {
                    ForEach(Array(m.comboDisplay.enumerated()), id: \.offset) { _, ch in
                        Text(String(ch))
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .frame(minWidth: 38, minHeight: 38)
                            .background(.quaternary.opacity(0.55),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(.separator, lineWidth: 1))
                    }
                    if m.recording {
                        Text("press keys…")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                            .padding(.leading, 6)
                    }
                }
                Button(m.recording ? "Cancel" : "Record New…") {
                    m.recording ? m.stopRecording() : m.startRecording(onHotkey: onHotkey)
                }
                if let keyWarning = m.keyWarning {
                    Text(keyWarning)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var personas: some View {
        page(icon: "person.2.fill",
             title: "Where Do You Write?",
             subtitle: "Stark can match its tone to the app you're in. Change any of this later in Settings.") {
            VStack(spacing: 0) {
                personaRow("Chat", "Slack, Discord, Messages → Friendly", $m.chatOn)
                Divider().padding(.leading, 14)
                personaRow("Email", "Mail, Outlook → Formal", $m.emailOn)
                Divider().padding(.leading, 14)
                personaRow("Notes", "Notes, Obsidian → Bullets", $m.notesOn)
                Divider().padding(.leading, 14)
                personaRow("Code", "Xcode, VS Code → Typos only", $m.codeOn)
                Divider().padding(.leading, 14)
                personaRow("Aura", "Learn from rewrites you accept", $m.auraOn)
            }
            .background(.quaternary.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator, lineWidth: 1))
        }
    }

    private func personaRow(_ title: String, _ detail: String,
                            _ binding: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var playgroundStep: some View {
        page(icon: m.charged ? "checkmark.seal.fill" : "text.cursor",
             title: m.charged ? "You're All Set" : "Try It Once",
             subtitle: m.charged
                ? "That rewrite ran on your Mac, on your model. Stark lives in the menu bar — select text anywhere and press \(m.comboDisplay)."
                : "Select the sentence below (⌘A works) and press \(m.comboDisplay).") {
            TextEditor(text: $m.playground)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(height: 76)
                .padding(10)
                .background(.quaternary.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(m.charged ? Color.green : Color.accentColor.opacity(0.55),
                            lineWidth: 1.5))
                .onChange(of: m.playground) { _, new in
                    if !m.charged, new != Self.slop, !new.lowercased().contains("beleive"),
                       new.trimmingCharacters(in: .whitespacesAndNewlines).count > 10 {
                        m.charged = true
                    }
                }
        }
    }

    // MARK: helpers

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(minWidth: 62) }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }
}


// MARK: - Confetti

/// A one-shot shower of bolts. Pure SwiftUI, skipped under Reduce Motion.
private struct ConfettiView: View {
    /// Same reason as `OnboardingModel`: no `@State` without the macro plugin.
    final class Phase: ObservableObject { @Published var fall = false }

    @StateObject private var phase = Phase()
    private let pieces: [(x: CGFloat, delay: Double, spin: Double, size: CGFloat)] =
        (0..<26).map { _ in (CGFloat.random(in: -360...360), .random(in: 0...0.5),
                             .random(in: -260...260), .random(in: 14...26)) }

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, p in
                Text("⚡")
                    .font(.system(size: p.size))
                    .position(x: geo.size.width / 2 + p.x, y: phase.fall ? geo.size.height + 40 : -40)
                    .rotationEffect(.degrees(phase.fall ? p.spin : 0))
                    .animation(.easeIn(duration: 1.6).delay(p.delay), value: phase.fall)
            }
        }
        .onAppear { phase.fall = true }
    }
}
