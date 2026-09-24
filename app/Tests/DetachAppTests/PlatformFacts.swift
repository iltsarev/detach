import Foundation

/// Observed SMAppService behavior from quality/platform-facts.tsv, written by
/// scripts/platform-probe on a real Mac. Fakes that model registration take
/// their shapes from here, so a macOS change fails these tests after
/// `scripts/platform-probe record` instead of hiding behind assumed codes.
enum PlatformFacts {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DetachAppTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // app
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("quality/platform-facts.tsv")

    static func value(_ fact: String) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        var matches: [String] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.count >= 2, fields[0] == Substring(fact) {
                matches.append(String(fields[1]))
            }
        }
        // A missing or duplicate fact is a corrupt table, never a default.
        guard matches.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return matches[0]
    }

    /// `Domain/code` → NSError, or nil for `success`.
    static func error(_ fact: String) throws -> NSError? {
        let shape = try value(fact)
        if shape == "success" { return nil }
        guard let slash = shape.lastIndex(of: "/"),
              let code = Int(shape[shape.index(after: slash)...]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return NSError(domain: String(shape[..<slash]), code: code)
    }

    /// True when a label without a Background Task Management record reports
    /// `.notFound` (folded into the app's `unavailable` status).
    static func absentRecordReportsNotFound() throws -> Bool {
        // Only the two shapes the handoff can treat as absence are accepted.
        // Any other recorded status must fail the tests, not model absence.
        switch try value("smappservice.agent.status.absent") {
        case "notFound": return true
        case "notRegistered": return false
        default: throw CocoaError(.fileReadCorruptFile)
        }
    }
}
