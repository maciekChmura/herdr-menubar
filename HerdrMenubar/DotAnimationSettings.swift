import AppKit

/// Whether the menu bar dots animate: the "Animate dots" setting, unless macOS's Reduce motion is on.
@MainActor
final class DotAnimationSettings {
    /// Called when either setting changes.
    var onChange: (() -> Void)?

    /// The "Animate dots" setting, remembered across launches.
    var userEnabled: Bool {
        didSet {
            UserDefaults.standard.set(userEnabled, forKey: Self.key)
            onChange?()
        }
    }

    private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var isEnabled: Bool { userEnabled && !reduceMotion }

    /// The menu item's title. Says why the dots are still when Reduce motion turns them off.
    var toggleTitle: String {
        reduceMotion ? "Animate dots (off while Reduce motion is on)" : "Animate dots"
    }

    private var reduceMotionObserver: (any NSObjectProtocol)?
    private static let key = "AnimateDots"

    init() {
        userEnabled = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.onChange?()
            }
        }
    }
}
