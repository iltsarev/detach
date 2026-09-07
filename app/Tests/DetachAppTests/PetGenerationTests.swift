import Foundation
import XCTest
@testable import DetachApp
@testable import DetachKit

final class PetGenerationTests: XCTestCase {
    func testGenerationPhaseTracksTheManagedCLISession() {
        XCTAssertEqual(
            PetGenerationPhase.resolve(
                isAvailable: true,
                isStarting: false,
                pendingPetID: "",
                pendingSessionID: "",
                pendingSessionStatus: nil,
                pendingTurnState: nil),
            .idle)
        XCTAssertEqual(
            PetGenerationPhase.resolve(
                isAvailable: true,
                isStarting: true,
                pendingPetID: "",
                pendingSessionID: "",
                pendingSessionStatus: nil,
                pendingTurnState: nil),
            .starting)
        XCTAssertEqual(
            PetGenerationPhase.resolve(
                isAvailable: true,
                isStarting: false,
                pendingPetID: "detach-random-pending",
                pendingSessionID: "detach-codex-random-pet",
                pendingSessionStatus: .running,
                pendingTurnState: .working),
            .running)
        XCTAssertEqual(
            PetGenerationPhase.resolve(
                isAvailable: false,
                isStarting: false,
                pendingPetID: "detach-random-pending",
                pendingSessionID: "detach-codex-random-pet",
                pendingSessionStatus: .running,
                pendingTurnState: .needsInput),
            .attention)
        XCTAssertEqual(
            PetGenerationPhase.resolve(
                isAvailable: false,
                isStarting: false,
                pendingPetID: "detach-random-pending",
                pendingSessionID: "detach-codex-random-pet",
                pendingSessionStatus: .running,
                pendingTurnState: .waiting),
            .attention)
        XCTAssertEqual(
            PetGenerationPhase.resolve(
                isAvailable: false,
                isStarting: false,
                pendingPetID: "detach-random-pending",
                pendingSessionID: "detach-codex-random-pet",
                pendingSessionStatus: nil,
                pendingTurnState: nil,
                hasFreshSessionSnapshot: true),
            .missingSession)
        XCTAssertEqual(
            PetGenerationPhase.resolve(
                isAvailable: true,
                isStarting: false,
                pendingPetID: "detach-random-pending",
                pendingSessionID: "detach-codex-random-pet",
                pendingSessionStatus: nil,
                pendingTurnState: nil,
                hasFreshSessionSnapshot: false),
            .checkingSession)
        XCTAssertEqual(
            PetGenerationPhase.resolve(
                isAvailable: true,
                isStarting: false,
                pendingPetID: "detach-random-pending",
                pendingSessionID: "detach-codex-random-pet",
                pendingSessionStatus: .recoverable,
                pendingTurnState: .working),
            .attention)
        XCTAssertEqual(
            PetGenerationPhase.resolve(
                isAvailable: true,
                isStarting: false,
                pendingPetID: "detach-random-pending",
                pendingSessionID: "detach-codex-random-pet",
                pendingSessionStatus: .completed,
                pendingTurnState: nil),
            .finished)
        XCTAssertEqual(
            PetGenerationPhase.resolve(
                isAvailable: true,
                isStarting: false,
                pendingPetID: "detach-random-pending",
                pendingSessionID: "detach-codex-random-pet",
                pendingSessionStatus: .running,
                pendingTurnState: .working,
                trackingTimedOut: true),
            .trackingTimedOut)
    }

