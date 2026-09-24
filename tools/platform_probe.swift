// Observes the SMAppService behavior that Detach's power handoff relies on,
// using a dedicated probe label that never touches the real helper or
// watchdog. Built, signed, and run by scripts/platform-probe.

import Foundation
import ServiceManagement

// Each run uses a label that has never been registered: Background Task
// Management keeps a record for a label after its first registration, and
// the absent-record facts need a label without one.
guard let plistIndex = CommandLine.arguments.firstIndex(of: "--plist"),
      plistIndex + 1 < CommandLine.arguments.count else {
    if CommandLine.arguments.contains("--agent-idle") { exit(0) }
    FileHandle.standardError.write(Data("usage: DetachPlatformProbe --plist NAME\n".utf8))
    exit(2)
}
let plistName = CommandLine.arguments[plistIndex + 1]

if CommandLine.arguments.contains("--agent-idle") {
    exit(0)
}

func statusName(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown"
    }
}

func errorShape(_ error: Error?) -> String {
    guard let error else { return "success" }
    let nsError = error as NSError
    return "\(nsError.domain)/\(nsError.code)"
}

func unregister(_ service: SMAppService) -> String {
    let done = DispatchSemaphore(value: 0)
    var shape = "timeout"
    service.unregister { error in
        shape = errorShape(error)
        done.signal()
    }
    if done.wait(timeout: .now() + 30) == .timedOut { return "timeout" }
    return shape
}

func fresh() -> SMAppService { SMAppService.agent(plistName: plistName) }

var facts: [(String, String)] = []
facts.append(("smappservice.agent.status.absent", statusName(fresh().status)))
facts.append(("smappservice.agent.unregister.absent", unregister(fresh())))

var registerShape = "success"
do { try fresh().register() } catch { registerShape = errorShape(error) }
facts.append(("smappservice.agent.register", registerShape))
Thread.sleep(forTimeInterval: 1)
facts.append(("smappservice.agent.status.registered", statusName(fresh().status)))
facts.append(("smappservice.agent.unregister.registered", unregister(fresh())))
Thread.sleep(forTimeInterval: 1)
facts.append(("smappservice.agent.status.after-unregister", statusName(fresh().status)))
facts.append(("smappservice.agent.unregister.after-unregister", unregister(fresh())))

// Leave nothing registered even if a step above behaved unexpectedly.
if fresh().status != .notRegistered { _ = unregister(fresh()) }

for (identifier, value) in facts {
    print("\(identifier)\t\(value)")
}
