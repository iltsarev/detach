import DetachKit
import Foundation
import Security

/// Keeps local and ad-hoc app copies read-only at the ServiceManagement
/// boundary. A preview may inspect status, but only the complete Developer ID
/// release identity may replace the shared watchdog or root helper.
enum ServiceManagementMutationAdmission {
    private static let expectedBundleIdentifier = "dev.tsarev.detach"
    private static let managedCodeIdentifiers = [
        "dev.tsarev.detach",
        "dev.tsarev.detach.power-helper",
        "dev.tsarev.detach.power-watchdog",
    ]

    static let currentBundleIsReleaseSigned = releaseSignedBundle(.main)

    static func permits(
        bundleIdentifier: String?,
        validatedTeams: [String: String]
    ) -> Bool {
        guard bundleIdentifier == expectedBundleIdentifier,
              validatedTeams.count == managedCodeIdentifiers.count,
              let team = validatedTeams[expectedBundleIdentifier],
              PowerHelperCodeSigningRequirement.client(
                teamIdentifier: team) != nil else {
            return false
        }
        return managedCodeIdentifiers.allSatisfy {
            validatedTeams[$0] == team
        }
    }

    static func releaseSignedBundle(_ bundle: Bundle) -> Bool {
        guard let executable = bundle.executableURL else { return false }
        let contents = bundle.bundleURL.appendingPathComponent(
            "Contents", isDirectory: true)
        let locations = [
            expectedBundleIdentifier: executable,
            "dev.tsarev.detach.power-helper": contents.appendingPathComponent(
                "MacOS/DetachPowerHelper"),
            "dev.tsarev.detach.power-watchdog": contents.appendingPathComponent(
                "MacOS/DetachWatchdog"),
        ]
        var teams: [String: String] = [:]
        for identifier in managedCodeIdentifiers {
            guard let location = locations[identifier],
                  let team = validatedTeamIdentifier(
                    at: location,
                    expectedIdentifier: identifier) else {
                return false
            }
            teams[identifier] = team
        }
        return permits(
            bundleIdentifier: bundle.bundleIdentifier,
            validatedTeams: teams)
    }

    private static func validatedTeamIdentifier(
        at location: URL,
        expectedIdentifier: String
    ) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            location as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode else { return nil }

        let validationFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(
            staticCode, validationFlags, nil) == errSecSuccess else {
            return nil
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information) == errSecSuccess,
            let values = information as? [String: Any],
            let identifier = values[kSecCodeInfoIdentifier as String]
                as? String,
            identifier == expectedIdentifier,
            let team = values[kSecCodeInfoTeamIdentifier as String]
                as? String,
            PowerHelperCodeSigningRequirement.client(
                teamIdentifier: team) != nil else {
            return nil
        }

        let source = "anchor apple generic and identifier "
            + "\"\(expectedIdentifier)\" and certificate "
            + "1[field.1.2.840.113635.100.6.2.6] /* exists */ and "
            + "certificate leaf[field.1.2.840.113635.100.6.1.13] "
            + "/* exists */ and certificate "
            + "leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            source as CFString, [], &requirement) == errSecSuccess,
            let requirement,
            SecStaticCodeCheckValidity(
                staticCode, validationFlags, requirement) == errSecSuccess else {
            return nil
        }
        return team
    }
}
