import AppKit
import Testing
@testable import HerdrMenubar

@MainActor
struct StatusDotsViewTests {
    let height: CGFloat = 22

    @Test func showsOneDotPerAgentInHerdrsOrder() {
        let view = StatusDotsView()
        let width = view.show(.dots([pane("a", .working), pane("b", .idle), pane("c", .blocked)]), animationsEnabled: true, height: height)

        #expect(view.shownKeys == ["a", "b", "c"])
        #expect(width == 2 * DotsImage.padding + 3 * DotsImage.diameter + 2 * DotsImage.spacing)
    }

    @Test func workingDotsBreatheAndBlockedDotsSendRings() {
        let view = StatusDotsView()
        view.show(.dots([pane("a", .working), pane("b", .blocked), pane("c", .idle)]), animationsEnabled: true, height: height)

        #expect(view.dotAnimationKeys(for: "a") == ["breathing"])
        #expect(view.ringAnimationKeys(for: "b") == ["ping"])
        #expect(view.dotAnimationKeys(for: "c").isEmpty)
        #expect(view.ringAnimationKeys(for: "c").isEmpty)
    }

    @Test func nothingAnimatesWhenAnimationIsOff() {
        let view = StatusDotsView()
        view.show(.dots([pane("a", .working), pane("b", .blocked)]), animationsEnabled: false, height: height)
        view.show(.dots([pane("a", .done), pane("b", .blocked)]), animationsEnabled: false, height: height)

        #expect(view.dotAnimationKeys(for: "a").isEmpty)
        #expect(view.ringAnimationKeys(for: "b").isEmpty)
    }

    @Test func theFirstShowNeitherFadesNorPops() {
        let view = StatusDotsView()
        view.show(.dots([pane("a", .done)]), animationsEnabled: true, height: height)

        #expect(view.dotAnimationKeys(for: "a").isEmpty)
    }

    @Test func aDotThatFinishesFadesAndPops() {
        let view = StatusDotsView()
        view.show(.dots([pane("a", .working)]), animationsEnabled: true, height: height)
        view.show(.dots([pane("a", .done)]), animationsEnabled: true, height: height)

        let keys = view.dotAnimationKeys(for: "a")
        #expect(keys.contains("pop"))
        #expect(keys.contains("fadeFill"))
        #expect(!keys.contains("breathing"), "A done dot stops breathing")
    }

    @Test func otherChangesFadeWithoutPopping() {
        let view = StatusDotsView()
        view.show(.dots([pane("a", .working)]), animationsEnabled: true, height: height)
        view.show(.dots([pane("a", .blocked)]), animationsEnabled: true, height: height)

        #expect(view.dotAnimationKeys(for: "a").contains("fadeFill"))
        #expect(!view.dotAnimationKeys(for: "a").contains("pop"))
        #expect(view.ringAnimationKeys(for: "a") == ["ping"])
    }

    @Test func aNewlyDetectedAgentDoesNotPop() {
        let view = StatusDotsView()
        view.show(.dots([pane("a", .idle)]), animationsEnabled: true, height: height)
        view.show(.dots([pane("a", .idle), pane("b", .done)]), animationsEnabled: true, height: height)

        #expect(view.dotAnimationKeys(for: "b").isEmpty)
    }

    @Test func goneAgentsLoseTheirDots() {
        let view = StatusDotsView()
        view.show(.dots([pane("a", .idle), pane("b", .idle)]), animationsEnabled: true, height: height)
        view.show(.dots([pane("b", .idle)]), animationsEnabled: true, height: height)

        #expect(view.shownKeys == ["b"])
    }

    @Test func afterAResetNothingFadesOrPops() {
        let view = StatusDotsView()
        view.show(.dots([pane("a", .working)]), animationsEnabled: true, height: height)
        view.reset()
        view.show(.dots([pane("a", .done)]), animationsEnabled: true, height: height)

        #expect(view.dotAnimationKeys(for: "a").isEmpty)
    }

    @Test func countsShowADotAndANumberPerState() {
        let view = StatusDotsView()
        let width = view.show(.counts([count(.blocked, 1), count(.working, 12)]), animationsEnabled: true, height: height)

        #expect(view.shownKeys == ["state:blocked", "state:working"])
        #expect(view.countTexts == ["1", "12"])
        #expect(width > 2 * DotsImage.padding + 2 * (DotsImage.diameter + DotsImage.countGap) + DotsImage.groupGap)
    }

    @Test func theDoneCountPopsWhenAnotherAgentFinishes() {
        let view = StatusDotsView()
        view.show(.counts([count(.working, 2)]), animationsEnabled: true, height: height)
        view.show(.counts([count(.working, 1), count(.done, 1)]), animationsEnabled: true, height: height)
        #expect(view.dotAnimationKeys(for: "state:done").contains("pop"), "The first agent to finish brings in the done dot")

        view.show(.counts([count(.done, 2)]), animationsEnabled: true, height: height)
        #expect(view.dotAnimationKeys(for: "state:done").contains("pop"))
        #expect(view.countTexts == ["2"])
    }

    private func pane(_ id: String, _ status: AgentStatus) -> PaneStatus {
        PaneStatus(paneId: id, status: status)
    }

    private func count(_ status: AgentStatus, _ count: Int) -> StatusCount {
        StatusCount(status: status, count: count)
    }
}
