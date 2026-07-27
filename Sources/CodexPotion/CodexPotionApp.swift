import SwiftUI
import AppKit
import Combine
import ServiceManagement

@main
struct CodexPotionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var usageMenuItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var usageObserver: AnyCancellable?
    private let store = UsageStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenuBarItem()
        observeUsage()
        store.start()
    }

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageTrailing
        item.button?.imageScaling = .scaleProportionallyDown
        updateStatusItem(with: store.codex)

        let menu = NSMenu()
        let usageItem = NSMenuItem(title: "Codex usage: --", action: nil, keyEquivalent: "")
        usageItem.isEnabled = false
        menu.addItem(usageItem)
        usageMenuItem = usageItem
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh Usage", action: #selector(refresh), keyEquivalent: "r")
        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        menu.addItem(loginItem)
        launchAtLoginItem = loginItem
        updateLaunchAtLoginMenu()
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit CodexPotion", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
        updateStatusItem(with: store.codex)
    }

    private func observeUsage() {
        usageObserver = store.$codex
            .receive(on: RunLoop.main)
            .sink { [weak self] usage in
                self?.updateStatusItem(with: usage)
            }
    }

    private func updateStatusItem(with usage: ProviderUsage) {
        guard let button = statusItem?.button else { return }
        let percentage = usage.remainingPercent < 0
            ? "--"
            : "\(Int(usage.remainingPercent.rounded()))%"
        let title = NSAttributedString(
            string: percentage,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )
        button.attributedTitle = title
        button.image = potionImage(for: usage.remainingPercent)
        button.toolTip = "Codex usage remaining: \(percentage)"

        var menuTitle = "Codex usage remaining: \(percentage)"
        if let reset = usage.resetsAt {
            menuTitle += " · resets \(Self.resetFormatter.string(from: reset))"
        }
        usageMenuItem?.title = menuTitle
    }

    private func potionImage(for percentage: Double) -> NSImage {
        let clamped = min(100, max(0, percentage))
        let level = percentage < 0 ? 0 : floor(clamped / 10) * 10
        let liquidColor: NSColor
        switch level {
        case 70...: liquidColor = .systemGreen
        case 40..<70: liquidColor = .systemCyan
        case 20..<40: liquidColor = .systemYellow
        case 10..<20: liquidColor = .systemOrange
        default: liquidColor = .systemRed
        }

        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let bottle = NSBezierPath()
            bottle.move(to: NSPoint(x: 6.2, y: 14.2))
            bottle.line(to: NSPoint(x: 6.2, y: 11.2))
            bottle.curve(to: NSPoint(x: 4.0, y: 8.1), controlPoint1: NSPoint(x: 6.2, y: 10.0), controlPoint2: NSPoint(x: 4.0, y: 9.5))
            bottle.line(to: NSPoint(x: 3.5, y: 4.2))
            bottle.curve(to: NSPoint(x: 6.0, y: 1.8), controlPoint1: NSPoint(x: 3.3, y: 2.7), controlPoint2: NSPoint(x: 4.4, y: 1.8))
            bottle.line(to: NSPoint(x: 12.0, y: 1.8))
            bottle.curve(to: NSPoint(x: 14.5, y: 4.2), controlPoint1: NSPoint(x: 13.6, y: 1.8), controlPoint2: NSPoint(x: 14.7, y: 2.7))
            bottle.line(to: NSPoint(x: 14.0, y: 8.1))
            bottle.curve(to: NSPoint(x: 11.8, y: 11.2), controlPoint1: NSPoint(x: 14.0, y: 9.5), controlPoint2: NSPoint(x: 11.8, y: 10.0))
            bottle.line(to: NSPoint(x: 11.8, y: 14.2))
            bottle.close()

            NSGraphicsContext.saveGraphicsState()
            bottle.addClip()
            let liquidTop = 2.0 + CGFloat(level / 100) * 8.8
            let liquidRect = NSRect(x: 3.0, y: 1.6, width: 12.0, height: max(0, liquidTop - 1.6))
            NSGradient(
                colors: [liquidColor.withAlphaComponent(0.72), liquidColor]
            )?.draw(in: liquidRect, angle: 90)
            if level > 0 {
                liquidColor.blended(withFraction: 0.35, of: .white)?.setStroke()
                let surface = NSBezierPath()
                surface.move(to: NSPoint(x: 4.2, y: liquidTop))
                surface.line(to: NSPoint(x: 13.8, y: liquidTop))
                surface.lineWidth = 0.7
                surface.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()

            NSColor.labelColor.withAlphaComponent(0.92).setStroke()
            bottle.lineWidth = 1.35
            bottle.lineJoinStyle = .round
            bottle.stroke()

            let lip = NSBezierPath(roundedRect: NSRect(x: 5.3, y: 13.5, width: 7.4, height: 2.3), xRadius: 0.8, yRadius: 0.8)
            lip.lineWidth = 1.2
            lip.stroke()

            NSColor.white.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: NSRect(x: 5.2, y: 6.2, width: 1.2, height: 1.2)).fill()
            return true
        }
        image.accessibilityDescription = "Codex usage potion, \(Int(level)) percent full"
        image.isTemplate = false
        return image
    }

    @objc private func refresh() {
        Task { await store.refresh(force: true) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t Change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        updateLaunchAtLoginMenu()
    }

    private func updateLaunchAtLoginMenu() {
        launchAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
