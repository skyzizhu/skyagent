import Foundation

enum L10n {
    nonisolated private static func selectedLanguagePreference() -> AppLanguagePreference {
        let raw = UserDefaults.standard.string(forKey: "appLanguagePreference") ?? AppLanguagePreference.system.rawValue
        return AppLanguagePreference(rawValue: raw) ?? .system
    }

    nonisolated private static func localizedBundle() -> Bundle {
        let preference = selectedLanguagePreference()
        guard let localeIdentifier = preference.localeIdentifier,
              let path = Bundle.main.path(forResource: localeIdentifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }

    nonisolated private static func formattingLocale() -> Locale {
        let preference = selectedLanguagePreference()
        guard let localeIdentifier = preference.localeIdentifier else {
            return .current
        }
        return Locale(identifier: localeIdentifier)
    }

    nonisolated static func tr(_ key: String) -> String {
        NSLocalizedString(key, bundle: localizedBundle(), comment: "")
    }

    nonisolated static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(key, bundle: localizedBundle(), comment: "")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: formattingLocale(), arguments: arguments)
    }
}
