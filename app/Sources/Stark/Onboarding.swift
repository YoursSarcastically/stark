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

struct OnboardingView: View {
    let hotkeyDisplay: String
    let onHotkey: (String) -> String?
    let onPersonas: ([String: [String]], Bool) -> Void
    let onFinish: () -> Void

    @State private var step = 0
    @State private var trusted = InPlace.trusted
    @State private var comboDisplay = ""
    @State private var recording = false
    @State private var keyWarning: String?
    @State private var keyMonitor: Any?
    @State private var chatOn = true
    @State private var emailOn = true
    @State private var notesOn = true
    @State private var codeOn = true
    @State private var auraOn = false
    @State private var playground = OnboardingView.slop
    @State private var charged = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let slop = "i cant beleive how fast this modle runs on my mac"
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            background
            card
            if charged && !reduceMotion { ConfettiView().allowsHitTesting(false) }
            VStack {
                Spacer()
                chargeMeter.padding(.bottom, 18)
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .onReceive(timer) { _ in trusted = InPlace.trusted }
        .onAppear { comboDisplay = hotkeyDisplay }
    }

    /// One scene for the whole journey: a single photo (or an aurora
    /// gradient when none is bundled) under a scrim that keeps the glass
    /// card legible on every step.
    private var background: some View {
        ZStack {
            if let img = Self.photo {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.19),
                    Color(red: 0.20, green: 0.14, blue: 0.45),
                    Color(red: 0.58, green: 0.25, blue: 0.52),
                    Color(red: 0.98, green: 0.68, blue: 0.25),
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.18), .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private static let photo: NSImage? = {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("backgrounds/bg1.jpg") else { return nil }
        return NSImage(contentsOf: url)
    }()

    private var chargeMeter: some View {
        HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? Color.yellow : Color.white.opacity(0.35))
                    .frame(width: 32, height: 6)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case 0: hello
            case 1: power
            case 2: key
            case 3: personas
            default: playgroundStep
            }
        }
        .padding(28)
        .frame(width: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22)
            .stroke(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.12)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1))
        .shadow(color: .black.opacity(0.38), radius: 30, y: 14)
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: step)
    }

    // MARK: Screens

    private var hello: some View {
        Group {
            Label("Meet Stark", systemImage: "bolt.circle.fill")
                .font(.title.weight(.bold)).foregroundStyle(.primary)
            Text("Your words, only better. A tiny model, fine-tuned and living entirely on this Mac. No account. No cloud. No subscription.")
                .foregroundStyle(.secondary)
            primary("Charge me up — 60 sec") { step = 1 }
        }
    }

    private var power: some View {
        Group {
            Text("Grant the superpower").font(.title2.weight(.bold))
            Text("To rewrite text where it lives, Stark needs macOS Accessibility — that's how the copy and paste happens for you. Nothing is watched or recorded.")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Circle().fill(trusted ? .green : .orange).frame(width: 10, height: 10)
                Text(trusted ? "Permission granted — you're wired in." : "Waiting for permission…")
                    .font(.callout)
            }
            HStack {
                Button("Open System Settings") {
                    let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    NSWorkspace.shared.open(URL(string: url)!)
                }
                Spacer()
                primary(trusted ? "Continue" : "Skip for now") { step = 2 }
            }
        }
    }

    private var key: some View {
        Group {
            Text("Pick your key").font(.title2.weight(.bold))
            Text("This combo triggers Stark anywhere. Keep the default or record your own.")
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(Array(comboDisplay.enumerated()), id: \.offset) { _, ch in
                    Text(String(ch))
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .frame(minWidth: 34, minHeight: 34)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.3)))
                }
                if recording {
                    Text("press keys…").font(.callout).foregroundStyle(.orange)
                }
            }
            if let keyWarning {
                Text(keyWarning).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button(recording ? "Cancel" : "Record new…") {
                    recording ? stopRecording() : startRecording()
                }
                Spacer()
                primary("Continue") { stopRecording(); step = 3 }
            }
        }
    }

    private var personas: some View {
        Group {
            Text("Where do you write?").font(.title2.weight(.bold))
            Text("Stark adapts to the app you're in. Change any of this later in ~/.stark/config.json.")
                .foregroundStyle(.secondary)
            Toggle("Chat (Slack, Discord, Messages) → Friendly", isOn: $chatOn)
            Toggle("Email (Mail, Outlook) → Formal", isOn: $emailOn)
            Toggle("Notes (Notes, Obsidian) → Organize into bullets", isOn: $notesOn)
            Toggle("Code (Xcode, VS Code) → Fix typos only", isOn: $codeOn)
            Divider()
            Toggle(isOn: $auraOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aura — learn from me")
                    Text("Accepted rewrites become training examples so the model grows into your voice. Stored only on this Mac; forget everything anytime.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                primary("Continue") {
                    onPersonas(builtPersonas, auraOn)
                    step = 4
                }
            }
        }
    }

    private var playgroundStep: some View {
        Group {
            Text(charged ? "You're charged ⚡" : "The playground").font(.title2.weight(.bold))
            Text(charged
                 ? "That rewrite ran on your Mac, on your model. Stark lives in the menu bar — select text anywhere and press \(comboDisplay)."
                 : "Select the sentence below (⌘A works) and press \(comboDisplay). Go on.")
                .foregroundStyle(.secondary)
            TextEditor(text: $playground)
                .font(.system(size: 14))
                .frame(height: 84)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(charged ? Color.green : Color.orange.opacity(0.6), lineWidth: 1.5))
                .onChange(of: playground) { _, new in
                    if !charged, new != Self.slop, !new.lowercased().contains("beleive"),
                       new.trimmingCharacters(in: .whitespacesAndNewlines).count > 10 {
                        charged = true
                    }
                }
            HStack {
                if !charged {
                    Button("Skip the test") { onFinish() }
                }
                Spacer()
                if charged {
                    primary("Finish") { onFinish() }
                }
            }
        }
    }

    // MARK: helpers

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).padding(.horizontal, 6).padding(.vertical, 2)
        }
        .buttonStyle(.borderedProminent)
        .tint(.yellow)
        .foregroundStyle(.black)
        .keyboardShortcut(.defaultAction)
    }

    private var builtPersonas: [String: [String]] {
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

    private func startRecording() {
        recording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            var parts: [String] = []
            if event.modifierFlags.contains(.control) { parts.append("ctrl") }
            if event.modifierFlags.contains(.option) { parts.append("alt") }
            if event.modifierFlags.contains(.shift) { parts.append("shift") }
            if event.modifierFlags.contains(.command) { parts.append("cmd") }
            guard !parts.isEmpty,
                  let name = HotKeySpec.keyName(for: UInt32(event.keyCode)) else { return event }
            // Plain ⌘ combos collide with system shortcuts (⌘F, ⌘Z, …) —
            // and the derived undo/picker keys would too. Require ⌃ or ⌥.
            guard parts.contains("ctrl") || parts.contains("alt") else {
                DispatchQueue.main.async {
                    keyWarning = "Include ⌃ or ⌥ — plain ⌘ combos collide with system shortcuts like Find and Undo."
                    stopRecording()
                }
                return nil
            }
            parts.append(name)
            let raw = parts.joined(separator: "+")
            DispatchQueue.main.async {
                keyWarning = nil
                if let display = onHotkey(raw) { comboDisplay = display }
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Confetti

/// A one-shot shower of bolts. Pure SwiftUI, skipped under Reduce Motion.
private struct ConfettiView: View {
    @State private var fall = false
    private let pieces: [(x: CGFloat, delay: Double, spin: Double, size: CGFloat)] =
        (0..<26).map { _ in (CGFloat.random(in: -360...360), .random(in: 0...0.5),
                             .random(in: -260...260), .random(in: 14...26)) }

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, p in
                Text("⚡")
                    .font(.system(size: p.size))
                    .position(x: geo.size.width / 2 + p.x, y: fall ? geo.size.height + 40 : -40)
                    .rotationEffect(.degrees(fall ? p.spin : 0))
                    .animation(.easeIn(duration: 1.6).delay(p.delay), value: fall)
            }
        }
        .onAppear { fall = true }
    }
}
