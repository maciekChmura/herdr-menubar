import AppKit
import Testing
@testable import HerdrMenubar

struct DotsImageTests {
    @Test func usesSystemColorsWithARingForUnknown() {
        #expect(DotsImage.style(for: .blocked) == .init(color: .systemRed, fill: .solid))
        #expect(DotsImage.style(for: .working) == .init(color: .systemGreen, fill: .solid))
        #expect(DotsImage.style(for: .done) == .init(color: .systemBlue, fill: .solid))
        #expect(DotsImage.style(for: .idle) == .init(color: .systemGray, fill: .solid))
        #expect(DotsImage.style(for: .unknown) == .init(color: .systemGray, fill: .ring))
    }

    @Test(arguments: AgentStatus.allCases)
    func menuIconKeepsItsColors(status: AgentStatus) {
        let icon = DotsImage.menuIcon(for: status)
        #expect(icon.isTemplate == false, "A template image would be tinted black or white")
        #expect(icon.size == DotsImage.menuIconSize)
    }

    @Test func menuIconsWithAndWithoutTheRingAreTheSameSizeSoTitlesLineUp() {
        let ringed = DotsImage.menuIcon(for: .done, hasBackgroundJobs: true)
        #expect(ringed.size == DotsImage.menuIcon(for: .done).size)
        #expect(ringed.size.width >= DotsImage.diameter + 2 * DotsImage.jobRingExtent, "Room for the whole ring")
    }

    @Test func theRingIsGreenLikeWorking() {
        #expect(DotsImage.jobRingColor == DotsImage.style(for: .working).color)
    }
}