    func testRequestPinsAUniqueV2PackageAndRandomVisualBrief() throws {
        let root = URL(fileURLWithPath: "/tmp/codex/pets", isDirectory: true)
        let identifier = try XCTUnwrap(UUID(
            uuidString: "11111111-2222-3333-4444-555555555555"))

        let request = RandomPetGenerationRequest.make(
            libraryRoot: root,
            identifier: identifier,
            character: "test creature",
            style: "test style",
            palette: "test palette",
            personality: "test personality")

        XCTAssertEqual(
            request.petID,
            "detach-random-11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(request.sessionName, "Random pet 11111111")
        XCTAssertTrue(request.prompt.contains("$hatch-pet"))
        XCTAssertTrue(request.prompt.contains("формата v2"))
        XCTAssertTrue(request.prompt.contains("test creature"))
        XCTAssertTrue(request.prompt.contains("test style"))
        XCTAssertTrue(request.prompt.contains("test palette"))
        XCTAssertTrue(request.prompt.contains("test personality"))
        XCTAssertTrue(request.prompt.contains(
            "/tmp/codex/pets/\(request.petID)"))
        XCTAssertTrue(request.prompt.contains(
            "Не изменяй и не перезаписывай другие пакеты"))
        XCTAssertTrue(request.prompt.contains(
            "не запрашивай разрешение ради необязательной очистки"))
        XCTAssertTrue(request.prompt.contains(
            "Если QA не проходит, исправляй артефакты"))
    }

    func testRequestBuildsOneSessionScopedReadOnlyRuntimeMCPConfiguration() {
        let root = URL(fileURLWithPath: "/tmp/codex/pets", isDirectory: true)
        let request = RandomPetGenerationRequest.make(
            libraryRoot: root,
            identifier: UUID(
                uuidString: "11111111-2222-3333-4444-555555555555")!,
            character: "test creature",
            style: "test style",
            palette: "test palette",
            personality: "test personality")
        let arguments = request.codexProviderArguments(runtimeHelperURL:
            URL(fileURLWithPath: "/tmp/Detach CLI/detach-state"))

        XCTAssertEqual(Array(arguments.prefix(2)), [
            "--disable", "tool_search_always_defer_mcp_tools",
        ])
        XCTAssertTrue(arguments.contains(
            #"mcp_servers.detach_workspace_dependencies.command="/tmp/Detach CLI/detach-state""#))
        XCTAssertTrue(arguments.contains(
            #"mcp_servers.detach_workspace_dependencies.args=["mcp","workspace-dependencies"]"#))
        XCTAssertTrue(arguments.contains(
            #"mcp_servers.detach_workspace_dependencies.enabled_tools=["load_workspace_dependencies"]"#))
        XCTAssertTrue(arguments.contains(
            #"mcp_servers.detach_workspace_dependencies.default_tools_approval_mode="approve""#))
        XCTAssertTrue(arguments.contains(
            "mcp_servers.detach_workspace_dependencies.required=true"))
    }

    func testGenerationSupportRequiresRegularHatchPetSkillFile() throws {
        let codexRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "detach-pet-generation-tests-\(UUID().uuidString)",
                isDirectory: true)
        let libraryRoot = codexRoot.appendingPathComponent(
            "pets", isDirectory: true)
        let skillURL = PetGenerationSupport.skillURL(
            for: libraryRoot)
        let runtimeRoot = try makeRuntimeRoot(in: codexRoot)
        try FileManager.default.createDirectory(
            at: skillURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: codexRoot)
        }

        XCTAssertFalse(PetGenerationSupport.isAvailable(
            libraryRoot: libraryRoot,
            runtimeHelperURL: URL(fileURLWithPath: "/bin/sh"),
            runtimeRoot: runtimeRoot))
        try Data("# Hatch Pet".utf8).write(to: skillURL)
        XCTAssertTrue(PetGenerationSupport.isAvailable(
            libraryRoot: libraryRoot,
            runtimeHelperURL: URL(fileURLWithPath: "/bin/sh"),
            runtimeRoot: runtimeRoot))
        XCTAssertFalse(PetGenerationSupport.isAvailable(
            libraryRoot: libraryRoot,
            runtimeHelperURL: codexRoot.appendingPathComponent("missing"),
            runtimeRoot: runtimeRoot))
        XCTAssertEqual(PetGenerationSupport.availability(
            libraryRoot: libraryRoot,
            runtimeHelperURL: URL(fileURLWithPath: "/bin/sh"),
            runtimeRoot: codexRoot.appendingPathComponent("missing-runtime")),
            .missingRuntime)
    }

    func testGenerationSupportRejectsSymlinkedSkillFile() throws {
        let codexRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "detach-pet-generation-tests-\(UUID().uuidString)",
                isDirectory: true)
        let libraryRoot = codexRoot.appendingPathComponent(
            "pets", isDirectory: true)
        let skillURL = PetGenerationSupport.skillURL(
            for: libraryRoot)
        let realSkill = codexRoot.appendingPathComponent("real-skill.md")
        try FileManager.default.createDirectory(
            at: skillURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("# Hatch Pet".utf8).write(to: realSkill)
        try FileManager.default.createSymbolicLink(
            at: skillURL,
            withDestinationURL: realSkill)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: codexRoot)
        }

        XCTAssertFalse(PetGenerationSupport.isAvailable(
            libraryRoot: libraryRoot,
            runtimeHelperURL: URL(fileURLWithPath: "/bin/sh")))
    }

    func testRuntimeHelperLivesBesideTheActiveDetachCLI() {
        XCTAssertEqual(
            PetGenerationSupport.runtimeHelperURL(
                detachPath: "/tmp/Detach CLI/detach").path,
            "/tmp/Detach CLI/detach-state")
    }

    func testRuntimeHelperResolvesTheInstalledPublicSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "detach-pet-helper-tests-\(UUID().uuidString)",
                isDirectory: true)
        let publicBin = root.appendingPathComponent("bin", isDirectory: true)
        let payload = root.appendingPathComponent(
            "libexec/detach/versions/0.5.2-test",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: publicBin,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: payload,
            withIntermediateDirectories: true)
        let executable = payload.appendingPathComponent("detach")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        let publicURL = publicBin.appendingPathComponent("detach")
        try FileManager.default.createSymbolicLink(
            at: publicURL,
            withDestinationURL: executable)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            PetGenerationSupport.runtimeHelperURL(detachPath: publicURL.path),
            payload.appendingPathComponent("detach-state"))
    }

    func testSessionMonitorSeparatesActiveAttentionAndStoppedStates() {
        XCTAssertEqual(
            PetGenerationSessionMonitor.state(
                status: .running, turnState: .working),
            .active)
        XCTAssertEqual(
            PetGenerationSessionMonitor.state(
                status: .running, turnState: .waiting),
            .attention)
        XCTAssertEqual(
            PetGenerationSessionMonitor.state(
                status: .running, turnState: .needsInput),
            .attention)
        XCTAssertEqual(
            PetGenerationSessionMonitor.state(
                status: .recoverable, turnState: .working),
            .attention)
        XCTAssertEqual(
            PetGenerationSessionMonitor.state(
                status: .hung, turnState: .working),
            .attention)
        XCTAssertEqual(
            PetGenerationSessionMonitor.state(
                status: .completed, turnState: nil),
            .stopped)
        XCTAssertEqual(
            PetGenerationSessionMonitor.state(
                status: .failed, turnState: nil),
            .stopped)
        XCTAssertEqual(
            PetGenerationSessionMonitor.state(
                status: .hung, turnState: nil),
            .attention)
        XCTAssertEqual(
            PetGenerationSessionMonitor.packageCheckIntervalNanoseconds,
            2_000_000_000)
        XCTAssertEqual(PetGenerationSessionMonitor.maximumPackageChecks, 1_800)
    }

    private func makeRuntimeRoot(in parent: URL) throws -> URL {
        let root = parent.appendingPathComponent(
            "codex-primary-runtime", isDirectory: true)
        for directory in [
            "dependencies/bin/fallback",
            "dependencies/bin/override",
            "dependencies/node/bin",
            "dependencies/node/node_modules",
            "dependencies/python/bin",
        ] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true)
        }
        try JSONSerialization.data(withJSONObject: [
            "bundleFormatVersion": 2,
            "bundleVersion": "pet-test-runtime",
        ]).write(to: root.appendingPathComponent("runtime.json"))
        for relativePath in [
            "dependencies/bin/fallback/git",
            "dependencies/bin/fallback/pnpm",
            "dependencies/node/bin/node",
            "dependencies/python/bin/python3",
        ] {
            let executable = root.appendingPathComponent(relativePath)
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path)
        }
        return root
    }
}
