import Foundation

/// Localized strings shared by the app and the app-facing parts of DetachKit.
///
/// Packaged builds install the localization tables in the application bundle.
/// The English source text is also the lookup key, which gives command-line
/// SwiftPM builds a readable fallback when there is no application bundle.
public enum L10n {
    public static func string(
        _ key: String,
        bundle: Bundle = .main,
        locale: Locale? = nil
    ) -> String {
        localizationBundle(bundle, for: locale).localizedString(
            forKey: key,
            value: key,
            table: "Localizable")
    }

    public static func format(
        _ key: String,
        bundle: Bundle = .main,
        locale: Locale? = nil,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: string(key, bundle: bundle, locale: locale),
            locale: locale ?? .current,
            arguments: arguments)
    }

    private static func localizationBundle(
        _ resources: Bundle,
        for locale: Locale?
    ) -> Bundle {
        guard let locale,
              let languageCode = locale.language.languageCode?.identifier,
              let path = resources.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return resources
        }
        return bundle
    }
}
