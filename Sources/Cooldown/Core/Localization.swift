import Foundation

/// The language Cooldown speaks: the first of the person's languages it has a translation for.
/// The source text is Russian; every other language comes from <lang>.lproj/Localizable.strings.
enum AppLanguage {
    static let code: String = Bundle.main.preferredLocalizations.first ?? "en"

    /// The locale for dates and numbers: the person's own regional variant of that language.
    static let locale: Locale = {
        let base = String(code.prefix(2))
        let preferred = Locale.preferredLanguages.first { $0.hasPrefix(base) } ?? code
        return Locale(identifier: preferred)
    }()

    /// Plural forms: Russian and Ukrainian have three, most others two, some one.
    static func pluralIndex(_ n: Int, forms: Int) -> Int {
        guard forms > 1 else { return 0 }
        let base = String(code.prefix(2))
        if forms >= 3 || base == "ru" || base == "uk" {
            let n10 = n % 10, n100 = n % 100
            if n10 == 1 && n100 != 11 { return 0 }
            if (2...4).contains(n10) && !(12...14).contains(n100) { return min(1, forms - 1) }
            return min(2, forms - 1)
        }
        if base == "fr" || (base == "pt" && code != "pt-PT") { return n <= 1 ? 0 : 1 }
        return n == 1 ? 0 : 1
    }
}

/// The text in the person's language.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// The text in the person's language, with values put in (%@ in the source).
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: AppLanguage.locale, arguments: arguments)
}
