import Darwin
import DetachKit
import Foundation

_ = umask(0o077)

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.starts(with: ["events", "watch"]) {
        try SessionFileEventWatcher.run(arguments: Array(arguments.dropFirst(2)))
    }
    let output = try DetachStateCommand.run(arguments: arguments)
    FileHandle.standardOutput.write(output)
} catch {
    let message = "detach-state: \(error)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}
