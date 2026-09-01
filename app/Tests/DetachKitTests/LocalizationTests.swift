import Foundation
import XCTest
@testable import DetachKit

final class LocalizationTests: XCTestCase {
    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var resources: Bundle {
        guard let bundle = Bundle(path: appRoot.appendingPathComponent("Resources").path) else {
            XCTFail("Could not load app localization resources")
            return .main
        }
        return bundle
    }

    func testEnglishAndRussianLookups() {
        XCTAssertEqual(
            L10n.string("Working", bundle: resources, locale: Locale(identifier: "en")),
            "Working")
        XCTAssertEqual(
            L10n.string("Working", bundle: resources, locale: Locale(identifier: "ru")),
            "Работают")
        XCTAssertEqual(
            L10n.format(
                "%@ tokens",
                bundle: resources,
                locale: Locale(identifier: "ru"),
                "361k"),
            "361k токенов")
        XCTAssertEqual(
            L10n.string(
                "Session failed",
                bundle: resources,
                locale: Locale(identifier: "ru")),
            "Сессия завершилась с ошибкой")
        XCTAssertEqual(
            L10n.format(
                "Exit code: %d",
                bundle: resources,
                locale: Locale(identifier: "ru"),
                7),
            "Код выхода: 7")
        XCTAssertEqual(
            L10n.string(
                "Mac can sleep: temperature",
                bundle: resources,
                locale: Locale(identifier: "en")),
            "Mac can sleep: temperature")
        XCTAssertEqual(
            L10n.string(
                "Mac can sleep: temperature",
                bundle: resources,
                locale: Locale(identifier: "ru")),
            "Mac может уснуть: высокая температура")
        XCTAssertEqual(
            L10n.string(
                "Temperature safety active",
                bundle: resources,
                locale: Locale(identifier: "ru")),
            "Включена температурная защита")
        XCTAssertEqual(
            L10n.string(
                "Add Pet…",
                bundle: resources,
                locale: Locale(identifier: "ru")),
            "Добавить питомца…")
        XCTAssertEqual(
            L10n.string(
                "Generate Random Pet",
                bundle: resources,
                locale: Locale(identifier: "ru")),
            "Сгенерировать питомца")
        XCTAssertEqual(
            L10n.string(
                "Generating Pet…",
                bundle: resources,
                locale: Locale(identifier: "ru")),
            "Генерируем питомца…")
        XCTAssertEqual(
            L10n.string(
                "Continue Pet Generation",
                bundle: resources,
                locale: Locale(identifier: "ru")),
            "Продолжить генерацию питомца")
        XCTAssertEqual(
            L10n.string(
                "Starting a managed Codex CLI session…",
                bundle: resources,
                locale: Locale(identifier: "ru")),
            "Запускаем управляемую CLI-сессию Codex…")
    }

    func testLocalizationTablesHaveMatchingKeysAndEnglishFallbacks() throws {
        let english = try stringsDictionary(language: "en")
        let russian = try stringsDictionary(language: "ru")

        XCTAssertEqual(Set(english.keys), Set(russian.keys))
        XCTAssertFalse(english.isEmpty)
        for (key, value) in english {
            XCTAssertEqual(value, key, "English source text must remain the fallback for \(key)")
            XCTAssertFalse(russian[key, default: ""].isEmpty)
        }
    }

    func testEveryLiteralLookupHasATranslation() throws {
        let english = try stringsDictionary(language: "en")
        let usedKeys = try literalL10nLookups()
        XCTAssertEqual(usedKeys.subtracting(english.keys), Set<String>())
    }

    func testEveryTranslationIsReferencedFromSource() throws {
        let english = try stringsDictionary(language: "en")
        let referenced = try referencedLocalizationKeys()
        XCTAssertEqual(
            Set(english.keys).subtracting(referenced),
            [],
            "Every Localizable key must come from an L10n.string/format literal or an owned dynamic producer")
        XCTAssertEqual(
            dynamicProducerKeys.subtracting(english.keys),
            [],
            "Owned dynamic producer keys must have translations")
    }

