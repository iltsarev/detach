import Foundation

public struct UpdateConfiguration: Equatable, Sendable {
    public enum Issue: Equatable, Sendable {
        case unstableApplicationLocation
        case invalidFeedURL
        case invalidPublicKey
    }

    public let issues: [Issue]
    public let feedURL: URL?
    public let manualDownloadURL: URL?

    public var isAvailable: Bool { issues.isEmpty }

    public init(
        feedURLString: String?,
        publicEDKey: String?,
        downloadURLString: String?,
        applicationURL: URL,
        isPackagedApplication: Bool
    ) {
        let feedURL = Self.httpsURL(feedURLString)
        let manualDownloadURL = Self.httpsURL(downloadURLString)
        var issues: [Issue] = []

        if isPackagedApplication, !Self.isStableApplicationLocation(applicationURL) {
            issues.append(.unstableApplicationLocation)
        }
        if feedURL == nil {
            issues.append(.invalidFeedURL)
        }
        if !Self.isValidPublicKey(publicEDKey) {
            issues.append(.invalidPublicKey)
        }

        self.issues = issues
        self.feedURL = feedURL
        self.manualDownloadURL = manualDownloadURL
    }

    public static func isStableApplicationLocation(_ applicationURL: URL) -> Bool {
        let path = applicationURL.standardizedFileURL.path
        return (path == "/Applications/Detach.app" || path.hasPrefix("/Applications/"))
            && !path.contains("/AppTranslocation/") && !path.hasPrefix("/Volumes/")
    }

    private static func httpsURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host != nil else { return nil }
        return url
    }

    private static func isValidPublicKey(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return Data(base64Encoded: trimmed)?.count == 32
    }
}
