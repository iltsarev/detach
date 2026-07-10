import Foundation

#if canImport(AppKit)
import AppKit

public enum TerminalLauncher {
    /// Returns an error message, or nil on success.
    @discardableResult
    public static func open(command: String) -> String? {
        let source = TerminalCommand.appleScript(for: command)
        guard let script = NSAppleScript(source: source) else {
            return "could not build the AppleScript"
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
            return message ?? "Terminal.app automation failed — проверь System Settings → Privacy & Security → Automation"
        }
        return nil
    }
}
#endif
