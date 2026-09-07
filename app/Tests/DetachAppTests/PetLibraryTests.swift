import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DetachApp

final class PetLibraryTests: XCTestCase {
    func testMissingLibraryRootIsAnEmptyLibrary() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "detach-missing-pet-library-\(UUID().uuidString)",
            isDirectory: true)

        let result = PetLibraryLoader.load(from: root)

        XCTAssertTrue(result.packages.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertTrue(result.accessIssues.isEmpty)
    }

    func testReportsLibraryRootThatCannotBeReadAsDirectory() throws {
        let parent = try temporaryDirectory()
        let root = parent.appendingPathComponent("pets")
        try Data("not a directory".utf8).write(to: root)

        let result = PetLibraryLoader.load(from: root)

        XCTAssertTrue(result.packages.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.accessIssues, [PetLibraryAccessIssue(
            source: .codexLibrary,
            reason: .invalidRoot,
        )])
    }

    func testReportsSymlinkedLibraryRoot() throws {
        let parent = try temporaryDirectory()
        let destination = parent.appendingPathComponent(
            "destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("pets")
        try FileManager.default.createSymbolicLink(
            at: root, withDestinationURL: destination)

        let result = PetLibraryLoader.load(from: root)

        XCTAssertTrue(result.packages.isEmpty)
        XCTAssertEqual(result.accessIssues, [PetLibraryAccessIssue(
            source: .codexLibrary,
            reason: .invalidRoot,
        )])
    }

    func testReportsBrokenSymlinkedLibraryRoot() throws {
        let parent = try temporaryDirectory()
        let root = parent.appendingPathComponent("pets")
        try FileManager.default.createSymbolicLink(
            at: root,
            withDestinationURL: parent.appendingPathComponent("missing"))

        let result = PetLibraryLoader.load(from: root)

        XCTAssertTrue(result.packages.isEmpty)
        XCTAssertEqual(result.accessIssues, [PetLibraryAccessIssue(
            source: .codexLibrary,
            reason: .invalidRoot,
        )])
    }

    func testLoadsV1AndV2PackagesAndSortsByDisplayName() throws {
        let root = try temporaryDirectory()
        try writePackage(root: root, folder: "zeta", id: "zeta",
                         displayName: "Zeta", version: nil, rows: 9)
        try writePackage(root: root, folder: "alpha", id: "alpha",
                         displayName: "Alpha", version: 2, rows: 11)

        let result = PetLibraryLoader.load(from: root)

        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.packages.map(\.id), ["alpha", "zeta"])
        XCTAssertEqual(result.packages.map(\.spriteVersionNumber), [2, 1])
        XCTAssertEqual(result.packages.map(\.rows), [11, 9])
        XCTAssertEqual(result.packages.map(\.source), [
            .codexLibrary, .codexLibrary,
        ])
    }

    func testOrdinaryFilesDoNotConsumeThePackageLimit() throws {
        let root = try temporaryDirectory()
        for index in 0..<PetLibraryLoader.maximumPackages {
            try Data().write(to: root.appendingPathComponent(
                String(format: "file-%03d", index)))
        }
        try writePackage(
            root: root,
            folder: "z-valid",
            id: "valid-id",
            displayName: "Valid",
            version: 2,
            rows: 11)

        let result = PetLibraryLoader.load(from: root)

        XCTAssertEqual(result.packages.map(\.id), ["valid-id"])
    }

    func testRejectsWrongAtlasDimensions() throws {
        let root = try temporaryDirectory()
        try writePackage(root: root, folder: "wrong", id: "wrong",
                         displayName: "Wrong", version: 2, rows: 1)

        let result = PetLibraryLoader.load(from: root)

        XCTAssertTrue(result.packages.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.issues[0].reason.contains("1536×2288"))
    }

    func testRejectsSpritePathEscape() throws {
        let root = try temporaryDirectory()
        let package = root.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package, withIntermediateDirectories: true)
        try writeManifest(
            at: package,
            id: "escape",
            displayName: "Escape",
            version: 2,
            spritesheetPath: "../outside.webp")

        let result = PetLibraryLoader.load(from: root)

        XCTAssertTrue(result.packages.isEmpty)
        XCTAssertTrue(result.issues[0].reason.contains("inside the pet package"))
    }

    func testRejectsSymlinkedSpritesheet() throws {
        let root = try temporaryDirectory()
        let outside = root.appendingPathComponent("outside.png")
        try writeImage(at: outside, width: 1_536, height: 2_288)
        let package = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("spritesheet.png"),
            withDestinationURL: outside)
        try writeManifest(
            at: package,
            id: "linked",
            displayName: "Linked",
            version: 2,
            spritesheetPath: "spritesheet.png")

        let result = PetLibraryLoader.load(from: root)

        XCTAssertTrue(result.packages.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
    }

    func testDefaultRootHonorsCodexHome() {
        XCTAssertEqual(
            PetLibraryLoader.defaultRoot(
                environment: ["CODEX_HOME": "/tmp/custom-codex"]).path,
            "/tmp/custom-codex/pets")
    }

    func testMergedLibraryUsesBundledPetsAsFallback() throws {
        let userRoot = try temporaryDirectory()
        let bundledRoot = try temporaryDirectory()
        try writePackage(
            root: userRoot,
            folder: "user-shared",
            id: "shared",
            displayName: "User Shared",
            version: 2,
            rows: 11)
        try writePackage(
            root: bundledRoot,
            folder: "bundled-shared",
            id: "shared",
            displayName: "Bundled Shared",
            version: 2,
            rows: 11)
        try writePackage(
            root: bundledRoot,
            folder: "bundled-only",
            id: "bundled-only",
            displayName: "Bundled Only",
            version: 2,
            rows: 11)

        let result = PetLibraryLoader.load(
            userRoot: userRoot,
            bundledRoot: bundledRoot)

        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.packages.map(\.id), ["bundled-only", "shared"])
        XCTAssertEqual(
            result.packages.first { $0.id == "shared" }?.displayName,
            "User Shared")
        XCTAssertEqual(
            result.packages.first { $0.id == "shared" }?.source,
            .codexLibrary)
        XCTAssertEqual(
            result.packages.first { $0.id == "bundled-only" }?.source,
            .bundled)
    }

    func testRejectsMalformedManifestAndUnsupportedImageExtension() throws {
        let root = try temporaryDirectory()
        let malformed = root.appendingPathComponent("malformed", isDirectory: true)
        try FileManager.default.createDirectory(
            at: malformed, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: malformed.appendingPathComponent("pet.json"))

        let extensionPackage = root.appendingPathComponent(
            "extension", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extensionPackage, withIntermediateDirectories: true)
        try writeManifest(
            at: extensionPackage,
            id: "extension",
            displayName: "Extension",
            version: 2,
            spritesheetPath: "spritesheet.gif")
        try Data([0]).write(
            to: extensionPackage.appendingPathComponent("spritesheet.gif"))

        let result = PetLibraryLoader.load(from: root)

        XCTAssertTrue(result.packages.isEmpty)
        XCTAssertEqual(Set(result.issues.map(\.packageName)), ["extension", "malformed"])
        XCTAssertTrue(result.issues.contains { $0.reason.contains("PNG or WebP") })
    }

    func testInstallerCopiesValidatedPackageAndLeavesSourceUntouched() throws {
        let sourceRoot = try temporaryDirectory()
        let libraryRoot = try temporaryDirectory()
        try writePackage(
            root: sourceRoot,
            folder: "new-friend",
            id: "new-friend",
            displayName: "New Friend",
            version: 2,
            rows: 11)
        let source = sourceRoot.appendingPathComponent(
            "new-friend", isDirectory: true)
        try Data("not part of the pet format".utf8).write(
            to: source.appendingPathComponent("notes.txt"))

        let installed = try PetLibraryInstaller.install(
            from: source,
            into: libraryRoot)

        XCTAssertEqual(installed.id, "new-friend")
        XCTAssertEqual(
            installed.directoryURL.deletingLastPathComponent().standardizedFileURL,
            libraryRoot.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: source.appendingPathComponent("pet.json").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: installed.directoryURL.appendingPathComponent("notes.txt").path))
        XCTAssertEqual(
            PetLibraryLoader.load(from: libraryRoot).packages.map(\.id),
            ["new-friend"])
    }

    func testInstallerRejectsDuplicateIDWithoutReplacingExistingPet() throws {
        let sourceRoot = try temporaryDirectory()
        let libraryRoot = try temporaryDirectory()
        try writePackage(
            root: libraryRoot,
            folder: "original",
            id: "shared-id",
            displayName: "Original",
            version: 2,
            rows: 11)
        try writePackage(
            root: sourceRoot,
            folder: "replacement",
            id: "shared-id",
            displayName: "Replacement",
            version: 2,
            rows: 11)

        XCTAssertThrowsError(try PetLibraryInstaller.install(
            from: sourceRoot.appendingPathComponent("replacement"),
            into: libraryRoot)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already installed"))
        }

        let result = PetLibraryLoader.load(from: libraryRoot)
        XCTAssertEqual(result.packages.map(\.displayName), ["Original"])
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: libraryRoot.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".pet-import-") })
    }

    func testInstallerRejectsInvalidPackageBeforeCreatingLibrary() throws {
        let sourceRoot = try temporaryDirectory()
        let libraryRoot = sourceRoot.appendingPathComponent(
            "missing-library", isDirectory: true)
        try writePackage(
            root: sourceRoot,
            folder: "invalid",
            id: "invalid",
            displayName: "Invalid",
            version: 2,
            rows: 1)

        XCTAssertThrowsError(try PetLibraryInstaller.install(
            from: sourceRoot.appendingPathComponent("invalid"),
            into: libraryRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryRoot.path))
    }

    func testInstallerIgnoresOrdinaryFilesWhenEnforcingPackageLimit() throws {
        let sourceRoot = try temporaryDirectory()
        let libraryRoot = try temporaryDirectory()
        try writePackage(
            root: sourceRoot,
            folder: "source",
            id: "source-id",
            displayName: "Source",
            version: 2,
            rows: 11)
        for index in 0..<PetLibraryLoader.maximumPackages {
            try Data().write(to: libraryRoot.appendingPathComponent(
                String(format: "file-%03d", index)))
        }

        let installed = try PetLibraryInstaller.install(
            from: sourceRoot.appendingPathComponent("source"),
            into: libraryRoot)

        XCTAssertEqual(installed.id, "source-id")
    }

    func testInstallerReusesPackageAlreadyStoredInLibrary() throws {
        let libraryRoot = try temporaryDirectory()
        try writePackage(
            root: libraryRoot,
            folder: "existing",
            id: "existing",
            displayName: "Existing",
            version: 2,
            rows: 11)
        let source = libraryRoot.appendingPathComponent(
            "existing", isDirectory: true)

        let installed = try PetLibraryInstaller.install(
            from: source,
            into: libraryRoot)

        XCTAssertEqual(installed.directoryURL, source.standardizedFileURL)
        XCTAssertEqual(
            PetLibraryLoader.load(from: libraryRoot).packages.map(\.id),
            ["existing"])
    }

    func testInstallerRejectsSymlinkedPackageDirectory() throws {
        let sourceRoot = try temporaryDirectory()
        let libraryRoot = sourceRoot.appendingPathComponent(
            "library", isDirectory: true)
        try writePackage(
            root: sourceRoot,
            folder: "real-package",
            id: "linked-package",
            displayName: "Linked Package",
            version: 2,
            rows: 11)
        let link = sourceRoot.appendingPathComponent(
            "package-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: sourceRoot.appendingPathComponent("real-package"))

        XCTAssertThrowsError(try PetLibraryInstaller.install(
            from: link,
            into: libraryRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryRoot.path))
    }

    func testInstallerRejectsSymlinkedLibraryRootWithoutWriting() throws {
        let parent = try temporaryDirectory()
        let destination = parent.appendingPathComponent(
            "destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        let libraryRoot = parent.appendingPathComponent(
            "library", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: libraryRoot, withDestinationURL: destination)
        let sourceRoot = try temporaryDirectory()
        try writePackage(
            root: sourceRoot,
            folder: "source",
            id: "source-id",
            displayName: "Source",
            version: 2,
            rows: 11)

        XCTAssertThrowsError(try PetLibraryInstaller.install(
            from: sourceRoot.appendingPathComponent("source"),
            into: libraryRoot)) { error in
            XCTAssertEqual(
                (error as? PetLibraryRootAccessError)?.issue,
                PetLibraryAccessIssue(
                    source: .codexLibrary,
                    reason: .invalidRoot))
        }
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil)).isEmpty)
    }

    @MainActor
    func testReloadSelectsACompletedPendingGeneratedPet() throws {
        let libraryRoot = try temporaryDirectory()
        try writePackage(
            root: libraryRoot,
            folder: "generated-id",
            id: "generated-id",
            displayName: "Generated",
            version: 2,
            rows: 11)
        let suiteName = "detach-generated-pet-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(
            "generated-id",
            forKey: PetCoordinator.pendingGeneratedPetIDKey)
        defaults.set(
            "generator-session",
            forKey: PetCoordinator.pendingGeneratedPetSessionIDKey)
        defaults.set(
            "prepared prompt",
            forKey: PetCoordinator.pendingGeneratedPetPromptKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: libraryRoot,
            bundledLibraryRoot: nil)

        coordinator.reloadLibrary()

        XCTAssertEqual(coordinator.selectedPetID, "generated-id")
        XCTAssertNil(defaults.string(
            forKey: PetCoordinator.pendingGeneratedPetIDKey))
        XCTAssertNil(defaults.string(
            forKey: PetCoordinator.pendingGeneratedPetSessionIDKey))
        XCTAssertNil(defaults.string(
            forKey: PetCoordinator.pendingGeneratedPetPromptKey))
        XCTAssertNotNil(coordinator.atlas)
    }

    @MainActor
    func testAppScopedTrackingSelectsAnAlreadyWrittenPackage() throws {
        let libraryRoot = try temporaryDirectory()
        try writePackage(
            root: libraryRoot,
            folder: "generated-id",
            id: "generated-id",
            displayName: "Generated",
            version: 2,
            rows: 11)
        let suiteName = "detach-app-pet-watch-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: libraryRoot,
            bundledLibraryRoot: nil)

        coordinator.beginGeneratedPetTracking(
            petID: "generated-id",
            sessionID: "generator-session")

        XCTAssertEqual(coordinator.selectedPetID, "generated-id")
        XCTAssertNil(defaults.string(
            forKey: PetCoordinator.pendingGeneratedPetIDKey))
        XCTAssertNil(defaults.string(
            forKey: PetCoordinator.pendingGeneratedPetSessionIDKey))
    }

    @MainActor
    func testPendingGeneratedPetBeyondLibraryLimitIsStillSelected() throws {
        let libraryRoot = try temporaryDirectory()
        for index in 0..<PetLibraryLoader.maximumPackages {
            try FileManager.default.createDirectory(
                at: libraryRoot.appendingPathComponent(
                    String(format: "a-invalid-%03d", index),
                    isDirectory: true),
                withIntermediateDirectories: false)
        }
        try writePackage(
            root: libraryRoot,
            folder: "z-generated-id",
            id: "z-generated-id",
            displayName: "Generated Beyond Limit",
            version: 2,
            rows: 11)
        let suiteName = "detach-pet-limit-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "z-generated-id",
            forKey: PetCoordinator.pendingGeneratedPetIDKey)
        defaults.set(
            "generator-session",
            forKey: PetCoordinator.pendingGeneratedPetSessionIDKey)
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: libraryRoot,
            bundledLibraryRoot: nil)

        coordinator.reloadLibrary()

        XCTAssertEqual(coordinator.selectedPetID, "z-generated-id")
        XCTAssertEqual(coordinator.packages.map(\.id), ["z-generated-id"])
        XCTAssertNotNil(coordinator.atlas)
        XCTAssertNil(defaults.string(
            forKey: PetCoordinator.pendingGeneratedPetIDKey))

        coordinator.reloadLibrary()

        XCTAssertEqual(coordinator.selectedPetID, "z-generated-id")
        XCTAssertEqual(coordinator.packages.map(\.id), ["z-generated-id"])
        XCTAssertNotNil(coordinator.atlas)

        let relaunchedCoordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: libraryRoot,
            bundledLibraryRoot: nil)
        relaunchedCoordinator.reloadLibrary()

        XCTAssertEqual(relaunchedCoordinator.selectedPetID, "z-generated-id")
        XCTAssertEqual(
            relaunchedCoordinator.packages.map(\.id),
            ["z-generated-id"])
        XCTAssertNotNil(relaunchedCoordinator.atlas)
    }

    @MainActor
    func testUndecodableGeneratedPackageKeepsPendingTracking() throws {
        enum DecodeFailure: LocalizedError {
            case corrupt
            var errorDescription: String? { "corrupt pixel data" }
        }

        let libraryRoot = try temporaryDirectory()
        try writePackage(
            root: libraryRoot,
            folder: "generated",
            id: "generated-id",
            displayName: "Generated",
            version: 2,
            rows: 11)
        let suiteName = "detach-pet-decode-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "generated-id",
            forKey: PetCoordinator.pendingGeneratedPetIDKey)
        defaults.set(
            "generator-session",
            forKey: PetCoordinator.pendingGeneratedPetSessionIDKey)
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: libraryRoot,
            bundledLibraryRoot: nil,
            makeAtlas: { _ in throw DecodeFailure.corrupt })

        coordinator.reloadLibrary()

        XCTAssertEqual(
            defaults.string(forKey: PetCoordinator.pendingGeneratedPetIDKey),
            "generated-id")
        XCTAssertEqual(
            defaults.string(
                forKey: PetCoordinator.pendingGeneratedPetSessionIDKey),
            "generator-session")
        XCTAssertNil(coordinator.atlas)
        XCTAssertEqual(coordinator.loadError, "corrupt pixel data")
    }

    @MainActor
    func testWatcherDecodeFailureDoesNotReloadTheSelectedAtlas() async throws {
        enum DecodeFailure: LocalizedError {
            case corrupt
            var errorDescription: String? { "corrupt generated pixels" }
        }

        let libraryRoot = try temporaryDirectory()
        try writePackage(
            root: libraryRoot,
            folder: "selected",
            id: "selected-id",
            displayName: "Selected",
            version: 2,
            rows: 11)
        try writePackage(
            root: libraryRoot,
            folder: "generated-id",
            id: "generated-id",
            displayName: "Generated",
            version: 2,
            rows: 11)
        let suiteName = "detach-pet-watch-decode-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("selected-id", forKey: PetCoordinator.selectedPetIDKey)
        var selectedDecodeCount = 0
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: libraryRoot,
            bundledLibraryRoot: nil,
            generationPackageCheckSleep: { _ in },
            generationPackageCheckLimit: 2,
            makeAtlas: { package in
                if package.id == "generated-id" {
                    throw DecodeFailure.corrupt
                }
                selectedDecodeCount += 1
                return try PetAtlas(package: package)
            })
        coordinator.reloadLibrary()
        let baselineDecodeCount = selectedDecodeCount

        coordinator.beginGeneratedPetTracking(
            petID: "generated-id",
            sessionID: "generator-session")
        for _ in 0..<20 where !coordinator.generationTrackingTimedOut {
            await Task.yield()
        }

        XCTAssertTrue(coordinator.generationTrackingTimedOut)
        XCTAssertEqual(selectedDecodeCount, baselineDecodeCount)
        XCTAssertEqual(
            coordinator.generationPackageIssue,
            "corrupt generated pixels")
        XCTAssertEqual(coordinator.selectedPetID, "selected-id")
    }

    @MainActor
    func testUndecodableImportIsRejectedBeforeCopy() throws {
        enum DecodeFailure: Error { case corrupt }

        let sourceRoot = try temporaryDirectory()
        try writePackage(
            root: sourceRoot,
            folder: "source",
            id: "corrupt-id",
            displayName: "Corrupt",
            version: 2,
            rows: 11)
        let source = sourceRoot.appendingPathComponent(
            "source",
            isDirectory: true)
        let libraryRoot = try temporaryDirectory()
        let suiteName = "detach-pet-import-decode-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: libraryRoot,
            bundledLibraryRoot: nil,
            makeAtlas: { _ in throw DecodeFailure.corrupt })

        XCTAssertThrowsError(try coordinator.importPet(from: source))
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(
            at: libraryRoot,
            includingPropertiesForKeys: nil)).isEmpty)
    }

    @MainActor
    func testGeneratedPackageMissKeepsAtlasAndReportsPausedTracking() async throws {
        let libraryRoot = try temporaryDirectory()
        try writePackage(
            root: libraryRoot,
            folder: "selected",
            id: "selected-id",
            displayName: "Selected",
            version: 2,
            rows: 11)
        let suiteName = "detach-pet-watch-miss-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: libraryRoot,
            bundledLibraryRoot: nil,
            generationPackageCheckSleep: { _ in },
            generationPackageCheckLimit: 1)
        coordinator.reloadLibrary()
        coordinator.beginGeneratedPetTracking(
            petID: "missing-generated-id",
            sessionID: "generator-session")
        let atlas = try XCTUnwrap(coordinator.atlas)

        for _ in 0..<20 where !coordinator.generationTrackingTimedOut {
            await Task.yield()
        }

        XCTAssertTrue(coordinator.generationTrackingTimedOut)
        XCTAssertTrue(coordinator.atlas === atlas)
        XCTAssertEqual(
            defaults.string(forKey: PetCoordinator.pendingGeneratedPetIDKey),
            "missing-generated-id")
        XCTAssertEqual(
            defaults.string(
                forKey: PetCoordinator.pendingGeneratedPetSessionIDKey),
            "generator-session")

        try writePackage(
            root: libraryRoot,
            folder: "missing-generated-id",
            id: "missing-generated-id",
            displayName: "Generated Later",
            version: 2,
            rows: 11)
        coordinator.resumeGeneratedPetTracking()
        for _ in 0..<20 where coordinator.selectedPetID != "missing-generated-id" {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.selectedPetID, "missing-generated-id")
        XCTAssertFalse(coordinator.generationTrackingTimedOut)
        XCTAssertNil(defaults.string(
            forKey: PetCoordinator.pendingGeneratedPetIDKey))
    }

    func testOnlyBundledLumiUsesTheLocalizedDescriptionKey() {
        let lumiDirectory = URL(fileURLWithPath: "/tmp/Pets/lumi")
        let base = PetPackage(
            id: "actual-bundled-id",
            displayName: "Lumi",
            description: "Manifest description",
            spriteVersionNumber: 2,
            spritesheetURL: lumiDirectory.appendingPathComponent("pet.webp"),
            directoryURL: lumiDirectory,
            source: .bundled)

        XCTAssertTrue(base.usesBundledLumiDescription)
        XCTAssertFalse(PetPackage(
            id: base.id,
            displayName: base.displayName,
            description: base.description,
            spriteVersionNumber: base.spriteVersionNumber,
            spritesheetURL: base.spritesheetURL,
            directoryURL: base.directoryURL,
            source: .codexLibrary).usesBundledLumiDescription)
    }

    func testPickerDisambiguatesMatchingNamesBySourceAndID() {
        let bundled = pickerPackage(
            id: "bundled-lumi", displayName: "Lumi", source: .bundled)
        let custom = pickerPackage(
            id: "custom-lumi", displayName: "lumi", source: .codexLibrary)
        let unique = pickerPackage(
            id: "unique", displayName: "Nova", source: .codexLibrary)
        let packages = [bundled, custom, unique]
        let sourceName: (PetPackage.Source) -> String = {
            $0 == .bundled ? "Included" : "Codex"
        }

        XCTAssertEqual(
            PetPickerPresentation.title(
                for: bundled,
                among: packages,
                sourceName: sourceName),
            "Lumi — Included · bundled-lumi")
        XCTAssertEqual(
            PetPickerPresentation.title(
                for: custom,
                among: packages,
                sourceName: sourceName),
            "lumi — Codex · custom-lumi")
        XCTAssertEqual(
            PetPickerPresentation.title(
                for: unique,
                among: packages,
                sourceName: sourceName),
            "Nova")
    }

    @MainActor
    func testCoordinatorPublishesLibraryAccessIssues() throws {
        let parent = try temporaryDirectory()
        let root = parent.appendingPathComponent("pets")
        try Data("not a directory".utf8).write(to: root)
        let suiteName = "detach-pet-access-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: root,
            bundledLibraryRoot: nil)

        coordinator.reloadLibrary()

        XCTAssertEqual(coordinator.libraryAccessIssues, [
            PetLibraryAccessIssue(
                source: .codexLibrary,
                reason: .invalidRoot),
        ])
        XCTAssertNil(coordinator.loadError)
    }

    @MainActor
    func testCoordinatorDoesNotLoadSelectedPetThroughSymlinkedRoot() throws {
        let parent = try temporaryDirectory()
        let destination = parent.appendingPathComponent(
            "destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        try writePackage(
            root: destination,
            folder: "selected-id",
            id: "selected-id",
            displayName: "Selected",
            version: 2,
            rows: 11)
        let libraryRoot = parent.appendingPathComponent(
            "pets", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: libraryRoot, withDestinationURL: destination)
        let suiteName = "detach-pet-symlink-root-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set("selected-id", forKey: PetCoordinator.selectedPetIDKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: libraryRoot,
            bundledLibraryRoot: nil)

        coordinator.reloadLibrary()

        XCTAssertTrue(coordinator.packages.isEmpty)
        XCTAssertNil(coordinator.atlas)
        XCTAssertEqual(coordinator.libraryAccessIssues, [
            PetLibraryAccessIssue(
                source: .codexLibrary,
                reason: .invalidRoot),
        ])
    }

    @MainActor
    func testCoordinatorDoesNotLoadPendingPetThroughSymlinkedRoot() throws {
        let parent = try temporaryDirectory()
        let destination = parent.appendingPathComponent(
            "destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        try writePackage(
            root: destination,
            folder: "generated-id",
            id: "generated-id",
            displayName: "Generated",
            version: 2,
            rows: 11)
        let libraryRoot = parent.appendingPathComponent(
            "pets", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: libraryRoot, withDestinationURL: destination)
        let suiteName = "detach-pet-symlink-pending-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(
            "generated-id",
            forKey: PetCoordinator.pendingGeneratedPetIDKey)
        defaults.set(
            "generator-session",
            forKey: PetCoordinator.pendingGeneratedPetSessionIDKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: libraryRoot,
            bundledLibraryRoot: nil)

        coordinator.reloadLibrary()

        XCTAssertTrue(coordinator.packages.isEmpty)
        XCTAssertNil(coordinator.atlas)
        XCTAssertEqual(
            defaults.string(forKey: PetCoordinator.pendingGeneratedPetIDKey),
            "generated-id")
    }

    @MainActor
    func testEnsureLibraryDirectoryRejectsSymlinkedRoot() throws {
        let parent = try temporaryDirectory()
        let destination = parent.appendingPathComponent(
            "destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        let libraryRoot = parent.appendingPathComponent(
            "pets", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: libraryRoot, withDestinationURL: destination)
        let suiteName = "detach-pet-symlink-ensure-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: libraryRoot,
            bundledLibraryRoot: nil)

        XCTAssertThrowsError(try coordinator.ensureLibraryDirectory())
    }

    @MainActor
    func testReloadSelectsBundledPetWhenUserLibraryIsEmpty() throws {
        let userRoot = try temporaryDirectory()
        let bundledRoot = try temporaryDirectory()
        try writePackage(
            root: bundledRoot,
            folder: "bundled",
            id: "bundled-id",
            displayName: "Bundled",
            version: 2,
            rows: 11)
        let suiteName = "detach-bundled-pet-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: userRoot,
            bundledLibraryRoot: bundledRoot)

        coordinator.reloadLibrary()

        XCTAssertEqual(coordinator.packages.map(\.id), ["bundled-id"])
        XCTAssertEqual(coordinator.selectedPetID, "bundled-id")
        XCTAssertNotNil(coordinator.atlas)
        XCTAssertEqual(coordinator.libraryURL, userRoot)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "detach-pet-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func pickerPackage(
        id: String,
        displayName: String,
        source: PetPackage.Source
    ) -> PetPackage {
        let directory = URL(fileURLWithPath: "/tmp/\(id)", isDirectory: true)
        return PetPackage(
            id: id,
            displayName: displayName,
            description: "",
            spriteVersionNumber: 2,
            spritesheetURL: directory.appendingPathComponent("spritesheet.webp"),
            directoryURL: directory,
            source: source)
    }

    private func writePackage(
        root: URL,
        folder: String,
        id: String,
        displayName: String,
        version: Int?,
        rows: Int
    ) throws {
        let package = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(
            at: package, withIntermediateDirectories: true)
        try writeManifest(
            at: package,
            id: id,
            displayName: displayName,
            version: version,
            spritesheetPath: "spritesheet.png")
        try writeImage(
            at: package.appendingPathComponent("spritesheet.png"),
            width: 1_536,
            height: 208 * rows)
    }

    private func writeManifest(
        at package: URL,
        id: String,
        displayName: String,
        version: Int?,
        spritesheetPath: String
    ) throws {
        var object: [String: Any] = [
            "id": id,
            "displayName": displayName,
            "description": "Test pet",
            "spritesheetPath": spritesheetPath,
        ]
        if let version { object["spriteVersionNumber"] = version }
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: package.appendingPathComponent("pet.json"))
    }

    private func writeImage(at url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.2, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
