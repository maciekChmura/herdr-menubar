import AppKit

/// Draws one small colored dot per agent for the menu bar, like the status dots in other Mac apps.
/// Emoji can't do this: they're drawn at text size with their own shading.
enum DotsImage {
    /// The same size in the menu bar and in front of the menu rows.
    static let diameter: CGFloat = 10
    static let spacing: CGFloat = 4
    /// Tall enough to center the dots in the menu bar.
    static let height: CGFloat = 16

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

    static func width(forCount count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * diameter + CGFloat(count - 1) * spacing
    }

    /// A non-template image, so the menu bar keeps the colors instead of tinting it black or white.
    static func image(for statuses: [AgentStatus]) -> NSImage {
        let size = NSSize(width: width(forCount: statuses.count), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            for (index, status) in statuses.enumerated() {
                let rect = NSRect(
                    x: CGFloat(index) * (diameter + spacing),
                    y: (height - diameter) / 2,
                    width: diameter,
                    height: diameter
                )
                draw(style(for: status), in: rect)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Space between a dot and its number, and between one number and the next dot.
    static let countGap: CGFloat = 3
    static let groupGap: CGFloat = 9

    static var countFont: NSFont {
        .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    /// A dot followed by its number for each state, such as "● 1  ● 2".
    ///
    /// The numbers use the system text color, resolved when the menu bar draws the image, so they're black on a
    /// light menu bar and white on a dark one. The image isn't cached, so it follows the menu bar when that changes.
    static func countsImage(for counts: [StatusCount]) -> NSImage {
        let font = countFont
        let numberWidths = counts.map { ceil(NSAttributedString(string: "\($0.count)", attributes: [.font: font]).size().width) }
        let width = zip(counts, numberWidths).reduce(CGFloat(0)) { total, pair in
            total + diameter + countGap + pair.1
        } + groupGap * CGFloat(max(counts.count - 1, 0))

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (item, numberWidth) in zip(counts, numberWidths) {
                draw(style(for: item.status), in: NSRect(x: x, y: (height - diameter) / 2, width: diameter, height: diameter))
                x += diameter + countGap
                let number = NSAttributedString(
                    string: "\(item.count)",
                    attributes: [.font: font, .foregroundColor: NSColor.labelColor]
                )
                number.draw(at: NSPoint(x: x, y: (height - number.size().height) / 2))
                x += numberWidth + groupGap
            }
            return true
        }
        image.isTemplate = false
        image.cacheMode = .never
        return image
    }

    /// The dot shown before an agent's title in the menu.
    static func menuIcon(for status: AgentStatus) -> NSImage {
        let size = NSSize(width: diameter + 2, height: diameter + 2)
        let image = NSImage(size: size, flipped: false) { _ in
            draw(style(for: status), in: NSRect(x: 1, y: 1, width: diameter, height: diameter))
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(_ style: Style, in rect: NSRect) {
        switch style.fill {
        case .solid:
            style.color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        case .ring:
            let lineWidth: CGFloat = 1.5
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            path.lineWidth = lineWidth
            style.color.setStroke()
            path.stroke()
        }
    }
}
