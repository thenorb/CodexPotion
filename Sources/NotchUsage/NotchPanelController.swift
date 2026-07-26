import SwiftUI
import AppKit

@MainActor
final class NotchPanelController {
    private let panel: NSPanel
    private let store: UsageStore
    private let notchWidth: CGFloat
    private var screenObserver: NSObjectProtocol?

    init(store: UsageStore) {
        self.store = store
        let targetScreen = Self.notchScreen()
        notchWidth = Self.measuredNotchWidth(on: targetScreen)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: max(440, 170 + notchWidth), height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.contentView = NSHostingView(
            rootView: NotchUsageView(
                store: store,
                notchWidth: notchWidth,
                onExpansionChanged: { [weak self] expanded in
                    self?.setExpanded(expanded)
                }
            )
        )

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.positionPanel() }
        }
    }

    func show() {
        positionPanel()
        panel.orderFrontRegardless()
    }

    private func positionPanel() {
        guard let screen = Self.notchScreen() else { return }
        let x = screen.frame.midX - panel.frame.width / 2
        let y = screen.frame.maxY - panel.frame.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func setExpanded(_ expanded: Bool) {
        guard let screen = Self.notchScreen() else { return }
        let height: CGFloat = expanded ? 130 : 34
        let frame = NSRect(
            x: screen.frame.midX - panel.frame.width / 2,
            y: screen.frame.maxY - height,
            width: panel.frame.width,
            height: height
        )
        panel.setFrame(frame, display: true, animate: true)
    }

    private static func notchScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    private static func measuredNotchWidth(on screen: NSScreen?) -> CGFloat {
        guard let screen,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            return 180
        }
        // The gap between macOS's two usable menu-bar areas is the physical notch.
        // Add 12 pt on each edge so text never touches the camera housing.
        return min(280, max(160, right.minX - left.maxX + 24))
    }
}
