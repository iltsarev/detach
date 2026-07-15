import Darwin
import DetachKit
import Foundation
import Security

private func log(_ message: String) {
    FileHandle.standardError.write(Data("DetachPowerHelper: \(message)\n".utf8))
}

private final class CodeSigningIdentityResolver {
    func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess,
              let code,
              let info = signingInformation(for: code) else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func signingInformation(for code: SecCode) -> [String: Any]? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information)
        guard status == errSecSuccess else { return nil }
        return information as? [String: Any]
    }
}

private final class PowerHelperListenerDelegate:
    NSObject, NSXPCListenerDelegate
{
    private let exportedObject: PowerHelperXPCService
    private let authorizationPolicy = PowerHelperClientAuthorizationPolicy()

    init(exportedObject: PowerHelperXPCService) {
        self.exportedObject = exportedObject
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // The listener-level code requirement validates the audit token and
        // signature before this delegate is called. Foundation also derives
        // effectiveUserIdentifier from that connection identity. Do not
        // replace either check with a PID lookup: process identifiers are
        // subject to reuse races.
        let clientUserIdentifier = UInt32(
            connection.effectiveUserIdentifier)
        let consoleUserIdentifier = currentConsoleUserIdentifier()
        let authorization = authorizationPolicy.decision(
            clientEffectiveUserIdentifier: clientUserIdentifier,
            consoleUserIdentifier: consoleUserIdentifier)
        guard authorization == .allowed else {
            let consoleDescription = consoleUserIdentifier.map {
                String($0)
            } ?? "none"
            log(
                "rejected XPC client (effective uid "
                    + "\(clientUserIdentifier), console uid "
                    + "\(consoleDescription), reason "
                    + "\(authorization.rawValue))")
            return false
        }
        connection.exportedInterface = NSXPCInterface(
            with: DetachPowerHelperXPCProtocol.self)
        connection.exportedObject = exportedObject
        connection.resume()
        return true
    }

    private func currentConsoleUserIdentifier() -> UInt32? {
        var metadata = stat()
        guard Darwin.lstat("/dev/console", &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFCHR else {
            return nil
        }
        return UInt32(metadata.st_uid)
    }
}

guard geteuid() == 0 else {
    log("must run as root through the bundled launch daemon")
    exit(1)
}

do {
    // Establish the framework-enforced trust boundary before any root power
    // mutation. An ad-hoc or otherwise untrusted helper exits without touching
    // machine state.
    let resolver = CodeSigningIdentityResolver()
    guard let teamIdentifier = resolver.ownTeamIdentifier(),
          let clientRequirement = PowerHelperCodeSigningRequirement.client(
              teamIdentifier: teamIdentifier) else {
        log("helper is missing a trusted Team ID signature")
        exit(1)
    }

    // Create the separate machine-wide app handoff rendezvous before accepting
    // clients. Every logged-in user opens this root-owned inode read-only, so
    // only one app process can drive SMAppService replacement at a time.
    try PowerHelperSystemHandoffLock().ensureExists()
    // Acquire the kernel lifetime barrier before creating the service or XPC
    // listener. A successful prepare response therefore proves this helper
    // generation already holds the contract, and the descriptor remains
    // locked until the process actually exits.
    let lifetimeBarrierLease = try PowerHelperLifetimeBarrier().acquire()
    let leaseService = try PowerHelperLeaseService(
        store: SecureFilePowerHelperStateStore(),
        backend: PMSetClosedLidProtectionController(),
        batteryReader: PMSetBatterySafetyReader(),
        bootSessionReader: SysctlBootSessionReader())
    let bridge = PowerHelperXPCService(service: leaseService)
    let delegate = PowerHelperListenerDelegate(exportedObject: bridge)
    let listener = NSXPCListener(
        machServiceName: PowerHelperXPCContract.machServiceName)
    listener.setConnectionCodeSigningRequirement(clientRequirement)
    listener.delegate = delegate

    let reconciliationQueue = DispatchQueue(
        label: "dev.tsarev.detach.power-helper.reconcile",
        qos: .utility)
    let reconciliationTimer = DispatchSource.makeTimerSource(
        queue: reconciliationQueue)
    // XPC status reads only the cached snapshot. One bounded reconciliation
    // every ten seconds keeps low-battery and external-setting changes fresh
    // without letting UI/tmux polling fan out into root pmset processes.
    reconciliationTimer.schedule(deadline: .now() + 10, repeating: 10)
    reconciliationTimer.setEventHandler {
        do {
            _ = try leaseService.reconcile()
        } catch {
            log("periodic reconciliation failed: \(error.localizedDescription)")
        }
    }
    // Install orderly shutdown handling before startup reconciliation can
    // acquire ownership of the persistent machine setting.
    Darwin.signal(SIGTERM, SIG_IGN)
    Darwin.signal(SIGINT, SIG_IGN)
    let terminationSource = DispatchSource.makeSignalSource(
        signal: SIGTERM, queue: .main)
    let interruptSource = DispatchSource.makeSignalSource(
        signal: SIGINT, queue: .main)
    let terminate: @Sendable () -> Void = {
        var restored = false
        for attempt in 1...3 {
            do {
                try leaseService.prepareForTermination()
                restored = true
                break
            } catch {
                log(
                    "could not restore normal sleep on shutdown "
                        + "(attempt \(attempt)/3): \(error.localizedDescription)")
                if attempt < 3 { usleep(250_000) }
            }
        }
        // Crash-only KeepAlive restarts a still-registered helper after a
        // failed restoration. App-driven unregister is separately guarded by
        // prepareForUnregistration, so it never relies on this fallback.
        exit(restored ? 0 : 1)
    }
    terminationSource.setEventHandler(handler: terminate)
    interruptSource.setEventHandler(handler: terminate)
    terminationSource.resume()
    interruptSource.resume()

    do {
        _ = try leaseService.reconcile()
    } catch {
        // Keep XPC reachable so callers receive an honest unavailable result;
        // the periodic reconciler will retry transient pmset failures.
        log("startup reconciliation failed: \(error.localizedDescription)")
    }

    reconciliationTimer.resume()
    listener.resume()
    // NSXPCListener.delegate is weak. Explicitly retain the delegate and all
    // event sources for the complete daemon lifetime, including optimized
    // release builds.
    withExtendedLifetime((lifetimeBarrierLease, delegate,
                          reconciliationQueue, reconciliationTimer,
                          terminationSource, interruptSource)) {
        RunLoop.main.run()
    }
} catch {
    log(error.localizedDescription)
    exit(1)
}
