import SwiftUI

enum AppPreferenceKey {
    static let language = "appLanguage"
    static let appearance = "appearanceMode"
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    static var initial: AppLanguage {
        let preferredLanguage = Locale.preferredLanguages.first ?? "en"
        return preferredLanguage.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var title: LocalizedStringKey {
        switch self {
        case .simplifiedChinese:
            return "language.chinese"
        case .english:
            return "language.english"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system:
            return "appearance.system"
        case .light:
            return "appearance.light"
        case .dark:
            return "appearance.dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
