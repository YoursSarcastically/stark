import AppKit
import Carbon.HIToolbox
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var serverStatusMenuItem: NSMenuItem?
    private var defaultStyleMenu: NSMenu?
    private var undoMenuItem: NSMenuItem?
    private var accessibilityMenuItem: NSMenuItem?
    private var auraStatusItem: NSMenuItem?
    private var auraTrainItem: NSMenuItem?
    private var auraTraining = false
    private var onboarding: OnboardingController?
    private var auraMenuItem: NSMenuItem?
    private var bag = Set<AnyCancellable>()

    private var config = Config.load()
    private lazy var hotKeySpec = HotKeySpec.parse(config.hotkey) ?? .fallback
    private lazy var server = ServerManager(config: config)
    private lazy var panel = PanelController(config: config, server: server)
    private lazy var completion = CompletionEngine(client: StarkClient(config: config))
    private var completionMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.circle",
                                           accessibilityDescription: "Stark")
        buildMenu()

        server.$status
            .receive(on: DispatchQueue.main)
            .sink { status in
                MainActor.assumeIsolated { [weak self] in
                    self?.serverStatusMenuItem?.title = "Stark: \(status.label)"
                }
            }
            .store(in: &bag)

        server.start()
        registerHotKeys()

        if !config.onboarded { showOnboarding() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    private func registerHotKeys() {
        let spec = hotKeySpec
        let center = HotKeyCenter.shared
        center.register(spec) { [weak self] in
            Task { @MainActor in self?.panel.toggle() }
        }
        // Adding Shift to any base is safe — ⇧⌘D collides with nothing.
        // Deriving undo is not: with a plain-⌘ base, modifiers+Z is ⌘Z, which
        // would shadow the host app's own undo everywhere.
        let safeBase = spec.modifiers & UInt32(controlKey | optionKey) != 0
        if spec.modifiers & UInt32(shiftKey) == 0 {
            let picker = HotKeySpec(keyCode: spec.keyCode,
                                    modifiers: spec.modifiers | UInt32(shiftKey),
                                    display: "⇧" + spec.display)
            center.register(picker) { [weak self] in
                Task { @MainActor in self?.panel.show(forcePicker: true) }
            }
        }
        // Same modifiers + Z = undo last rewrite.
        if safeBase, spec.keyCode != UInt32(kVK_ANSI_Z) {
            let undo = HotKeySpec(keyCode: UInt32(kVK_ANSI_Z),
                                  modifiers: spec.modifiers, display: "undo")
            center.register(undo) { [weak self] in
                Task { @MainActor in self?.panel.undoLastRewrite() }
            }
        }
        // Upgrade to the event tap when Accessibility is already granted; the
        // Carbon path alone has proven unreliable for LSUIElement apps.
        center.startTapIfPossible()
        // Not while setup is open. With predictive typing on by default the
        // keystroke tap went live over the setup window itself, put ghost text
        // on top of it, and drove the flow through all five steps on its own
        // before the user had read the first one.
        if config.completion, config.onboarded { completion.start() }
    }

    /// Called by onboarding when the user records a new combo.
    func applyHotkey(_ spec: HotKeySpec, raw: String) {
        HotKeyCenter.shared.unregisterAll()
        hotKeySpec = spec
        config.hotkey = raw
        config.save()
        registerHotKeys()
        buildMenu()
        panel.update(config: config)
    }

    /// Called by onboarding when persona/Aura choices change.
    func applyPersonas(_ personas: [String: [String]], aura: Bool) {
        config.personas = personas
        config.aura = aura
        config.save()
        panel.update(config: config)
    }

    func finishOnboarding() {
        config.onboarded = true
        config.save()
        onboarding = nil
        // Held back during setup; this is the moment it is wanted.
        if config.completion, !completion.isEnabled, InPlace.trusted {
            _ = completion.start()
        }
    }

    private func showOnboarding() {
        let controller = OnboardingController(app: self, hotkeyDisplay: hotKeySpec.display)
        onboarding = controller
        controller.show()
    }

    /// "Rewrite Selection            ⌥⌘B" — label left, shortcut trailing in
    /// secondary grey, the way AppKit renders a real key equivalent. Done as an
    /// attributed title because the shortcut is registered globally by Carbon,
    /// not as a menu `keyEquivalent`.
    private func shortcutTitle(_ label: String, _ shortcut: String) -> NSAttributedString {
        let tab = NSTextTab(textAlignment: .right, location: 260)
        let para = NSMutableParagraphStyle()
        para.tabStops = [tab]
        let s = NSMutableAttributedString(
            string: label,
            attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: para])
        s.append(NSAttributedString(
            string: "\t" + shortcut,
            attributes: [.font: NSFont.menuFont(ofSize: 0),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: para]))
        return s
    }

    /// Green when granted, orange and actionable when not — the hotkey does
    /// nothing useful without it, so it should never be a silent failure.
    private func refreshAccessibilityItem() {
        guard let it = accessibilityMenuItem else { return }
        let ok = InPlace.trusted
        // Granted is the normal state and needs no row. Missing is the one
        // failure worth interrupting the menu for.
        it.isHidden = ok
        it.isEnabled = !ok
        it.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                           accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
    }

    /// Suggestions that finish your sentence as you type.
    @objc private func toggleCompletion() {
        if completion.isEnabled {
            completion.stop()
            config.completion = false
        } else {
            guard InPlace.trusted else {
                InPlace.promptOnce()
                openAccessibilitySettings()
                return
            }
            config.completion = completion.start()
        }
        config.save()
        refreshCompletionItem()
    }

    private func refreshCompletionItem() {
        completionMenuItem?.state = completion.isEnabled ? .on : .off
    }

    /// Aura carries a submenu, so clicking the parent row toggles it and the
    /// tick reflects the state — the same gesture as Finish My Sentences.
    @objc private func toggleAura() {
        config.aura.toggle()
        config.save()
        panel.update(config: config)
        auraMenuItem?.state = config.aura ? .on : .off
    }

    @objc private func openAccessibilitySettings() {
        // Ask first: the system prompt is the only path that deep-links the user
        // straight to Stark's row in the list.
        InPlace.promptOnce()
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        NSWorkspace.shared.open(URL(string: url)!)
    }

    /// A menu item carrying an SF Symbol, matching the way system menus pair a
    /// glyph with a label.
    private func item(_ title: String, symbol: String, action: Selector?) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        return it
    }

    /// Six rows and a Quit.
    ///
    /// This menu had fourteen items under three section headers, which meant
    /// every glance cost a read. The things people actually click — rewrite,
    /// undo, the two toggles — are now top level; the maintenance (styles,
    /// permission, restart, setup) is one level down under Settings, where it
    /// does not compete. The permission row is the exception: it appears at the
    /// top level only when it is missing, because a silent Accessibility
    /// failure is the most confusing way for Stark to break.
    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false // enabled states managed in menuWillOpen

        let rewrite = item("Rewrite Selection", symbol: "wand.and.stars",
                           action: #selector(openPanel))
        // Shown right-aligned and greyed, the way system menus present shortcuts.
        rewrite.attributedTitle = shortcutTitle("Rewrite Selection", hotKeySpec.display)
        menu.addItem(rewrite)

        let presetsMenu = NSMenu()
        for (i, preset) in Presets.all.enumerated() {
            let it = NSMenuItem(title: preset.name,
                                action: #selector(runPreset(_:)), keyEquivalent: "")
            it.tag = i
            it.target = self
            presetsMenu.addItem(it)
        }
        let presetsItem = item("Rewrite As", symbol: "slider.horizontal.3", action: nil)
        menu.addItem(presetsItem)
        menu.setSubmenu(presetsMenu, for: presetsItem)

        // Both of these are about the rewrite that just happened, so they live
        // together rather than taking two rows of their own.
        let lastMenu = NSMenu()
        let undo = NSMenuItem(title: "Undo", action: #selector(undoRewrite),
                              keyEquivalent: "")
        undo.target = self
        lastMenu.addItem(undo)
        undoMenuItem = undo
        let copyOriginal = NSMenuItem(title: "Copy the Original",
                                      action: #selector(copyOriginal(_:)), keyEquivalent: "")
        copyOriginal.target = self
        lastMenu.addItem(copyOriginal)
        let lastItem = item("Last Rewrite", symbol: "arrow.uturn.backward", action: nil)
        menu.addItem(lastItem)
        menu.setSubmenu(lastMenu, for: lastItem)

        menu.addItem(.separator())

        let predict = item("Finish My Sentences", symbol: "text.cursor",
                           action: #selector(toggleCompletion))
        menu.addItem(predict)
        completionMenuItem = predict

        // Aura's own controls sit under Aura rather than in a section of their
        // own; the submenu opens with the state, so the count is one hover away.
        let auraMenu = NSMenu()
        let auraStatus = NSMenuItem(title: "Aura: off", action: nil, keyEquivalent: "")
        auraStatus.isEnabled = false
        auraMenu.addItem(auraStatus)
        auraStatusItem = auraStatus
        auraMenu.addItem(.separator())
        let train = NSMenuItem(title: "Update My Style Now",
                               action: #selector(trainAura), keyEquivalent: "")
        train.target = self
        auraMenu.addItem(train)
        auraTrainItem = train
        let forget = NSMenuItem(title: "Forget What It Learned",
                                action: #selector(forgetAura), keyEquivalent: "")
        forget.target = self
        auraMenu.addItem(forget)
        let auraItem = item("Aura", symbol: "brain", action: #selector(toggleAura))
        menu.addItem(auraItem)
        menu.setSubmenu(auraMenu, for: auraItem)
        auraMenuItem = auraItem

        menu.addItem(.separator())

        // Present only while something is wrong, so a healthy menu stays short.
        let access = item("Grant Permission…", symbol: "exclamationmark.triangle.fill",
                          action: #selector(openAccessibilitySettings))
        menu.addItem(access)
        accessibilityMenuItem = access

        let settingsMenu = NSMenu()
        let status = NSMenuItem(title: "Stark: starting…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        settingsMenu.addItem(status)
        serverStatusMenuItem = status
        settingsMenu.addItem(.separator())

        // Which style the one-press in-place rewrite uses (config `preset`).
        let styleMenu = NSMenu()
        for (i, preset) in Presets.all.enumerated() {
            let item = NSMenuItem(title: preset.name,
                                  action: #selector(setDefaultStyle(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = preset.tag == config.preset ? .on : .off
            styleMenu.addItem(item)
        }
        let styleItem = NSMenuItem(title: "Default Style", action: nil, keyEquivalent: "")
        settingsMenu.addItem(styleItem)
        settingsMenu.setSubmenu(styleMenu, for: styleItem)
        defaultStyleMenu = styleMenu

        let restart = NSMenuItem(title: "Restart Stark", action: #selector(restartServer),
                                 keyEquivalent: "")
        restart.target = self
        settingsMenu.addItem(restart)
        let setup = NSMenuItem(title: "Run Setup…", action: #selector(runSetup),
                               keyEquivalent: "")
        setup.target = self
        settingsMenu.addItem(setup)

        let settingsItem = item("Settings", symbol: "gearshape", action: nil)
        menu.addItem(settingsItem)
        menu.setSubmenu(settingsMenu, for: settingsItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Stark",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func openPanel() {
        panel.show()
    }

    @objc private func runPreset(_ sender: NSMenuItem) {
        guard Presets.all.indices.contains(sender.tag) else { return }
        panel.show(preset: Presets.all[sender.tag])
    }

    @objc private func setDefaultStyle(_ sender: NSMenuItem) {
        guard Presets.all.indices.contains(sender.tag) else { return }
        config.preset = Presets.all[sender.tag].tag
        config.save()
        panel.update(config: config)
        defaultStyleMenu?.items.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
    }

    @objc private func undoRewrite() {
        panel.undoLastRewrite()
    }

    @objc private func copyOriginal(_ sender: NSMenuItem) {
        panel.copyLastOriginal()
    }

    @objc private func restartServer() {
        server.restart()
    }

    @objc private func runSetup() {
        showOnboarding()
    }

    // MARK: Aura

    @objc private func trainAura() {
        guard !auraTraining else { return }
        auraTraining = true
        auraStatusItem?.title = "Studying your style… (a few minutes)"
        let python = config.pythonPath
        let script = URL(fileURLWithPath: config.modelPath).deletingLastPathComponent()
            .appendingPathComponent("aura_train.py").path
        Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = [script]
            var env = ProcessInfo.processInfo.environment
            env["HF_HUB_OFFLINE"] = "1"
            p.environment = env
            var ok = false
            do {
                try p.run()
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            } catch {}
            let succeeded = ok
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.auraTraining = false
                self.auraStatusItem?.title = succeeded
                    ? "Caught up ✓"
                    : "Training failed (~/.stark/aura/train.log)"
                if succeeded { self.server.restart() }
            }
        }
    }

    @objc private func forgetAura() {
        AuraStore.shared.forget()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            undoMenuItem?.isEnabled = panel.canUndo
            refreshAccessibilityItem()
            refreshCompletionItem()
            auraMenuItem?.state = config.aura ? .on : .off
            guard !auraTraining else { return }
            if config.aura {
                let n = AuraStore.shared.count()
                auraStatusItem?.title = "On · \(n) rewrite\(n == 1 ? "" : "s") kept"
                auraTrainItem?.isEnabled = n >= 8
            } else {
                auraStatusItem?.title = "Off"
                auraTrainItem?.isEnabled = false
            }
        }
    }
}
