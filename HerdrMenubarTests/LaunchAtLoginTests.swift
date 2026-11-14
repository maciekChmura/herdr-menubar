import ServiceManagement
import Testing
@testable import HerdrMenubar

struct LaunchAtLoginTests {
    @Test(arguments: [SMAppService.Status.enabled, .notRegistered, .notFound])
    func titleIsPlainUnlessApprovalIsNeeded(status: SMAppService.Status) {
        #expect(LaunchAtLogin.title(for: status) == "Launch at login")
    }

    @Test func titleSaysWhereToApprove() {
        #expect(LaunchAtLogin.title(for: .requiresApproval) == "Launch at login (approve in System Settings)")
    }
}
