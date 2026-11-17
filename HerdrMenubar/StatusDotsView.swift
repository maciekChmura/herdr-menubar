import AppKit
import QuartzCore

/// The dots in the menu bar, as Core Animation layers inside the status item's button.
///
/// Each dot keeps its layer while its key stays the same (the pane ID in dots mode, the state in counts mode),
/// so a state change can fade the color and pop the dot. See `DotAnimation` for the animations.
@MainActor
final class StatusDotsView: NSView {
    enum Content: Equatable {
        case dots([PaneStatus])
        /// The counts per state, and how many agents have background jobs.
        case counts([StatusCount], inBackground: Int)
    }

    /// The key of the count of agents with background jobs, in counts mode.
    static let backgroundKey = "background"

    private struct Entry {
        let key: String
        /// Nil for the count of agents with background jobs, which shows only the ring.
        let status: AgentStatus?
        let hasJobs: Bool
        let count: Int?
    }

    @MainActor
    private final class Item {
        let key: String
        var status: AgentStatus?
        var hasJobs: Bool
        var count: Int?
        /// Positions the dot; `dot`, `ring` and `jobRing` fill it.
        let holder = CALayer()
        let dot = CAShapeLayer()
        /// Only visible while a blocked dot's ring animation is playing.
        let ring = CAShapeLayer()
        /// The green ring around an agent with background jobs.
        let jobRing = CAShapeLayer()
        let label: NSTextField?

        init(entry: Entry) {
            key = entry.key
            status = entry.status
            hasJobs = entry.hasJobs
            count = entry.count
            if entry.count != nil {
                let field = NSTextField(labelWithString: "")
                field.font = DotsImage.countFont
                field.textColor = .labelColor
                label = field
            } else {
                label = nil
            }
            ring.fillColor = nil
            ring.lineWidth = 1
            ring.opacity = 0
            jobRing.fillColor = nil
            jobRing.lineWidth = DotsImage.jobRingLineWidth
            holder.addSublayer(ring)
            holder.addSublayer(jobRing)
            holder.addSublayer(dot)
        }
    }

    /// Breathing and rings all count from this moment, so every dot moves in step.
    private static let epoch = CACurrentMediaTime()

    private let dotsLayer = CALayer()
    private var items: [Item] = []
    private var hasShownContent = false
    private var animationsEnabled = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(dotsLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Clicks go to the status bar button underneath, which opens the menu.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withoutImplicitAnimations { items.forEach(applyStyle) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        withoutImplicitAnimations { items.forEach(applyScale) }
    }

    /// Forgets the current dots, so the next `show` starts fresh, without fades or pops.
    func reset() {
        for item in items {
            item.holder.removeFromSuperlayer()
            item.label?.removeFromSuperview()
        }
        items = []
        hasShownContent = false
    }

    /// Shows `content` and returns the width it needs.
    ///
    /// The first call after creating the view or after `reset()` only sets up the dots. Later calls fade a dot
    /// whose state changed and pop one that just turned done, if `animationsEnabled`.
    @discardableResult
    func show(_ content: Content, animationsEnabled: Bool, height: CGFloat) -> CGFloat {
        self.animationsEnabled = animationsEnabled
        let animateChanges = hasShownContent && animationsEnabled
        var existing = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [Item] = []

        let width = withoutImplicitAnimations {
            for entry in Self.entries(for: content) {
                let item: Item
                if let reused = existing.removeValue(forKey: entry.key) {
                    item = reused
                    let before = (status: item.status, count: item.count)
                    item.status = entry.status
                    item.hasJobs = entry.hasJobs
                    item.count = entry.count
                    if animateChanges, let old = before.status, let new = entry.status, old != new {
                        fade(item, from: old, to: new)
                    }
                    let finished = before.status != .done || (entry.count ?? 0) > (before.count ?? 0)
                    if animateChanges, entry.status == .done, finished {
                        item.dot.add(DotAnimation.pop(), forKey: "pop")
                    }
                } else {
                    item = Item(entry: entry)
                    dotsLayer.addSublayer(item.holder)
                    if let label = item.label { addSubview(label) }
                    applyScale(item)
                    // In counts mode, the done dot appears when the first agent finishes.
                    if animateChanges, entry.status == .done, entry.count != nil {
                        item.dot.add(DotAnimation.pop(), forKey: "pop")
                    }
                }
                applyStyle(item)
                applyContinuousAnimation(item)
                item.label?.stringValue = entry.count.map(String.init) ?? ""
                next.append(item)
            }
            for gone in existing.values {
                gone.holder.removeFromSuperlayer()
                gone.label?.removeFromSuperview()
            }
            items = next
            return layout(height: height)
        }
        hasShownContent = true
        return width
    }

    private static func entries(for content: Content) -> [Entry] {
        switch content {
        case .dots(let panes):
            return panes.map { Entry(key: $0.paneId, status: $0.status, hasJobs: $0.hasBackgroundJobs, count: nil) }
        case .counts(let counts, let inBackground):
            var entries = counts.map { Entry(key: "state:\($0.status.rawValue)", status: $0.status, hasJobs: false, count: $0.count) }
            if inBackground > 0 {
                let background = Entry(key: backgroundKey, status: nil, hasJobs: true, count: inBackground)
                entries.insert(background, at: MenuBarLabel.backgroundIndex(in: counts))
            }
            return entries
        }
    }

    // MARK: Drawing

    private struct ShapeValues {
        let fill: CGColor
        let stroke: CGColor
        let lineWidth: CGFloat
        let path: CGPath
    }

    private func shapeValues(for status: AgentStatus) -> ShapeValues {
        let style = DotsImage.style(for: status)
        let color = resolved(style.color)
        let diameter = DotsImage.diameter
        switch style.fill {
        case .solid:
            return ShapeValues(
                fill: color, stroke: .clear, lineWidth: 0,
                path: DotAnimation.circle(diameter: diameter, centeredIn: diameter)
            )
        case .ring:
            let width = DotsImage.ringLineWidth
            return ShapeValues(
                fill: .clear, stroke: color, lineWidth: width,
                path: DotAnimation.circle(diameter: diameter - width, centeredIn: diameter)
            )
        }
    }

    private func applyStyle(_ item: Item) {
        if let status = item.status {
            let values = shapeValues(for: status)
            item.dot.fillColor = values.fill
            item.dot.strokeColor = values.stroke
            item.dot.lineWidth = values.lineWidth
            item.dot.path = values.path
            item.ring.strokeColor = resolved(DotsImage.style(for: status).color)
        } else {
            item.dot.path = nil
        }
        item.ring.path = DotAnimation.circle(diameter: DotsImage.diameter, centeredIn: DotsImage.diameter)
        item.jobRing.strokeColor = resolved(DotsImage.jobRingColor)
        item.jobRing.path = DotsImage.jobRingPath
        item.jobRing.isHidden = !item.hasJobs
    }

    private func fade(_ item: Item, from previous: AgentStatus, to status: AgentStatus) {
        let old = shapeValues(for: previous)
        let new = shapeValues(for: status)
        item.dot.add(DotAnimation.fade(keyPath: "fillColor", from: old.fill, to: new.fill), forKey: "fadeFill")
        item.dot.add(DotAnimation.fade(keyPath: "strokeColor", from: old.stroke, to: new.stroke), forKey: "fadeStroke")
        item.dot.add(DotAnimation.fade(keyPath: "lineWidth", from: old.lineWidth, to: new.lineWidth), forKey: "fadeLineWidth")
        item.dot.add(DotAnimation.fade(keyPath: "path", from: old.path, to: new.path), forKey: "fadePath")
    }

    private func applyContinuousAnimation(_ item: Item) {
        item.dot.removeAnimation(forKey: "breathing")
        item.ring.removeAnimation(forKey: "ping")
        item.jobRing.removeAnimation(forKey: "breathing")
        guard animationsEnabled else { return }
        if item.hasJobs {
            item.jobRing.add(DotAnimation.breathing(beginTime: Self.epoch), forKey: "breathing")
        }
        switch item.status {
        case .working:
            item.dot.add(DotAnimation.breathing(beginTime: Self.epoch), forKey: "breathing")
        case .blocked:
            item.ring.add(DotAnimation.ping(beginTime: Self.epoch, diameter: DotsImage.diameter), forKey: "ping")
        case .done, .idle, .unknown, nil:
            break
        }
    }

    private func applyScale(_ item: Item) {
        // Shape layers are drawn at this scale; without it they'd be blurry on a Retina display.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for layer in [item.holder, item.dot, item.ring, item.jobRing] {
            layer.contentsScale = scale
        }
    }

