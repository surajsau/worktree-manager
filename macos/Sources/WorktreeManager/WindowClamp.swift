import AppKit
import SwiftUI

/// Keeps the MenuBarExtra window fully on screen. With an auto-hidden menu
/// bar, AppKit anchors the window where the menu bar would be, clipping the
/// top edge (rounded corners and title) off screen. Clamp the frame back
/// inside the visible area with a small margin whenever it appears, moves,
/// or grows.
struct WindowClamp: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClampView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ClampView: NSView {
    // Only touched on the main thread; nonisolated(unsafe) so deinit can clean up.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                Self.clamp(window)
            })
        }
        Self.clamp(window)
    }

    deinit {
        removeObservers()
    }

    private nonisolated func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private static func clamp(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 10
        let frame = window.frame
        var origin = frame.origin
        origin.x = min(origin.x, visible.maxX - margin - frame.width)
        origin.x = max(origin.x, visible.minX + margin)
        origin.y = min(origin.y, visible.maxY - margin - frame.height)
        origin.y = max(origin.y, visible.minY + margin)
        if origin != frame.origin {
            window.setFrameOrigin(origin)
        }
    }
}
