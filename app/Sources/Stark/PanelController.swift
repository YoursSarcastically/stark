import AppKit
import SwiftUI

/// Floating panel shown on the global hotkey: preset picker + streamed result.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var pasteTarget: NSRunningApplication?
    private var config: Config
    private let hotkeyDisplay: String
    let vm: PolishVM

    /// Undo state: what the last in-place rewrite replaced, and where.
    private(set) var lastOriginal: String?
    private var lastTarget: NSRunningApplication?
    var canUndo: Bool { lastTarget != nil }

    init(config: Config, server: ServerManager) {
        self.config = config
        self.vm = PolishVM(client: StarkClient(config: config), server: server)
        self.hotkeyDisplay = (HotKeySpec.parse(config.hotkey) ?? .fallback).display
        super.init()
        vm.onDone = { [weak self] result in
            guard let self else { return }
            self.lastOriginal = self.vm.input
            self.lastTarget = self.pasteTarget
            let target = self.pasteTarget
            if self.config.aura {
                AuraStore.shared.record(app: target?.bundleIdentifier,
                                        tags: self.vm.lastTags,
                                        input: self.vm.input, output: result)
            }
            self.close()
            Task { await InPlace.paste(result, into: target) }
        }
    }

    /// Onboarding saves new settings; pick them up without a relaunch.
    func update(config: Config) {
        self.config = config
    }

    private var defaultPreset: Preset {
        Presets.byTag(config.preset) ?? Presets.all[0]
    }

    /// The persona chain for the app the user is writing in.
    private func personaPresets(for bundleID: String?) -> [Preset] {
        if let bundleID, let tags = config.personas[bundleID] {
            let presets = tags.compactMap { Presets.byTag($0) }
            if !presets.isEmpty { return presets }
        }
        return [defaultPreset]
    }

    /// ⌘Z in the app that received the last in-place rewrite.
    func undoLastRewrite() {
        guard let target = lastTarget else { return }
        if config.aura { AuraStore.shared.markLastRejected() }
        Task { await InPlace.undo(in: target) }
    }

    func copyLastOriginal() {
        guard let text = lastOriginal else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    /// Hotkey / menu entry. With Accessibility granted and text selected in
    /// the frontmost app: one shot — rewrite the selection with `preset` (or
    /// the app's persona chain) and paste it back in place. `forcePicker`
    /// (shift-hotkey) keeps in-place paste-back but lets the user choose the
    /// style. Without a selection it falls back to clipboard mode.
    func show(preset: Preset? = nil, forcePicker: Bool = false) {
        Task { await captureAndShow(preset: preset, forcePicker: forcePicker) }
    }

    private func captureAndShow(preset: Preset?, forcePicker: Bool) async {
        vm.server.noteUsed() // wake it if it dozed off, and reset the idle clock
        pasteTarget = nil
        var selection: String?
        var target: NSRunningApplication?
        if InPlace.trusted {
            target = NSWorkspace.shared.frontmostApplication
            selection = await InPlace.copySelection()
            if selection != nil { pasteTarget = target }
        } else {
            InPlace.promptOnce()
        }
        let inPlace = selection != nil
        vm.reset(with: selection ?? NSPasteboard.general.string(forType: .string) ?? "",
                 inPlace: inPlace)
        if panel == nil { makePanel() }
        panel?.center()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        if let preset {
            vm.run(preset)
        } else if inPlace && !forcePicker {
            vm.runChain(personaPresets(for: target?.bundleIdentifier))
        }
    }

    func close() {
        removeKeyMonitor()
        vm.cancel()
        panel?.orderOut(nil)
        // Hand focus back to the app being written in — but NOT when that app
        // is Stark itself. The onboarding "try it" step rewrites text inside
        // Stark's own window, and hiding the whole app first meant the paste
        // had nowhere to land, so the step could never complete.
        let targetIsSelf = pasteTarget?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
        if !targetIsSelf { NSApp.hide(nil) }
    }

    private func makePanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.contentView = NSHostingView(
            rootView: PolishView(vm: vm, server: vm.server,
                                 hotkeyDisplay: hotkeyDisplay) { [weak self] in self?.close() })
        panel = p
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local event monitors are always invoked on the main thread.
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.panel?.isKeyWindow == true else { return event }
                if event.keyCode == 53 { self.close(); return nil } // esc
                if event.keyCode == 36, self.vm.state == .done { self.close(); return nil } // return
                if self.vm.canPickPreset,
                   let chars = event.charactersIgnoringModifiers,
                   let preset = Presets.all.first(where: { $0.key == chars }) {
                    self.vm.run(preset)
                    return nil
                }
                if self.vm.canPickPreset, self.vm.suggestOrganize,
                   event.charactersIgnoringModifiers == "b",
                   let bullets = Presets.byTag("bullets") {
                    self.vm.run(bullets)
                    return nil
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
