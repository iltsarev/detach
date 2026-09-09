import Darwin
import DetachKit
import Foundation

_ = umask(0o077)

let arguments = Array(CommandLine.arguments.dropFirst())
let helperTransport: any PowerHelperXPCTransport = NSXPCPowerHelperTransport()
let helperClient = PowerHelperXPCClient(transport: helperTransport)
let command = DetachPowerCommand(
    helperClient: helperClient,
    assertionController: PowerAssertionController(),
    childRunner: ProcessChildCommandRunner(),
    heartbeatRunner: DispatchPowerHeartbeatRunner(),
    clamshellLockRunner: ClamshellLockRunner())
let executable = DetachPowerExecutable(command: command)
exit(executable.run(arguments: arguments))
