import QuartzCore
import Testing
@testable import HerdrMenubar

struct DotAnimationTests {
    @Test func breathingFadesToHalfAndBackForever() {
        let animation = DotAnimation.breathing(beginTime: 42)
        #expect(animation.keyPath == "opacity")
        #expect(animation.fromValue as? Double == 1)
        #expect(animation.toValue as? Double == DotAnimation.breathingMinOpacity)
        #expect(animation.autoreverses)
        #expect(animation.duration * 2 == DotAnimation.breathingPeriod, "Down and back up make one breath")
        #expect(animation.repeatCount == .infinity)
        #expect(animation.beginTime == 42, "A shared begin time keeps all working dots in step")
    }

    @Test func aRingSpreadsAndFadesOnceEveryPeriodForever() throws {
        let group = DotAnimation.ping(beginTime: 42, diameter: 10)
        #expect(group.duration == DotAnimation.pingPeriod)
        #expect(group.repeatCount == .infinity)
        #expect(group.beginTime == 42)

        let parts = try #require(group.animations as? [CABasicAnimation])
        let spread = try #require(parts.first { $0.keyPath == "path" })
        let fade = try #require(parts.first { $0.keyPath == "opacity" })
        #expect(spread.duration == DotAnimation.pingDuration)
        #expect(fade.duration == DotAnimation.pingDuration)
        #expect(fade.fromValue as? Double == DotAnimation.pingStartOpacity)
        #expect(fade.toValue as? Double == 0)

        let from = (spread.fromValue as! CGPath).boundingBox
        let to = (spread.toValue as! CGPath).boundingBox
        #expect(from.width == 10)
        #expect(to.width == 10 + 2 * DotAnimation.pingGrowth)
        #expect(to.midX == from.midX && to.midY == from.midY, "The ring spreads evenly around the dot")
    }

    @Test func popGrowsAndSettlesOnce() {
        let animation = DotAnimation.pop()
        #expect(animation.keyPath == "transform.scale")
        #expect(animation.values as? [Double] == [1, 1 + DotAnimation.popExtraScale, 1])
        #expect(animation.duration == DotAnimation.popDuration)
        #expect(animation.repeatCount == 0)
    }

    @Test func fadeTakesTheCrossfadeDuration() {
        let animation = DotAnimation.fade(keyPath: "fillColor", from: CGColor.black, to: CGColor.white)
        #expect(animation.keyPath == "fillColor")
        #expect(animation.duration == DotAnimation.crossfadeDuration)
    }

    @Test func circleIsCenteredInItsLayer() {
        let box = DotAnimation.circle(diameter: 16, centeredIn: 10).boundingBox
        #expect(box == CGRect(x: -3, y: -3, width: 16, height: 16))
    }

    @Test func roomForTheRingAndThePop() {
        let ringDiameter = DotsImage.diameter + 2 * DotAnimation.pingGrowth
        let poppedDiameter = DotsImage.diameter * (1 + CGFloat(DotAnimation.popExtraScale))
        let menuBarHeight: CGFloat = 22
        #expect(ringDiameter <= menuBarHeight)
        #expect(poppedDiameter <= menuBarHeight)
        // At the ends, the padding plus half the dot must hold half the ring.
        #expect(DotsImage.padding + DotsImage.diameter / 2 >= ringDiameter / 2)
    }
}
