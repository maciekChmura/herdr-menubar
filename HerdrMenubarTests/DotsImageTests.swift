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
        #expect(icon.size == NSSize(width: DotsImage.diameter + 2, height: DotsImage.diameter + 2))
    }
}
