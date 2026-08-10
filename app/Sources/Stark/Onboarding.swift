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
        // Onboarding is always light. The demo artwork is a fixed light palette,
        // and a window that flips with the system theme would leave the
        // animations sitting on the wrong background half the time.
        w.appearance = NSAppearance(named: .aqua)
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
        // Stark is an LSUIElement app, so activating it does not reliably pull a
        // window in front of whatever is already frontmost — first-run setup
        // could open behind the user's browser and simply never be seen. Raise
        // it above normal windows to present, then drop back to normal so it
        // doesn't hover over everything for the rest of its life.
        window?.level = .floating
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.window?.level = .normal
        }
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
    @Published var completionOn = false
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
    @StateObject private var models = ModelStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let slop = "i cant beleive how fast this modle runs on my mac"
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Four steps, one job each. The previous flow had five and asked about
    /// per-app personas before the user had seen a single rewrite — a settings
    /// screen for a product they had no feel for yet. Personas moved to the
    /// menu bar, where they belong once someone actually wants them.
    private enum Step: Int, CaseIterable {
        case welcome, model, access, tryIt, done
    }
    private var step: Step { Step(rawValue: m.step) ?? .welcome }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 46)
                footer
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(.background)
        .onReceive(timer) { _ in m.trusted = InPlace.trusted }
        .onAppear { m.comboDisplay = hotkeyDisplay }
    }

    // MARK: chrome

    /// A visible spine of named steps rather than anonymous dots. On a
    /// four-screen flow the user should always know what is left, and "Grant
    /// access" reads as a task while a dot reads as a countdown.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(
                        LinearGradient(colors: [Color.accentColor,
                                                Color.accentColor.opacity(0.75)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("Stark").font(.system(size: 15, weight: .semibold))
            }
            .padding(.bottom, 30)

            ForEach(Step.allCases, id: \.rawValue) { s in
                stepRow(s)
            }
            Spacer()
            credit
        }
        .padding(24)
        .frame(width: 216, alignment: .leading)
        .background(.quaternary.opacity(0.22))
    }

    private func stepRow(_ s: Step) -> some View {
        let done = s.rawValue < m.step
        let current = s == step
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(done ? Color.accentColor
                          : (current ? Color.accentColor.opacity(0.16) : Color.clear))
                    .frame(width: 20, height: 20)
                if !done, !current {
                    Circle().stroke(.tertiary, lineWidth: 1).frame(width: 20, height: 20)
                }
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                } else if current {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                }
            }
            Text(title(s))
                .font(.system(size: 12.5, weight: current ? .semibold : .regular))
                .foregroundStyle(current ? AnyShapeStyle(.primary)
                                 : (done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: m.step)
    }

    private func title(_ s: Step) -> String {
        switch s {
        case .welcome: return "Welcome"
        case .model:   return "Download model"
        case .access:  return "Grant access"
        case .tryIt:   return "Try it"
        case .done:    return "You're set"
        }
    }

    private var credit: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Built by").font(.system(size: 10)).foregroundStyle(.tertiary)
            Link("Suraj Sharma",
                 destination: URL(string: "https://www.linkedin.com/in/surajsharma97/")!)
                .font(.system(size: 11, weight: .medium))
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if m.step > 0 {
                    Button("Back") { m.step -= 1 }.buttonStyle(.link)
                }
                Spacer()
                primaryAction
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch step {
        case .welcome:
            primary("Get started") { m.step += 1 }
        case .model:
            // The one step that cannot be skipped — without weights there is no
            // product. The button becomes Continue only once the file is on disk.
            if models.isReady {
                primary("Continue") { m.step += 1 }
            } else if case .downloading = models.state {
                Button("Downloading…") {}.buttonStyle(.borderedProminent)
                    .controlSize(.large).disabled(true)
            } else {
                primary("Download · 1.2 GB") { models.start() }
            }
        case .access:
            primary(m.trusted ? "Continue" : "Skip for now") { m.step += 1 }
        case .tryIt:
            primary("Continue") { m.step += 1 }
        case .done:
            primary("Start writing") { onPersonas(m.builtPersonas, m.auraOn); onFinish() }
        }
    }

    // MARK: steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .model:   modelStep
        case .access:  access
        case .tryIt:   tryIt
        case .done:    done
        }
    }

    private func heading(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(sub)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 0)
            heading("Your words, only better.",
                    "A small model, fine-tuned and running entirely on this Mac. "
                    + "Select text anywhere, press one key, watch it improve in place.")
            DemoView("rewrite") { RewriteDemo() }
            HStack(spacing: 22) {
                fact("lock.fill", "Nothing leaves\nthis Mac")
                fact("bolt.fill", "About a second\nper rewrite")
                fact("keyboard", "Works in\nevery app")
            }
            Spacer(minLength: 0)
        }
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Progress for a download people will otherwise assume has hung. A bare
    /// spinner for three minutes reads as broken; bytes and a bar read as work.
    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 0)
            heading(models.isReady ? "The model is ready." : "One download, then it's yours.",
                    models.isReady
                    ? "It lives on this Mac from here on. Nothing is fetched again, and nothing you write is ever uploaded."
                    : "Stark runs a 1.7-billion-parameter model locally, so the weights have to live on your Mac. It is a one-time download of about 1.2 GB.")

            switch models.state {
            case .ready:
                statusCard(symbol: "checkmark.circle.fill", tint: .green,
                           title: "Downloaded",
                           detail: "Stored in Application Support · delete anytime")
            case .downloading(let fraction, let received, let total):
                VStack(alignment: .leading, spacing: 9) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                    HStack {
                        Text("\(ModelStore.describe(received)) of \(ModelStore.describe(total))")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(fraction * 100))%")
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                    }
                }
                .padding(16)
                .background(.quaternary.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.separator, lineWidth: 1))
            case .failed(let why):
                statusCard(symbol: "exclamationmark.triangle.fill", tint: .orange,
                           title: "Download failed", detail: why)
            case .missing:
                statusCard(symbol: "arrow.down.circle", tint: .secondary,
                           title: "Not downloaded yet",
                           detail: "About 1.2 GB · takes a few minutes on most connections")
            }
            Spacer(minLength: 0)
        }
    }

    private func statusCard(symbol: String, tint: Color,
                            title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.quaternary.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(.separator, lineWidth: 1))
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 0)
            heading("One permission, then you're done.",
                    "To replace text where you wrote it, Stark copies your selection and "
                    + "pastes the result back. macOS requires your permission for that. "
                    + "Nothing is recorded, and nothing is sent anywhere.")
            HStack(spacing: 12) {
                Image(systemName: m.trusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(m.trusted ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.trusted ? "Accessibility granted" : "Accessibility not granted yet")
                        .font(.system(size: 13, weight: .medium))
                    Text(m.trusted ? "Everything below will work."
                         : "Rewriting can't paste without it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !m.trusted {
                    Button("Open Settings…") {
                        InPlace.promptOnce()
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .controlSize(.large)
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator, lineWidth: 1))
            Text("Stark waits here until you switch it on — the tick turns green by itself.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            heading(m.charged ? "That ran on your Mac." : "Try it right here.",
                    m.charged
                    ? "No account, no network, no waiting on a server. That is the whole product."
                    : "Select the sentence below — ⌘A works — then press \(m.comboDisplay).")
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $m.playground)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .frame(height: 78)
                    .padding(12)
                    .background(.quaternary.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(m.charged ? Color.green : Color.accentColor.opacity(0.5),
                                lineWidth: 1.5))
                    .onChange(of: m.playground) { _, new in
                        if !m.charged, new != Self.slop, !new.lowercased().contains("beleive"),
                           new.trimmingCharacters(in: .whitespacesAndNewlines).count > 10 {
                            m.charged = true
                        }
                    }
                HStack(spacing: 7) {
                    Image(systemName: m.charged ? "checkmark.circle.fill" : "keyboard")
                        .font(.system(size: 11))
                        .foregroundStyle(m.charged ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                    Text(m.charged ? "Rewritten in place."
                         : "Not working? Accessibility may still be off — go back a step.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(m.charged ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            heading("You're set.",
                    "Stark lives in the menu bar. Select text anywhere and press "
                    + "\(m.comboDisplay) — that's the whole thing.")

            HStack(spacing: 7) {
                ForEach(Array(m.comboDisplay.enumerated()), id: \.offset) { _, ch in
                    Text(String(ch))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .frame(minWidth: 36, minHeight: 36)
                        .background(.quaternary.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.separator, lineWidth: 1))
                }
                Button(m.recording ? "Cancel" : "Change…") {
                    m.recording ? m.stopRecording() : m.startRecording(onHotkey: onHotkey)
                }
                .padding(.leading, 6)
                if m.recording {
                    Text("press keys…").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                }
            }
            if let warning = m.keyWarning {
                Text(warning).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 2)

            // The two things worth knowing exist, each with its own demo. Both
            // default off — they are the parts that watch what you type.
            optionRow(demo: "predict", fallback: AnyView(PredictDemo()),
                      title: "Predictive typing",
                      detail: "Ghost-text suggestions as you write. Tab accepts.",
                      isOn: $m.completionOn)
            optionRow(demo: "aura", fallback: AnyView(AuraDemo()),
                      title: "Aura",
                      detail: "Learns your voice from rewrites you keep. Stays on this Mac.",
                      isOn: $m.auraOn)
            Spacer(minLength: 0)
        }
    }

    private func optionRow(demo: String, fallback: AnyView, title: String,
                           detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            DemoView(demo) { fallback }
                .scaleEffect(0.38, anchor: .center)
                .frame(width: DemoView.w * 0.38, height: DemoView.h * 0.38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(minWidth: 76) }
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
