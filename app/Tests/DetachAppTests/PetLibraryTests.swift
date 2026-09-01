import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DetachApp

final class PetLibraryTests: XCTestCase {
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

    @MainActor
    func testReloadSelectsACompletedPendingGeneratedPet() throws {
        let libraryRoot = try temporaryDirectory()
        try writePackage(
            root: libraryRoot,
            folder: "generated",
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
