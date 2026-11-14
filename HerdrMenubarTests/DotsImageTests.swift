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

    @Test func isOneDotWidePerAgentWithGapsBetween() {
        #expect(DotsImage.width(forCount: 0) == 0)
        #expect(DotsImage.width(forCount: 1) == DotsImage.diameter)
        #expect(DotsImage.width(forCount: 5) == 5 * DotsImage.diameter + 4 * DotsImage.spacing)
    }

    @Test func keepsItsColorsInTheMenuBar() {
        let image = DotsImage.image(for: [.working, .blocked])
        #expect(image.isTemplate == false, "A template image would be tinted black or white")
        #expect(image.size == NSSize(width: DotsImage.width(forCount: 2), height: DotsImage.height))
    }

    @Test func countsImageKeepsItsColorsAndRedrawsForTheMenuBarAppearance() {
        let image = DotsImage.countsImage(for: [StatusCount(status: .blocked, count: 1), StatusCount(status: .working, count: 12)])
        #expect(image.isTemplate == false)
        #expect(image.cacheMode == .never, "Cached, the numbers would keep the color of the first appearance")
        #expect(image.size.width > 2 * (DotsImage.diameter + DotsImage.countGap) + DotsImage.groupGap)
    }

    @Test func menuIconKeepsItsColors() {
        #expect(DotsImage.menuIcon(for: .done).isTemplate == false)
    }
}
