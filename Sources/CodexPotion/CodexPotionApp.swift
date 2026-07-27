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
final class RefreshIntervalControlView: NSView {
    var onAdjust: ((Int) -> Void)?

    private let intervalLabel = NSTextField(labelWithString: "")
    private lazy var decreaseButton = makeButton(
        title: "−",
        toolTip: "Decrease refresh interval",
        action: #selector(decrease)
    )
    private lazy var increaseButton = makeButton(
        title: "+",
        toolTip: "Increase refresh interval",
        action: #selector(increase)
    )

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 34))
        intervalLabel.font = NSFont.menuFont(ofSize: 0)
        intervalLabel.textColor = .labelColor
        intervalLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(intervalLabel)
        addSubview(decreaseButton)
        addSubview(increaseButton)
        NSLayoutConstraint.activate([
            intervalLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            intervalLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            intervalLabel.trailingAnchor.constraint(lessThanOrEqualTo: decreaseButton.leadingAnchor, constant: -8),
            decreaseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            decreaseButton.widthAnchor.constraint(equalToConstant: 28),
            decreaseButton.heightAnchor.constraint(equalToConstant: 24),
            increaseButton.leadingAnchor.constraint(equalTo: decreaseButton.trailingAnchor, constant: 6),
            increaseButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            increaseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            increaseButton.widthAnchor.constraint(equalToConstant: 28),
            increaseButton.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(intervalText: String, canDecrease: Bool, canIncrease: Bool) {
        intervalLabel.stringValue = "Refresh Every: \(intervalText)"
        decreaseButton.isEnabled = canDecrease
        increaseButton.isEnabled = canIncrease
    }

    private func makeButton(title: String, toolTip: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        button.toolTip = toolTip
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    @objc private func decrease() {
        onAdjust?(-1)
    }

    @objc private func increase() {
        onAdjust?(1)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var primaryWindowMenuItem: NSMenuItem?
    private var secondaryWindowMenuItem: NSMenuItem?
    private var bankedResetsMenuItem: NSMenuItem?
    private var resetCreditMenuItems: [NSMenuItem] = []
    private var refreshIntervalControl: RefreshIntervalControlView?
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
        let primaryWindowItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        primaryWindowItem.isEnabled = false
        primaryWindowItem.isHidden = true
        menu.addItem(primaryWindowItem)
        primaryWindowMenuItem = primaryWindowItem

        let secondaryWindowItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        secondaryWindowItem.isEnabled = false
        secondaryWindowItem.isHidden = true
        menu.addItem(secondaryWindowItem)
        secondaryWindowMenuItem = secondaryWindowItem

        let bankedResetsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        bankedResetsItem.isEnabled = false
        bankedResetsItem.isHidden = true
        menu.addItem(bankedResetsItem)
        bankedResetsMenuItem = bankedResetsItem

        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh Usage", action: #selector(refresh), keyEquivalent: "r")
        let intervalControl = RefreshIntervalControlView()
        intervalControl.onAdjust = { [weak self] offset in
            self?.store.adjustRefreshInterval(by: offset)
            self?.updateRefreshIntervalMenu()
        }
        let intervalItem = NSMenuItem()
        intervalItem.view = intervalControl
        menu.addItem(intervalItem)
        refreshIntervalControl = intervalControl
        updateRefreshIntervalMenu()

        menu.addItem(.separator())
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
        let overallRemaining = usage.limitingRemainingPercent
        let percentage = overallRemaining < 0
            ? "--"
            : "\(Int(overallRemaining.rounded()))%"
        let title = NSAttributedString(
            string: percentage,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )
        button.attributedTitle = title
        button.image = potionImage(for: overallRemaining)
        button.toolTip = "Codex usage remaining: \(percentage)"

        updateWindowMenuItem(
            primaryWindowMenuItem,
            remaining: usage.remainingPercent,
            label: usage.label,
            reset: usage.resetsAt
        )
        updateWindowMenuItem(
            secondaryWindowMenuItem,
            remaining: usage.secondaryRemainingPercent,
            label: usage.secondaryLabel,
            reset: usage.secondaryResetsAt
        )
        updateResetCreditMenu(with: usage)
    }

    private func updateWindowMenuItem(
        _ item: NSMenuItem?,
        remaining: Double?,
        label: String?,
        reset: Date?
    ) {
        guard let item, let remaining, remaining >= 0 else {
            item?.isHidden = true
            return
        }
        var title = "\(label ?? "Usage window"): \(Int(remaining.rounded()))% remaining"
        if let reset {
            title += " · resets \(Self.resetFormatter.string(from: reset))"
        }
        item.title = title
        item.isHidden = false
    }

    private func updateResetCreditMenu(with usage: ProviderUsage) {
        guard let menu = statusItem?.menu, let summaryItem = bankedResetsMenuItem else { return }
        resetCreditMenuItems.forEach(menu.removeItem)
        resetCreditMenuItems.removeAll()

        guard let availableCount = usage.availableResetCount else {
            summaryItem.isHidden = true
            return
        }

        summaryItem.title = "Banked full resets: \(availableCount) available"
        summaryItem.isHidden = false

        var insertionIndex = menu.index(of: summaryItem) + 1
        for credit in usage.resetCredits ?? [] {
            var title = "  \(credit.title)"
            if let expiresAt = credit.expiresAt {
                title += " · expires \(Self.resetFormatter.string(from: expiresAt))"
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: insertionIndex)
            resetCreditMenuItems.append(item)
            insertionIndex += 1
        }
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

    private func updateRefreshIntervalMenu() {
        let interval = store.refreshInterval
        let intervals = UsageStore.allowedRefreshIntervals
        refreshIntervalControl?.update(
            intervalText: Self.format(interval: interval),
            canDecrease: interval != intervals.first,
            canIncrease: interval != intervals.last
        )
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

    private static func format(interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min"
    }
}
