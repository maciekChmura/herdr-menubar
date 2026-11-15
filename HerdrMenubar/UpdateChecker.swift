import Foundation
import OSLog

/// Asks GitHub whether a newer release is out, so the menu can offer it. See "Update check" in `docs/PRD.md`.
/// It never downloads or installs anything.
@MainActor
final class UpdateChecker {
    struct Update: Equatable, Sendable {
        var version: String
        /// The release page on github.com.
        var url: URL
    }

    /// The part of GitHub's "latest release" reply that the check reads.
    struct Release: Decodable, Equatable, Sendable {
        var tagName: String
        var htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    typealias Fetch = @Sendable () async throws -> (Data, URLResponse)

    static let checkInterval: Duration = .seconds(24 * 60 * 60)
    static let retryInterval: Duration = .seconds(60 * 60)

    /// Called when `available` changes.
    var onChange: (() -> Void)?

    /// The newer release, if there is one.
    private(set) var available: Update? {
        didSet { if available != oldValue { onChange?() } }
    }

    /// The "Check for updates" setting, remembered across launches. Turning it off stops checking
    /// and forgets the update the menu was offering.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }

    private let currentVersion: String
    private let fetch: Fetch
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "io.github.maciekchmura.HerdrMenubar", category: "updates")

    private static let enabledKey = "CheckForUpdates"

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         fetch: @escaping Fetch = UpdateChecker.fetchFromGitHub(url: UpdateChecker.latestReleaseURL)) {
        self.currentVersion = currentVersion
        self.fetch = fetch
        // On by default. bool(forKey:) also reads "NO" and "0", as given by a launch argument or `defaults write`.
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Checks now and then every 24 hours, while the setting is on. Calling it again while running does nothing.
    func start() {
        guard isEnabled, task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.check() else { return }
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        available = nil
    }

    /// Asks GitHub once and updates `available`. Returns how long to wait before asking again.
    @discardableResult
    func check() async -> Duration {
        do {
            let (data, response) = try await fetch()
            guard !Task.isCancelled else { return Self.retryInterval }
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                let release = try JSONDecoder().decode(Release.self, from: data)
                available = Self.update(offeredBy: release, currentVersion: currentVersion)
                if let available {
                    log.info("Update available: \(available.version, privacy: .public)")
                } else {
                    log.info("Up to date: \(self.currentVersion, privacy: .public), latest release \(release.tagName, privacy: .public)")
                }
            case 404:
                available = nil
                log.info("No releases on GitHub yet")
            case let status:
                log.error("Couldn't check for updates: HTTP \(status ?? 0, privacy: .public)")
                return Self.retryInterval
            }
            return Self.checkInterval
        } catch {
            if !Task.isCancelled {
                log.error("Couldn't check for updates: \(String(describing: error), privacy: .public)")
            }
            return Self.retryInterval
        }
    }

    // MARK: Comparing versions

    /// The update to offer, or nil when the release isn't newer than `currentVersion`, its tag isn't
    /// plain numbers, or its page isn't on github.com.
    nonisolated static func update(offeredBy release: Release, currentVersion: String) -> Update? {
        guard let latest = versionNumbers(release.tagName),
              let current = versionNumbers(currentVersion),
              isNewer(latest, than: current),
              release.htmlURL.scheme == "https",
              release.htmlURL.host() == "github.com"
        else { return nil }
        return Update(version: latest.map(String.init).joined(separator: "."), url: release.htmlURL)
    }

    /// "v1.2.3" or "1.2.3" as numbers, or nil for anything else, such as "1.2.0-beta".
    nonisolated static func versionNumbers(_ version: String) -> [Int]? {
        let digits = version.hasPrefix("v") ? version.dropFirst() : Substring(version)
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        // Only digits: Int() alone would also accept "+1" and "-1".
        let numbers = parts.compactMap { part in part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil }
        return numbers.count == parts.count ? numbers : nil
    }

    /// Compares number by number; missing numbers count as 0, so 1.2 and 1.2.0 are the same version.
    nonisolated static func isNewer(_ version: [Int], than other: [Int]) -> Bool {
        let length = max(version.count, other.count)
        let padded = { (numbers: [Int]) in numbers + Array(repeating: 0, count: length - numbers.count) }
        return padded(other).lexicographicallyPrecedes(padded(version))
    }

    // MARK: GitHub

    /// The repo's latest release, or the `UpdateCheckURL` setting when it's set, for testing.
    static var latestReleaseURL: URL {
        UserDefaults.standard.string(forKey: "UpdateCheckURL").flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/maciekChmura/herdr-menubar/releases/latest")!
    }

    nonisolated static func fetchFromGitHub(url: URL) -> Fetch {
        {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            return try await session.data(for: request)
        }
    }

    /// Ephemeral, so nothing about the check is cached on disk.
    private nonisolated static let session = URLSession(configuration: .ephemeral)
}