    func testQuotedCommentOrUnrelatedLiteralDoesNotCountAsAReference() throws {
        let source = """
        // "Orphan localization key"
        let title = "Orphan localization key"
        L10n.string("Working")
        """
        XCTAssertEqual(literalL10nKeys(in: source), ["Working"])
    }

    func testEveryTipCatalogEntryHasEnglishAndRussianTranslations() throws {
        let english = try stringsDictionary(language: "en")
        let russian = try stringsDictionary(language: "ru")

        for tip in TipCatalog.all {
            XCTAssertNotNil(english[tip.localizationKey], "Missing English tip: \(tip.id)")
            XCTAssertNotNil(russian[tip.localizationKey], "Missing Russian tip: \(tip.id)")
        }
    }

    func testUpdateNotificationAndBackgroundFlowsHaveBothLocales() throws {
        let english = try stringsDictionary(language: "en")
        let russian = try stringsDictionary(language: "ru")
        let keys = [
            "Allow notifications",
            "Open System Settings",
            "macOS doesn't show the prompt again after a denial. Allow notifications for Detach in System Settings.",
            "Detach cannot update from this app location. Move Detach to /Applications. The active CLI did not change. Then try again.",
            "Detach could not prepare or download the update: %@. The active CLI did not change. Check the network connection and free disk space. Then try again.",
            "Detach rejected or could not install the update: %@. The active CLI did not change. Download the latest DMG. If the CLI does not match the app, open Detach settings, select System, and run Repair.",
        ]

        for key in keys {
            XCTAssertEqual(english[key], key)
            XCTAssertNotNil(russian[key])
            XCTAssertNotEqual(russian[key], key)
        }
    }

    /// Status, tip, and power presentation keys are not always written as
    /// literal `L10n.string` / `L10n.format` calls.
    private var dynamicProducerKeys: Set<String> {
        Set(TipCatalog.all.map(\.localizationKey))
            .union([
                "starting", "running", "recovering", "hung",
                "completed", "failed", "interrupted", "stopped",
                "recoverable", "orphaned", "corrupt", "collision", "unknown",
            ])
            .union([
                "Mac stays awake",
                "Mac can sleep",
                "Enabling sleep protection",
                "Mac can sleep: low battery",
                "Mac can sleep: temperature",
                "Sleep protection unavailable",
                "Sleep status unknown",
            ])
            .union([
                "The native power helper is registered, but its live check failed.",
                "One-time administrator approval is required for native sleep protection.",
                "The native power helper is not registered yet.",
                "The native power helper is unavailable.",
            ])
            .union([
                "Clear selection", "Done", "Select", "Select all",
                "Deselect %@ from deletion", "Select %@ for deletion",
            ])
    }

    private func referencedLocalizationKeys() throws -> Set<String> {
        try literalL10nLookups().union(dynamicProducerKeys)
    }

    private func literalL10nLookups() throws -> Set<String> {
        let sources = appRoot.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]))
        var usedKeys: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            usedKeys.formUnion(literalL10nKeys(in: source))
        }
        XCTAssertFalse(usedKeys.isEmpty)
        return usedKeys
    }

    private func literalL10nKeys(in source: String) -> Set<String> {
        let expression = try! NSRegularExpression(
            pattern: #"L10n\.(?:string|format)\(\s*\"((?:\\.|[^\"\\])*)\""#)
        let range = NSRange(source.startIndex..., in: source)
        var keys: Set<String> = []
        for match in expression.matches(in: source, range: range) {
            guard let capture = Range(match.range(at: 1), in: source) else { continue }
            let key = source[capture]
                .replacingOccurrences(of: #"\n"#, with: "\n")
                .replacingOccurrences(of: #"\""#, with: "\"")
                .replacingOccurrences(of: #"\\"#, with: #"\"#)
            keys.insert(key)
        }
        return keys
    }

    private func stringsDictionary(language: String) throws -> [String: String] {
        let url = resources.bundleURL
            .appendingPathComponent("\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(value as? [String: String])
    }
}
