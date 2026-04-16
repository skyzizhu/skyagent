import Foundation

enum AppContentLanguage: String, CaseIterable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ja
    case ko
    case de
    case fr

    nonisolated init(localeIdentifier: String) {
        let normalized = localeIdentifier.lowercased()
        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh_tw") || normalized.hasPrefix("zh-hk") {
            self = .zhHant
        } else if normalized.hasPrefix("zh") {
            self = .zhHans
        } else if normalized.hasPrefix("ja") {
            self = .ja
        } else if normalized.hasPrefix("ko") {
            self = .ko
        } else if normalized.hasPrefix("de") {
            self = .de
        } else if normalized.hasPrefix("fr") {
            self = .fr
        } else {
            self = .en
        }
    }
}

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

    nonisolated static var contentLanguage: AppContentLanguage {
        let preference = selectedLanguagePreference()
        if let localeIdentifier = preference.localeIdentifier {
            return AppContentLanguage(localeIdentifier: localeIdentifier)
        }
        let systemIdentifier = Locale.preferredLanguages.first ?? Locale.current.identifier
        return AppContentLanguage(localeIdentifier: systemIdentifier)
    }

    nonisolated static func tr(_ key: String) -> String {
        NSLocalizedString(key, bundle: localizedBundle(), comment: "")
    }

    nonisolated static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(key, bundle: localizedBundle(), comment: "")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: formattingLocale(), arguments: arguments)
    }

    nonisolated static func tr(_ key: String, arguments: [String]) -> String {
        let format = NSLocalizedString(key, bundle: localizedBundle(), comment: "")
        guard !arguments.isEmpty else { return format }
        let cVarArgs: [CVarArg] = arguments.map { $0 }
        return String(format: format, locale: formattingLocale(), arguments: cVarArgs)
    }
}
