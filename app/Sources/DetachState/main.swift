import Darwin
import DetachKit
import Foundation

_ = umask(0o077)

if Array(CommandLine.arguments.dropFirst()) == ["mcp", "workspace-dependencies"] {
    WorkspaceDependenciesMCPServer.serve()
    exit(EXIT_SUCCESS)
}

do {
    let output = try DetachStateCommand.run(
        arguments: Array(CommandLine.arguments.dropFirst()))
    FileHandle.standardOutput.write(output)
} catch {
    let message = "detach-state: \(error)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}
