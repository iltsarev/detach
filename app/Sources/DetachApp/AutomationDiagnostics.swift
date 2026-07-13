import AppKit
import ApplicationServices
import Foundation

enum AutomationStatus: Equatable, Sendable {
    case notChecked
    case allowed
    case denied(String)
}

enum AutomationDiagnostics {
    static func preflightTerminal() async -> AutomationStatus? {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Terminal").isEmpty else { return nil }
        return await Task.detached {
            let descriptor = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal")
            guard let target = descriptor.aeDesc else { return nil }
            let result = AEDeterminePermissionToAutomateTarget(
                target, typeWildCard, typeWildCard, false)
            switch result {
            case noErr:
                return .allowed
            case OSStatus(errAEEventNotPermitted):
                return .denied("Terminal Automation запрещён в System Settings")
            case OSStatus(errAEEventWouldRequireUserConsent):
                return .notChecked
            default:
                return nil
            }
        }.value
    }

    static func probeTerminal() async -> AutomationStatus {
        await Task.detached {
            let source = "tell application \"Terminal\" to count windows"
            guard let script = NSAppleScript(source: source) else {
                return .denied("Не удалось создать AppleScript")
            }
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let message = errorInfo[NSAppleScript.errorMessage] as? String
                    ?? "Terminal Automation запрещён"
                return .denied(message)
            }
            return .allowed
        }.value
    }

    @MainActor
    static func openAutomationSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}
