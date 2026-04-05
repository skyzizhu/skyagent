import Foundation

enum L10n {
    private static let bundle: Bundle = .main

    static func tr(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }

    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(key, bundle: bundle, comment: "")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
