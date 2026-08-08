import AppKit
import Carbon.HIToolbox
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var serverStatusMenuItem: NSMenuItem?
    private var defaultStyleMenu: NSMenu?
    private var undoMenuItem: NSMenuItem?
    private var auraStatusItem: NSMenuItem?
    private var auraTrainItem: NSMenuItem?
    private var auraTraining = false
    private var hotKey: HotKey?
    private var pickerHotKey: HotKey?
    private var undoHotKey: HotKey?
    private var onboarding: OnboardingController?
    private var bag = Set<AnyCancellable>()

    private var config = Config.load()
    private lazy var hotKeySpec = HotKeySpec.parse(config.hotkey) ?? .fallback
    private lazy var server = ServerManager(config: config)
    private lazy var panel = PanelController(config: config, server: server)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.circle.fill",
                                           accessibilityDescription: "Stark")
        buildMenu()

        server.$status
            .receive(on: DispatchQueue.main)
            .sink { status in
                MainActor.assumeIsolated { [weak self] in
                    self?.serverStatusMenuItem?.title = "Model server: \(status.label)"
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
        hotKey = HotKey(keyCode: spec.keyCode, modifiers: spec.modifiers) { [weak self] in
            Task { @MainActor in self?.panel.toggle() }
        }
        // Derived combos (picker = +⇧, undo = modifiers+Z) are only safe when
        // the base includes ⌃ or ⌥ — a plain-⌘ base would shadow ⌘Z itself.
        let safeBase = spec.modifiers & UInt32(controlKey | optionKey) != 0
        // Shift + hotkey = manual style picker (still pastes back in place).
        if safeBase, spec.modifiers & UInt32(shiftKey) == 0 {
            pickerHotKey = HotKey(keyCode: spec.keyCode,
                                  modifiers: spec.modifiers | UInt32(shiftKey)) { [weak self] in
                Task { @MainActor in self?.panel.show(forcePicker: true) }
            }
        }
        // Same modifiers + Z = undo last rewrite.
        if safeBase, spec.keyCode != UInt32(kVK_ANSI_Z) {
            undoHotKey = HotKey(keyCode: UInt32(kVK_ANSI_Z),
                                modifiers: spec.modifiers) { [weak self] in
                Task { @MainActor in self?.panel.undoLastRewrite() }
            }
        }
    }

    /// Called by onboarding when the user records a new combo.
    func applyHotkey(_ spec: HotKeySpec, raw: String) {
        hotKey = nil; pickerHotKey = nil; undoHotKey = nil
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
    }

    private func showOnboarding() {
        let controller = OnboardingController(app: self, hotkeyDisplay: hotKeySpec.display)
        onboarding = controller
        controller.show()
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false // enabled states managed in menuWillOpen

        let rewrite = NSMenuItem(title: "Rewrite Selection (\(hotKeySpec.display))",
                                 action: #selector(openPanel), keyEquivalent: "")
        rewrite.target = self
        menu.addItem(rewrite)

        let presetsMenu = NSMenu()
        for (i, preset) in Presets.all.enumerated() {
            let item = NSMenuItem(title: preset.name,
                                  action: #selector(runPreset(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            presetsMenu.addItem(item)
        }
        let presetsItem = NSMenuItem(title: "Rewrite As", action: nil, keyEquivalent: "")
        menu.addItem(presetsItem)
        menu.setSubmenu(presetsMenu, for: presetsItem)

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
        menu.addItem(styleItem)
        menu.setSubmenu(styleMenu, for: styleItem)
        defaultStyleMenu = styleMenu

        let undo = NSMenuItem(title: "Undo Last Rewrite",
                              action: #selector(undoRewrite), keyEquivalent: "")
        undo.target = self
        menu.addItem(undo)
        undoMenuItem = undo

        let copyOriginal = NSMenuItem(title: "Copy Original of Last Rewrite",
                                      action: #selector(copyOriginal(_:)), keyEquivalent: "")
        copyOriginal.target = self
        menu.addItem(copyOriginal)

        menu.addItem(.separator())

        let auraStatus = NSMenuItem(title: "Aura: off", action: nil, keyEquivalent: "")
        auraStatus.isEnabled = false
        menu.addItem(auraStatus)
        auraStatusItem = auraStatus

        let train = NSMenuItem(title: "Train Aura Now",
                               action: #selector(trainAura), keyEquivalent: "")
        train.target = self
        menu.addItem(train)
        auraTrainItem = train

        let forget = NSMenuItem(title: "Forget Aura Data",
                                action: #selector(forgetAura), keyEquivalent: "")
        forget.target = self
        menu.addItem(forget)

        menu.addItem(.separator())

        let status = NSMenuItem(title: "Model server: …", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        serverStatusMenuItem = status

        let restart = NSMenuItem(title: "Restart Server",
                                 action: #selector(restartServer), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)

        let setup = NSMenuItem(title: "Run Setup…",
                               action: #selector(runSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Stark",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

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
        auraStatusItem?.title = "Aura: training… (a few minutes)"
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
                    ? "Aura: model updated ✓"
                    : "Aura: training failed (~/.stark/aura/train.log)"
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
            guard !auraTraining else { return }
            if config.aura {
                let n = AuraStore.shared.count()
                auraStatusItem?.title = "Aura: learning · \(n) example\(n == 1 ? "" : "s")"
                auraTrainItem?.isEnabled = n >= 8
            } else {
                auraStatusItem?.title = "Aura: off (enable via Run Setup…)"
                auraTrainItem?.isEnabled = false
            }
        }
    }
}
