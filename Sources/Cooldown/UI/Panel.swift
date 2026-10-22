import AppKit
import Combine
import SwiftUI

final class GlassPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The menu bar item and the glass window it opens. A borderless panel instead of a menu bar
/// extra gives the window its own shape: Liquid Glass with large continuous corners.
@MainActor
final class StatusController: NSObject {
    static let size = NSSize(width: 380, height: 620)
    static weak var shared: StatusController?
    static let cornerRadius: CGFloat = 28

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: GlassPanel
    private let model: AppModel
    private var subscriptions = Set<AnyCancellable>()
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        panel = GlassPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.close() }

        let hosting = NSHostingView(rootView: RootView().environmentObject(model))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]

        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: Self.size))
        glass.cornerRadius = Self.cornerRadius
        glass.contentView = hosting
        glass.autoresizingMask = [.width, .height]

        // The window itself must be round too: a clear container clipped to the same corners,
        // so nothing (and no shadow) is left in the square corners of the panel.
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.addSubview(glass)
        panel.contentView = container

        if let button = item.button {
            button.image = model.menuImage
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityTitle("Cooldown")
        }
        Self.shared = self
        ToastController.shared.anchor = { [weak self] in
            guard let button = self?.item.button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        model.menuImageChanges
            .receive(on: RunLoop.main)
            .sink { [weak self] image in
                self?.item.button?.image = image
                self?.updateGlow()
            }
            .store(in: &subscriptions)
        model.menuTooltipChanges
            .receive(on: RunLoop.main)
            .sink { [weak self] text in self?.item.button?.toolTip = text }
            .store(in: &subscriptions)
    }

    // MARK: Light along a working agent's line

    private var glowLayers: [CALayer] = []
    private var glowKey = ""

    /// One clipped layer per working line with a soft light sliding through it, animated by the
    /// system compositor: smooth, and next to no work for Cooldown while an agent runs.
    private func updateGlow() {
        guard let button = item.button else { return }
        let lines = model.displayedLines
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let layout = GaugeIcon.barFrames(lines: lines, attention: model.needsAttention, showText: Settings.showPercent)
        let bounds = button.bounds
        let origin = NSPoint(x: ((bounds.width - layout.size.width) / 2).rounded(), y: ((bounds.height - layout.size.height) / 2).rounded())
        var frames: [NSRect] = []
        for (index, line) in lines.enumerated() where line.activity == .working && !still && index < layout.bars.count {
            var rect = layout.bars[index].offsetBy(dx: origin.x, dy: origin.y)
            if button.isFlipped { rect.origin.y = bounds.height - rect.maxY }
            frames.append(rect)
        }
        let key = frames.map { NSStringFromRect($0) }.joined(separator: "|")
        guard key != glowKey else { return }
        glowKey = key
        glowLayers.forEach { $0.removeFromSuperlayer() }
        glowLayers = []
        guard !frames.isEmpty else { return }
        button.wantsLayer = true
        for rect in frames {
            let clip = CALayer()
            clip.frame = rect
            clip.cornerRadius = rect.height / 2
            clip.masksToBounds = true
            let light = CAGradientLayer()
            light.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.6).cgColor,
                            NSColor.white.withAlphaComponent(0).cgColor]
            light.startPoint = CGPoint(x: 0, y: 0.5)
            light.endPoint = CGPoint(x: 1, y: 0.5)
            light.frame = CGRect(x: -20, y: 0, width: 20, height: rect.height)
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = -10
            slide.toValue = rect.width + 10
            slide.duration = 2.4
            slide.repeatCount = .infinity
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            light.add(slide, forKey: "slide")
            clip.addSublayer(light)
            button.layer?.addSublayer(clip)
            glowLayers.append(clip)
        }
    }

    @objc private func toggle() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
            return
        }
        panel.isVisible && panel.alphaValue > 0.5 ? close() : open()
    }

    /// Right click on the icon: the few things worth reaching without opening the window.
    private func showMenu() {
        if panel.isVisible { close() }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "") {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self
            menu.addItem(entry)
        }
        add("Обновить лимиты", #selector(menuRefresh), "r")
        add("События", #selector(menuFeed))
        add("Запланировать задачу Codex…", #selector(menuSchedule))
        menu.addItem(.separator())
        add("Настройки…", #selector(menuSettings), ",")
        add("Выйти из Cooldown", #selector(menuQuit), "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func menuRefresh() { Task { await model.refreshLimits() } }
    @objc private func menuFeed() { open(to: .feed) }
    @objc private func menuSchedule() { open(to: .schedule) }
    @objc private func menuSettings() { SettingsWindow.shared.show() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    /// Opens the window on a given screen (feed, settings, …).
    func open(to screen: Screen) {
        model.route = screen
        if !(panel.isVisible && panel.alphaValue > 0.5) { open() }
    }

    func toggleFromHotKey() {
        panel.isVisible && panel.alphaValue > 0.5 ? close() : open()
    }

    func open() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.midX - Self.size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - Self.size.width - 8)
        let final = NSRect(x: x, y: anchor.minY - Self.size.height - 6, width: Self.size.width, height: Self.size.height)

        panel.setFrame(final.offsetBy(dx: 0, dy: 8), display: false)
        panel.alphaValue = 0
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.displayIfNeeded()
        button.highlight(true)
        model.panelOpened()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        } completionHandler: { [weak self] in
            // The shadow follows the drawn shape only once the content is on screen.
            Task { @MainActor in self?.panel.invalidateShadow() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.panel.invalidateShadow() }
        installMonitors()
    }

    func close() {
        model.panelVisible = false
        removeMonitors()
        item.button?.highlight(false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.panel.alphaValue < 0.5 else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Draws the panel's content into a PNG (the desktop seen through the glass is not part of it).
    func capture(to url: URL) {
        let glass = panel.contentView?.subviews.first as? NSGlassEffectView
        guard let view = glass?.contentView ?? panel.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor(white: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: bounds.size), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
        rep.draw(in: NSRect(origin: .zero, size: bounds.size))
        image.unlockFocus()
        if let data = RenderMode.pngData(image, scale: 2) { try? data.write(to: url) }
    }

    private func installMonitors() {
        removeMonitors()
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.close() }
        }) {
            monitors.append(monitor)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}
