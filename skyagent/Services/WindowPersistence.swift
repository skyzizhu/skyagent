import AppKit

class WindowPersistence {
    static let shared = WindowPersistence()
    private var observer: Any?

    func restore() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = NSApp.windows.first(where: { $0.isKeyWindow || $0.isVisible }) else { return }
            if let frame = Self.loadFrame() {
                window.setFrame(frame, display: true)
            }
            self.startObserving(window)
        }
    }

    private func startObserving(_ window: NSWindow) {
        observer = NotificationCenter.default.addObserver(forName: nil, object: window, queue: .main) { notification in
            if notification.name == NSWindow.didMoveNotification || notification.name == NSWindow.didResizeNotification {
                Self.saveFrame(window.frame)
            }
        }
    }

    private static func saveFrame(_ frame: NSRect) {
        let data = "\(frame.origin.x),\(frame.origin.y),\(frame.size.width),\(frame.size.height)"
        UserDefaults.standard.set(data, forKey: "savedWindowFrame")
    }

    private static func loadFrame() -> NSRect? {
        guard let data = UserDefaults.standard.string(forKey: "savedWindowFrame") else { return nil }
        let parts = data.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
