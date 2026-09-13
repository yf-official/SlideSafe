import SwiftUI

@main
struct SlideSafeApp: App {
    @AppStorage(AppPreferenceKey.language)
    private var languageRawValue = AppLanguage.initial.rawValue

    @AppStorage(AppPreferenceKey.appearance)
    private var appearanceRawValue = AppAppearance.system.rawValue

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRawValue) ?? .initial
    }

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRawValue) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ImportView()
                .environment(\.locale, language.locale)
                .preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 680, minHeight: 500)
        }
        .defaultSize(width: 760, height: 560)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(\.locale, language.locale)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
