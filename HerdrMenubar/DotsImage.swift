import AppKit

/// The dots' look: sizes, colors, and the still dot drawn in front of each menu row.
/// The menu bar dots themselves are Core Animation layers; see `StatusDotsView`.
enum DotsImage {
    /// The same size in the menu bar and in front of the menu rows.
    static let diameter: CGFloat = 10
    /// Space between dots in dots mode.
    static let spacing: CGFloat = 4
    /// Room at both ends of the menu bar item, so a ring or a pop on the first or last dot isn't cut off.
    static let padding: CGFloat = 3
    /// In counts mode: space between a dot and its number, and between one number and the next dot.
    static let countGap: CGFloat = 3
    static let groupGap: CGFloat = 9

    static var countFont: NSFont {
        .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    enum Fill: Equatable {
        case solid
        case ring
    }

    struct Style: Equatable {
        let color: NSColor
        let fill: Fill
    }

    static func style(for status: AgentStatus) -> Style {
        switch status {
        case .blocked: Style(color: .systemRed, fill: .solid)
        case .working: Style(color: .systemGreen, fill: .solid)
        case .done: Style(color: .systemBlue, fill: .solid)
        case .idle: Style(color: .systemGray, fill: .solid)
        case .unknown: Style(color: .systemGray, fill: .ring)
        }
    }

    /// Width of a ring-style dot's outline.
    static let ringLineWidth: CGFloat = 1.5

    /// The still dot shown before an agent's title in the menu. A non-template image, so it keeps its color.
    static func menuIcon(for status: AgentStatus) -> NSImage {
        let size = NSSize(width: diameter + 2, height: diameter + 2)
        let image = NSImage(size: size, flipped: false) { _ in
            let rect = NSRect(x: 1, y: 1, width: diameter, height: diameter)
            let style = style(for: status)
            switch style.fill {
            case .solid:
                style.color.setFill()
                NSBezierPath(ovalIn: rect).fill()
            case .ring:
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: ringLineWidth / 2, dy: ringLineWidth / 2))
                path.lineWidth = ringLineWidth
                style.color.setStroke()
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
