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
        let sources = appRoot.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]))
        let expression = try NSRegularExpression(
            pattern: #"L10n\.(?:string|format)\(\s*\"((?:\\.|[^\"\\])*)\""#)
        var usedKeys: Set<String> = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let capture = Range(match.range(at: 1), in: source) else { continue }
                let key = source[capture]
                    .replacingOccurrences(of: #"\n"#, with: "\n")
                    .replacingOccurrences(of: #"\""#, with: "\"")
                    .replacingOccurrences(of: #"\\"#, with: #"\"#)
                usedKeys.insert(key)
            }
        }

        XCTAssertFalse(usedKeys.isEmpty)
        XCTAssertEqual(usedKeys.subtracting(english.keys), Set<String>())
    }

    private func stringsDictionary(language: String) throws -> [String: String] {
        let url = resources.bundleURL
            .appendingPathComponent("\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(value as? [String: String])
    }
}
