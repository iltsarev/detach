import XCTest
@testable import DetachKit

final class TerminalCatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDiscoversOnlyAppsThatDeclareCommandFileSupport() throws {
        _ = try makeApplication(
            name: "ZetaTerm", bundleIdentifier: "test.zeta", supportsCommandFiles: true)
        _ = try makeApplication(
            name: "Editor", bundleIdentifier: "test.editor", supportsCommandFiles: false)
        let alpha = try makeApplication(
            name: "AlphaTerm", bundleIdentifier: "test.alpha", supportsCommandFiles: true)

        let applications = TerminalCatalog.installedApplications(
            registeredApplicationURLs: [alpha],
            searchRoots: [root],
            fileManager: .default)

        XCTAssertEqual(applications.map(\.displayName), ["AlphaTerm", "ZetaTerm"])
        XCTAssertEqual(Set(applications.map(\.bundleIdentifier)), ["test.alpha", "test.zeta"])
    }

    func testRecognizesLegacyCommandExtensionDeclaration() {
        XCTAssertTrue(TerminalCatalog.declaresShellScriptSupport([
            "CFBundleDocumentTypes": [[
                "CFBundleTypeRole": "Shell",
                "CFBundleTypeExtensions": ["COMMAND"],
            ]],
        ]))
    }

    func testRejectsEditorRoleEvenWhenItHandlesCommandFiles() {
        XCTAssertFalse(TerminalCatalog.declaresShellScriptSupport([
            "CFBundleDocumentTypes": [[
                "CFBundleTypeRole": "Editor",
                "LSItemContentTypes": [TerminalCatalog.shellScriptContentType],
            ]],
        ]))
    }

    func testAcceptsShellRoleDeclaredForUnixExecutables() {
        // iTerm2 declares .command files under an Editor-role entry and the
        // Shell role only for public.unix-executable; the Shell entry alone
        // must qualify the app as a terminal.
        XCTAssertTrue(TerminalCatalog.declaresShellScriptSupport(iTermStyleInfoDictionary))
    }

    func testRejectsEditorsThatOnlyEditShellScripts() {
        XCTAssertFalse(TerminalCatalog.declaresShellScriptSupport([
            "CFBundleDocumentTypes": [[
                "CFBundleTypeRole": "Editor",
                "CFBundleTypeExtensions": ["sh", "command", "bashrc", "zshrc"],
            ]],
        ]))
    }

    func testRejectsShellRoleForUnrelatedDocumentTypes() {
        XCTAssertFalse(TerminalCatalog.declaresShellScriptSupport([
            "CFBundleDocumentTypes": [[
                "CFBundleTypeRole": "Shell",
                "LSItemContentTypes": ["com.example.game-project"],
            ]],
        ]))
    }

    func testDiscoversTerminalsWithITermStyleDeclarations() throws {
        _ = try makeApplication(
            name: "UnixExecTerm",
            bundleIdentifier: "test.unixexec",
            documentTypes: iTermStyleInfoDictionary["CFBundleDocumentTypes"] as? [[String: Any]])

        let applications = TerminalCatalog.installedApplications(
            registeredApplicationURLs: [],
            searchRoots: [root],
            fileManager: .default)

        XCTAssertEqual(applications.map(\.bundleIdentifier), ["test.unixexec"])
    }

    func testResolvesManuallyChosenApplicationWithoutDeclarations() throws {
        let applicationURL = try makeApplication(
            name: "BareTerm", bundleIdentifier: "test.bare", documentTypes: nil)

        let application = TerminalCatalog.application(at: applicationURL)

        XCTAssertEqual(application?.bundleIdentifier, "test.bare")
        XCTAssertEqual(application?.displayName, "BareTerm")
    }

    func testTerminalApplicationIdentityAndDisplayNameFallbacks() throws {
        let bundleNameURL = try makeApplication(
            name: "BundleNameTerm",
            bundleIdentifier: "test.bundle-name",
            documentTypes: nil,
            displayName: nil,
            bundleName: "Bundle Name")
        let filenameURL = try makeApplication(
            name: "FilenameTerm",
            bundleIdentifier: "test.filename",
            documentTypes: nil,
            displayName: nil,
            bundleName: nil)

        let bundleName = try XCTUnwrap(TerminalCatalog.application(at: bundleNameURL))
        let filename = try XCTUnwrap(TerminalCatalog.application(at: filenameURL))

        XCTAssertEqual(bundleName.id, "test.bundle-name")
        XCTAssertEqual(bundleName.displayName, "Bundle Name")
        XCTAssertEqual(filename.displayName, "FilenameTerm")
    }

    func testApplicationWithoutABundleIdentifierIsRejected() throws {
        let url = try makeApplication(
            name: "NoIdentifier",
            bundleIdentifier: nil,
            documentTypes: nil,
            displayName: "No Identifier",
            bundleName: nil)

        XCTAssertNil(TerminalCatalog.application(at: url))
    }

    func testDiscoveryPrefersRegisteredDuplicateAndUsesBundleIDAsSortTieBreaker() throws {
        let registeredRoot = root.appendingPathComponent("registered", isDirectory: true)
        let searchedRoot = root.appendingPathComponent("searched", isDirectory: true)
        try FileManager.default.createDirectory(at: registeredRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: searchedRoot, withIntermediateDirectories: true)
        let originalRoot = root
        root = registeredRoot
        let registered = try makeApplication(
            name: "Registered", bundleIdentifier: "test.duplicate", supportsCommandFiles: true,
            displayName: "Same Name")
        let alpha = try makeApplication(
            name: "Alpha", bundleIdentifier: "test.alpha-tie", supportsCommandFiles: true,
            displayName: "Same Name")
        root = searchedRoot
        _ = try makeApplication(
            name: "Discovered", bundleIdentifier: "test.duplicate", supportsCommandFiles: true,
            displayName: "Different Name")
        let beta = try makeApplication(
            name: "Beta", bundleIdentifier: "test.beta-tie", supportsCommandFiles: true,
            displayName: "Same Name")
        root = originalRoot

        let applications = TerminalCatalog.installedApplications(
            registeredApplicationURLs: [registered, alpha, beta],
            searchRoots: [searchedRoot],
            fileManager: .default)

        XCTAssertEqual(applications.map(\.bundleIdentifier), [
            "test.alpha-tie", "test.beta-tie", "test.duplicate",
        ])
        XCTAssertEqual(
            applications.first { $0.bundleIdentifier == "test.duplicate" }?.applicationURL,
            registered)
    }

    func testDefaultSearchRootsCoverSystemAndUserApplicationDirectories() {
        let paths = TerminalCatalog.defaultSearchRoots.map(\.path)

        XCTAssertTrue(paths.contains("/Applications"))
        XCTAssertTrue(paths.contains("/System/Applications"))
        XCTAssertTrue(paths.contains("/System/Library/CoreServices/Applications"))
        XCTAssertTrue(paths.contains(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications").path))
    }

    func testShellDeclarationParsingIsCaseInsensitiveAndRejectsMissingShape() {
        XCTAssertTrue(TerminalCatalog.declaresShellScriptSupport([
            "CFBundleDocumentTypes": [[
                "CFBundleTypeRole": "sHeLl",
                "LSItemContentTypes": ["PUBLIC.EXECUTABLE"],
            ]],
        ]))
        XCTAssertFalse(TerminalCatalog.declaresShellScriptSupport([:]))
        XCTAssertFalse(TerminalCatalog.declaresShellScriptSupport([
            "CFBundleDocumentTypes": [[
                "LSItemContentTypes": ["public.executable"],
            ]],
        ]))
    }

    private var iTermStyleInfoDictionary: [String: Any] {
        [
            "CFBundleDocumentTypes": [
                [
                    "CFBundleTypeRole": "Editor",
                    "CFBundleTypeExtensions": ["command", "tool", "sh", "zsh", "csh", "pl"],
                ],
                [
                    "CFBundleTypeRole": "Shell",
                    "LSItemContentTypes": ["public.unix-executable"],
                ],
            ],
        ]
    }

    private func makeApplication(
        name: String,
        bundleIdentifier: String,
        supportsCommandFiles: Bool,
        displayName: String? = nil
    ) throws -> URL {
        try makeApplication(
            name: name,
            bundleIdentifier: bundleIdentifier,
            documentTypes: supportsCommandFiles
                ? [[
                    "CFBundleTypeRole": "Shell",
                    "LSItemContentTypes": [TerminalCatalog.shellScriptContentType],
                ]]
                : nil,
            displayName: displayName ?? name,
            bundleName: name)
    }

    private func makeApplication(
        name: String,
        bundleIdentifier: String?,
        documentTypes: [[String: Any]]?,
        displayName: String? = nil,
        bundleName: String? = nil
    ) throws -> URL {
        let applicationURL = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
        ]
        if let bundleIdentifier { info["CFBundleIdentifier"] = bundleIdentifier }
        if let displayName { info["CFBundleDisplayName"] = displayName }
        if let bundleName { info["CFBundleName"] = bundleName }
        if let documentTypes {
            info["CFBundleDocumentTypes"] = documentTypes
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return applicationURL
    }
}
