import SwiftUI

struct SettingsView: View {
    @AppStorage(AppPreferenceKey.language)
    private var languageRawValue = AppLanguage.initial.rawValue

    @AppStorage(AppPreferenceKey.appearance)
    private var appearanceRawValue = AppAppearance.system.rawValue

    var body: some View {
        Form {
            Section("settings.general") {
                Picker("settings.language", selection: $languageRawValue) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title)
                            .tag(language.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Picker("settings.appearance", selection: $appearanceRawValue) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title)
                            .tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 230)
        .navigationTitle("settings.title")
    }
}

#Preview {
    SettingsView()
}
