import Foundation

public protocol DetachPowerCommandExecuting: Sendable {
    func execute(arguments: [String]) throws -> DetachPowerCommandResult
}

extension DetachPowerCommand: DetachPowerCommandExecuting {}

public protocol DetachPowerOutputWriting: Sendable {
    func writeStandardOutput(_ data: Data)
    func writeStandardError(_ data: Data)
}

public struct FileHandleDetachPowerOutput: DetachPowerOutputWriting {
    private let standardOutput: FileHandle
    private let standardError: FileHandle

    public init(
        standardOutput: FileHandle = .standardOutput,
        standardError: FileHandle = .standardError
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public func writeStandardOutput(_ data: Data) {
        standardOutput.write(data)
    }

    public func writeStandardError(_ data: Data) {
        standardError.write(data)
    }
}

/// Thin executable adapter that maps typed command results onto stdout/stderr
/// and stable process exit codes.
public struct DetachPowerExecutable: Sendable {
    public static let temporaryFailureExitCode: Int32 = 75

    private let command: any DetachPowerCommandExecuting
    private let output: any DetachPowerOutputWriting

    public init(
        command: any DetachPowerCommandExecuting,
        output: any DetachPowerOutputWriting = FileHandleDetachPowerOutput()
    ) {
        self.command = command
        self.output = output
    }

    public func run(arguments: [String]) -> Int32 {
        do {
            let result = try command.execute(arguments: arguments)
            switch result {
            case let .statusJSON(data):
                var line = data
                if line.last != 0x0A {
                    line.append(0x0A)
                }
                output.writeStandardOutput(line)
            case .child:
                break
            case .lifecycle:
                break
            }
            return result.exitCode
        } catch let error as PowerHelperLifecycleError {
            output.writeStandardError(Data("detach-power: \(error.localizedDescription)\n".utf8))
            return Self.temporaryFailureExitCode
        } catch let error as DetachPowerCommandError {
            output.writeStandardError(Data("detach-power: \(error.localizedDescription)\n".utf8))
            if case .usage = error {
                return 2
            }
            return 1
        } catch {
            output.writeStandardError(Data("detach-power: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
