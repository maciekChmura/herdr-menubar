import QuartzCore

/// The menu bar dot animations, as Core Animation animations. macOS plays them outside the app,
/// so they cost almost no CPU. Redrawing an image for every frame cost about 40% of a core.
///
/// - working: slow breathing, all working dots in step.
/// - blocked: every two seconds a faint ring spreads out from the dot and fades.
/// - done: one small pop when the agent finishes.
/// - any state change: the color fades from the old state to the new one.
/// - idle and unknown: still.
enum DotAnimation {
    static let breathingPeriod: CFTimeInterval = 2.5
    static let breathingMinOpacity: Double = 0.5

    static let pingPeriod: CFTimeInterval = 2
    static let pingDuration: CFTimeInterval = 1.2
    /// How far the ring spreads beyond the dot's edge, in points.
    static let pingGrowth: CGFloat = 3
    static let pingStartOpacity: Double = 0.6

    static let popDuration: CFTimeInterval = 0.35
    /// Extra size at the top of the pop: 0.3 means 30% bigger.
    static let popExtraScale: Double = 0.3

    static let crossfadeDuration: CFTimeInterval = 0.3

    /// Fades the dot between full and `breathingMinOpacity`, forever. Animations that share a `beginTime`
    /// stay in step, even when added at different moments.
    static func breathing(beginTime: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = breathingMinOpacity
        animation.duration = breathingPeriod / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.beginTime = beginTime
        return animation
    }

    /// Spreads a ring from the dot's edge outward while it fades, once every `pingPeriod`, forever.
    /// Between rings the ring layer shows its own opacity, which is 0.
    static func ping(beginTime: CFTimeInterval, diameter: CGFloat) -> CAAnimationGroup {
        let spread = CABasicAnimation(keyPath: "path")
        spread.fromValue = circle(diameter: diameter, centeredIn: diameter)
        spread.toValue = circle(diameter: diameter + 2 * pingGrowth, centeredIn: diameter)
        spread.duration = pingDuration
        spread.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = pingStartOpacity
        fade.toValue = 0.0
        fade.duration = pingDuration

        let group = CAAnimationGroup()
        group.animations = [spread, fade]
        group.duration = pingPeriod
        group.repeatCount = .infinity
        group.beginTime = beginTime
        return group
    }

    /// Grows the dot and settles it back, once.
    static func pop() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, 1.0 + popExtraScale, 1.0]
        animation.keyTimes = [0, 0.5, 1]
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn),
        ]
        animation.duration = popDuration
        return animation
    }

    /// Fades one property of the dot, such as its fill color, from the old state's value to the new one's.
    static func fade(keyPath: String, from: Any?, to: Any?) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = crossfadeDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }

    /// A circle of `diameter`, centered in a square layer whose sides are `side` long.
    static func circle(diameter: CGFloat, centeredIn side: CGFloat) -> CGPath {
        let inset = (side - diameter) / 2
        return CGPath(ellipseIn: CGRect(x: inset, y: inset, width: diameter, height: diameter), transform: nil)
    }
}
