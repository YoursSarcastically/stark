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
        // Deliberately still opaque. A fully transparent window with
        // `.underWindowBackground` let whatever was behind it read straight
        // through the text — Mail and System Settings put vibrancy in the
        // sidebar and keep the content pane solid, and so does this.
        w.isMovableByWindowBackground = true
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
            // Order and ownership both matter here. `finishOnboarding()` clears
            // the AppDelegate's only strong reference to this controller, so
            // `self?.window` was already nil by the time the close ran and the
            // window simply stayed on screen after "Start writing". Hold both
            // the controller and the window for the duration of the closure.
            onFinish: { [weak self] in
                guard let self else { return }
                let window = self.window
                self.app?.finishOnboarding()
                window?.close()
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
    @Published var auraOn = true
    @Published var completionOn = true
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
                // Each step slides in from the side the flow is moving. Without
                // it a five-screen setup reads as five unrelated windows that
                // happen to share a sidebar.
                ZStack {
                    content
                        .id(m.step)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 26)),
                            removal: .opacity.combined(with: .offset(x: -26))))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 46)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: m.step)
                footer
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        // Flat white, for the same reason the sidebar is flat: a behind-window
        // material tinted the whole pane with whatever wallpaper was behind it.
        // White content against the grey rail is the standard Mac pairing.
        .background(Color(nsColor: .textBackgroundColor))
        .onReceive(timer) { _ in m.trusted = InPlace.trusted }
        .onAppear { m.comboDisplay = hotkeyDisplay }
    }

    // MARK: chrome

    /// A visible spine of named steps rather than anonymous dots. On a
    /// four-screen flow the user should always know what is left, and "Grant
    /// access" reads as a task while a dot reads as a countdown.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                // The mark itself, not a bolt in a coloured tile. bolt.circle
                // is the same drawing as assets/icon.png.
                Image(systemName: "bolt.circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color.ink)
                Text("Stark").font(.system(size: 14, weight: .semibold))
            }
            .padding(.bottom, 26)

            // Rows sit on a single continuous rail, so the list reads as one
            // journey with a position on it rather than five loose bullets.
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 1.5, height: CGFloat(Step.allCases.count - 1) * 34)
                    .padding(.leading, 8.25)
                    .padding(.top, 17)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Step.allCases, id: \.rawValue) { s in
                        stepRow(s)
                    }
                }
            }

            Spacer()

            // The sidebar used to be two thirds empty. This is the one promise
            // worth repeating while the user is still deciding to trust it.
            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("Everything stays\non this Mac")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 16)

            credit
        }
        .padding(22)
        .frame(width: 208, alignment: .leading)
        // `.sidebar` samples the desktop behind the window, so the rail took on
        // whatever colour the wallpaper happened to be — on a warm wallpaper it
        // came out muddy beige. A flat, slightly recessed panel is what Apple's
        // own setup assistants use, and it looks the same on every Mac.
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topLeading) {
            LinearGradient(colors: [Color.brand.opacity(0.05), .clear],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
    }

    private func stepRow(_ s: Step) -> some View {
        let done = s.rawValue < m.step
        let current = s == step
        return HStack(spacing: 11) {
            // Only the step you are on is filled. Solid colour on every
            // finished step turned the rail into a column of dots, which is
            // most of what made the window look cheap.
            ZStack {
                // Opaque, so the rail passes behind the markers rather than
                // through them.
                Circle().fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 17, height: 17)
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.brand.opacity(0.55))
                } else if current {
                    Circle().fill(Color.brand).frame(width: 15, height: 15)
                    Circle().fill(.white).frame(width: 5, height: 5)
                } else {
                    Circle().strokeBorder(.quaternary, lineWidth: 1.2)
                        .frame(width: 15, height: 15)
                }
            }
            .frame(width: 17, height: 17)
            Text(title(s))
                .font(.system(size: 12.5, weight: current ? .semibold : .regular))
                .foregroundStyle(current ? AnyShapeStyle(Color.ink)
                                 : (done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8.5)
        .padding(.horizontal, 8)
        .padding(.leading, -8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(current ? Color.brand.opacity(0.09) : .clear)
                .padding(.leading, -8)
                .padding(.trailing, -6))
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
                .foregroundStyle(Color.brand)
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
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
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
                Button("Downloading…") {}
                    .buttonStyle(GlassButton())
                    .disabled(true)
                    .opacity(0.6)
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
        .riseIn()
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 0)
            heading("You write. I'll handle the rest.",
                    "Select text anywhere, press one key, and I rewrite it in place.")
            DemoView("rewrite") { RewriteDemo() }
                .padding(9)
                .glassCard(radius: 16)
                .riseIn(0.1)
            HStack(spacing: 22) {
                fact("lock.fill", "Your words never\nleave the building")
                fact("bolt.fill", "About a second.\nGive or take.")
                fact("keyboard", "Works wherever\nyou type")
            }
            .riseIn(0.2)
            Spacer(minLength: 0)
        }
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.ink.opacity(0.75))
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
            heading(models.isReady ? "Suited up." : "One download, then we're in business.",
                    models.isReady
                    ? "Everything I need is on this Mac now. No re-downloads."
                    : "I think locally, so about 1.2 GB has to live on your Mac.")

            downloadCard
                .riseIn(0.1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: models.state)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var downloadCard: some View {
            switch models.state {
            case .ready:
                statusCard(symbol: "checkmark.circle.fill", tint: .green,
                           title: "Ready when you are",
                           detail: "Sitting on your Mac · delete it whenever you like")
            case .downloading(let fraction, let received, let total):
                VStack(alignment: .leading, spacing: 9) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.3),
                                   value: fraction)
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
                .glassCard()
            case .failed(let why):
                statusCard(symbol: "exclamationmark.triangle.fill", tint: .orange,
                           title: "That one didn't land", detail: why)
            case .missing:
                statusCard(symbol: "arrow.down.circle", tint: .secondary,
                           title: "Still in the box",
                           detail: "About 1.2 GB · a few minutes, tops")
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
        .glassCard()
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 0)
            heading("One permission. Last bit of paperwork.",
                    "macOS wants your say-so before I can type on your behalf.")
            HStack(spacing: 12) {
                Image(systemName: m.trusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(m.trusted ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.trusted ? "Cleared for takeoff" : "Still waiting on you")
                        .font(.system(size: 13, weight: .medium))
                    Text(m.trusted ? "We're good. Everything works."
                         : "Without this I can think, but I can't type.")
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
            .glassCard()
            Text("Leave this open. The tick goes green by itself. I'm patient.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            heading(m.charged ? "That ran right here." : "Take it for a spin.",
                    m.charged
                    ? "No sign-up, no internet, nobody else's computer involved."
                    : "Select the sentence below with ⌘A, then press \(m.comboDisplay).")
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $m.playground)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .frame(height: 78)
                    .padding(12)
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(m.charged ? Color.green.opacity(0.75)
                                      : Color.brand.opacity(0.45),
                                      lineWidth: 1.2))
                    .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.35),
                               value: m.charged)
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
                    Text(m.charged ? "Rewritten, in place. You're welcome."
                         : "Nothing happening? I probably still need that permission. Go back a step.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(m.charged ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: m.charged)
            }
            Spacer(minLength: 0)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            heading("Good to go.",
                    "I'll be in the menu bar. Select text, press \(m.comboDisplay), done.")

            HStack(spacing: 7) {
                ForEach(Array(m.comboDisplay.enumerated()), id: \.offset) { i, ch in
                    Text(String(ch))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .frame(minWidth: 36, minHeight: 36)
                        .background(.regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.5), lineWidth: 1))
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                        .riseIn(0.12 + 0.07 * Double(i))
                }
                Button(m.recording ? "Cancel" : "Change…") {
                    m.recording ? m.stopRecording() : m.startRecording(onHotkey: onHotkey)
                }
                .padding(.leading, 6)
                if m.recording {
                    Text("press keys…").font(.system(size: 11)).foregroundStyle(Color.brand)
                }
            }
            if let warning = m.keyWarning {
                Text(warning).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 2)

            // The two things worth knowing exist, each with its own demo. Both
            // are on: they are what makes Stark feel like more than a
            // spellchecker, and left off by default most people never found
            // them. The switches are here, and again in the menu bar.
            optionRow(demo: "predict", fallback: AnyView(PredictDemo()),
                      title: "Finish my sentences",
                      detail: "I'll grey in what I think comes next. Press Tab if I'm right.",
                      isOn: $m.completionOn)
            optionRow(demo: "aura", fallback: AnyView(AuraDemo()),
                      title: "Aura learns how you write",
                      detail: "Every rewrite you keep teaches me how you write. Stays on this Mac, obviously.",
                      isOn: $m.auraOn)
            Spacer(minLength: 0)
        }
        // Finishing setup is the one moment in the flow worth celebrating.
        // Clipped to the content column: unclipped it rained over the sidebar
        // and the footer buttons, which reads as a glitch rather than a party.
        .overlay {
            if !reduceMotion {
                ConfettiView()
                    .allowsHitTesting(false)
                    .clipped()
            }
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
            .buttonStyle(GlassButton())
            .keyboardShortcut(.defaultAction)
    }
}


