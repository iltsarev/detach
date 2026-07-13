import Foundation

#if canImport(AppKit)
import AppKit

public struct TerminalLaunchFailure: Equatable, Sendable {
    public let message: String
    public let requiresAutomationPermission: Bool
}

public enum TerminalLauncher {
    /// Returns a typed failure, or nil on success. Calling this method is also
    /// the just-in-time trigger for macOS' Terminal Automation prompt.
    @MainActor
    @discardableResult
    public static func open(command: String) -> TerminalLaunchFailure? {
        let source = TerminalCommand.appleScript(for: command)
        guard let script = NSAppleScript(source: source) else {
            return TerminalLaunchFailure(
                message: "Не удалось подготовить команду для Terminal.",
                requiresAutomationPermission: false)
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            return failure(from: errorInfo)
        }
        return nil
    }

    static func failure(from errorInfo: NSDictionary) -> TerminalLaunchFailure {
        let number = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        let denied = number == Int(errAEEventNotPermitted)
        if denied {
            return TerminalLaunchFailure(
                message: "Разрешите Detach управлять Terminal в Системных настройках.",
                requiresAutomationPermission: true)
        }
        let message = errorInfo[NSAppleScript.errorMessage] as? String
            ?? "Terminal не смог открыть команду."
        return TerminalLaunchFailure(
            message: message,
            requiresAutomationPermission: false)
    }

    @MainActor
    public static func openAutomationSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}
#endif
