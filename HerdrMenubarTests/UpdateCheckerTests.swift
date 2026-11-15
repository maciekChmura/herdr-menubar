import Foundation
import Testing
@testable import HerdrMenubar

struct UpdateCheckerVersionTests {
    @Test(arguments: [
        ("v1.2.3", [1, 2, 3]),
        ("1.2.3", [1, 2, 3]),
        ("0.10.0", [0, 10, 0]),
        ("2", [2]),
    ])
    func readsPlainVersions(version: String, numbers: [Int]) {
        #expect(UpdateChecker.versionNumbers(version) == numbers)
    }

    @Test(arguments: ["", "v", "1.2.0-beta", "v0.3.0-rc.1", "1..2", "1.2.", "+1.2", "1.-2", "latest", "١.٢"])
    func ignoresAnythingElse(version: String) {
        #expect(UpdateChecker.versionNumbers(version) == nil)
    }

    @Test func comparesNumberByNumber() {
        #expect(UpdateChecker.isNewer([0, 10, 0], than: [0, 9, 0]), "Not compared as text")
        #expect(UpdateChecker.isNewer([1, 0], than: [0, 99, 99]))
        #expect(UpdateChecker.isNewer([0, 1, 1], than: [0, 1]))
        #expect(!UpdateChecker.isNewer([0, 1, 0], than: [0, 1]), "Missing numbers count as 0")
        #expect(!UpdateChecker.isNewer([0, 1, 0], than: [0, 1, 0]))
        #expect(!UpdateChecker.isNewer([0, 1, 0], than: [0, 2, 0]))
    }

    @Test func offersANewerRelease() throws {
        let release = try UpdateChecker.Release(tagName: "v0.2.0", htmlURL: page("v0.2.0"))
        let update = UpdateChecker.update(offeredBy: release, currentVersion: "0.1.0")
        #expect(try update == UpdateChecker.Update(version: "0.2.0", url: page("v0.2.0")))
    }

    @Test(arguments: [("v0.1.0", "0.1.0"), ("v0.1", "0.1.0"), ("v0.0.9", "0.1.0"), ("v0.3.0-beta", "0.1.0"), ("v0.2.0", "dev")])
    func offersNothingOtherwise(tag: String, current: String) throws {
        let release = try UpdateChecker.Release(tagName: tag, htmlURL: page(tag))
        #expect(UpdateChecker.update(offeredBy: release, currentVersion: current) == nil)
    }

    @Test(arguments: ["http://github.com/a/b/releases/tag/v9.0.0", "https://example.com/releases/tag/v9.0.0"])
    func opensOnlyGitHubPages(url: String) throws {
        let release = UpdateChecker.Release(tagName: "v9.0.0", htmlURL: try #require(URL(string: url)))
        #expect(UpdateChecker.update(offeredBy: release, currentVersion: "0.1.0") == nil)
    }

    @Test func decodesGitHubsReply() throws {
        let json = """
            {
              "url": "https://api.github.com/repos/maciekChmura/herdr-menubar/releases/1",
              "html_url": "https://github.com/maciekChmura/herdr-menubar/releases/tag/v0.2.0",
              "id": 1,
              "tag_name": "v0.2.0",
              "name": "0.2.0",
              "draft": false,
              "prerelease": false,
              "assets": []
            }
            """
        let release = try JSONDecoder().decode(UpdateChecker.Release.self, from: Data(json.utf8))
        #expect(try release == UpdateChecker.Release(tagName: "v0.2.0", htmlURL: page("v0.2.0")))
    }
}

@MainActor
struct UpdateCheckerCheckTests {
    @Test func remembersANewerReleaseAndChecksAgainTomorrow() async throws {
        let checker = UpdateChecker(currentVersion: "0.1.0", fetch: reply(200, tag: "v0.2.0"))
        var changes = 0
        checker.onChange = { changes += 1 }

        let delay = await checker.check()

        #expect(try checker.available == UpdateChecker.Update(version: "0.2.0", url: page("v0.2.0")))
        #expect(delay == UpdateChecker.checkInterval)
        #expect(changes == 1)

        await checker.check()
        #expect(changes == 1, "The same update again isn't a change")
    }

    @Test func offersNothingWhenUpToDate() async {
        let checker = UpdateChecker(currentVersion: "0.2.0", fetch: reply(200, tag: "v0.2.0"))
        let delay = await checker.check()
        #expect(checker.available == nil)
        #expect(delay == UpdateChecker.checkInterval)
    }

    @Test func aRepoWithoutReleasesIsNotAnError() async {
        let checker = UpdateChecker(currentVersion: "0.1.0", fetch: reply(404))
        let delay = await checker.check()
        #expect(checker.available == nil)
        #expect(delay == UpdateChecker.checkInterval)
    }

    @Test func triesAgainSoonerAfterAFailure() async {
        let offline = UpdateChecker(currentVersion: "0.1.0") { throw URLError(.notConnectedToInternet) }
        #expect(await offline.check() == UpdateChecker.retryInterval)
        #expect(offline.available == nil)

        let rateLimited = UpdateChecker(currentVersion: "0.1.0", fetch: reply(403))
        #expect(await rateLimited.check() == UpdateChecker.retryInterval)

        let garbled = UpdateChecker(currentVersion: "0.1.0", fetch: reply(200, body: "<html>"))
        #expect(await garbled.check() == UpdateChecker.retryInterval)
    }

    private func reply(_ status: Int, tag: String) -> UpdateChecker.Fetch {
        reply(status, body: #"{"tag_name": "\#(tag)", "html_url": "https://github.com/maciekChmura/herdr-menubar/releases/tag/\#(tag)"}"#)
    }

    private func reply(_ status: Int, body: String = "{}") -> UpdateChecker.Fetch {
        { @Sendable in
            let url = URL(string: "https://api.github.com/repos/maciekChmura/herdr-menubar/releases/latest")!
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }
}

private func page(_ tag: String) throws -> URL {
    try #require(URL(string: "https://github.com/maciekChmura/herdr-menubar/releases/tag/\(tag)"))
}