// MARK: - Motion

/// A fade-and-rise entrance, staggered by `delay`.
///
/// Everything used to snap into place the instant a step changed, which made
/// the window feel like a slideshow. Content now settles in the order you read
/// it. Skipped entirely under Reduce Motion, where the view starts visible.
private struct RiseIn: ViewModifier {
    /// Same reason as `OnboardingModel`: no `@State` without the macro plugin.
    final class Phase: ObservableObject { @Published var shown = false }

    @StateObject private var phase = Phase()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let delay: Double

    func body(content: Content) -> some View {
        let settled = reduceMotion || phase.shown
        return content
            .opacity(settled ? 1 : 0)
            .offset(y: settled ? 0 : 9)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.42).delay(delay)) { phase.shown = true }
            }
    }
}

extension View {
    fileprivate func riseIn(_ delay: Double = 0) -> some View {
        modifier(RiseIn(delay: delay))
    }
}

// MARK: - Confetti

/// A one-shot shower of bolts. Pure SwiftUI, skipped under Reduce Motion.
private struct ConfettiView: View {
    /// Same reason as `OnboardingModel`: no `@State` without the macro plugin.
    final class Phase: ObservableObject { @Published var fall = false }

    @StateObject private var phase = Phase()
    /// Fewer, smaller, and more transparent than the first attempt, which put
    /// 26 full-size bolts across the text and made the last screen unreadable
    /// for two seconds. A celebration should be noticed, not endured.
    private let pieces: [(x: CGFloat, delay: Double, spin: Double,
                          size: CGFloat, fade: Double)] =
        (0..<14).map { _ in (CGFloat.random(in: -300...300), .random(in: 0...0.7),
                             .random(in: -220...220), .random(in: 11...18),
                             .random(in: 0.35...0.6)) }

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, p in
                Text("⚡")
                    .font(.system(size: p.size))
                    .opacity(p.fade)
                    .position(x: geo.size.width / 2 + p.x,
                              y: phase.fall ? geo.size.height + 40 : -40)
                    .rotationEffect(.degrees(phase.fall ? p.spin : 0))
                    .animation(.easeIn(duration: 1.9).delay(p.delay), value: phase.fall)
            }
        }
        .onAppear { phase.fall = true }
    }
}