    /// The color as it looks in this view's appearance, which follows the menu bar.
    private func resolved(_ color: NSColor) -> CGColor {
        var cgColor = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cgColor = color.cgColor }
        return cgColor
    }

    private func layout(height: CGFloat) -> CGFloat {
        let diameter = DotsImage.diameter
        var x = DotsImage.padding
        for (index, item) in items.enumerated() {
            // A dot with a ring takes the ring's room on both sides, so rings never touch their neighbors.
            let ringRoom = item.hasJobs ? DotsImage.jobRingExtent : 0
            x += ringRoom
            item.holder.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            item.holder.position = CGPoint(x: x + diameter / 2, y: height / 2)
            item.dot.frame = item.holder.bounds
            item.ring.frame = item.holder.bounds
            item.jobRing.frame = item.holder.bounds
            x += diameter + ringRoom
            let isLast = index == items.count - 1
            if let label = item.label {
                label.sizeToFit()
                x += DotsImage.countGap
                label.setFrameOrigin(NSPoint(x: x, y: ((height - label.frame.height) / 2).rounded()))
                x += label.frame.width
                if !isLast { x += DotsImage.groupGap }
            } else if !isLast {
                x += DotsImage.spacing
            }
        }
        let width = (x + DotsImage.padding).rounded(.up)
        dotsLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        return width
    }

    private func withoutImplicitAnimations<T>(_ body: () -> T) -> T {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        return body()
    }

    // MARK: For tests

    var shownKeys: [String] { items.map(\.key) }

    var countTexts: [String] { items.compactMap { $0.label?.stringValue } }

    func dotAnimationKeys(for key: String) -> Set<String> {
        Set(items.first { $0.key == key }?.dot.animationKeys() ?? [])
    }

    func ringAnimationKeys(for key: String) -> Set<String> {
        Set(items.first { $0.key == key }?.ring.animationKeys() ?? [])
    }

    func showsJobRing(for key: String) -> Bool {
        items.first { $0.key == key }.map { !$0.jobRing.isHidden && $0.jobRing.path != nil } ?? false
    }

    func showsDot(for key: String) -> Bool {
        items.first { $0.key == key }?.dot.path != nil
    }

    func jobRingAnimationKeys(for key: String) -> Set<String> {
        Set(items.first { $0.key == key }?.jobRing.animationKeys() ?? [])
    }
}
