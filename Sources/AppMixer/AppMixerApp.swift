import SwiftUI

@main
struct AppMixerApp: App {
    @StateObject private var mixer = MixerModel()

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environmentObject(mixer)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .accessibilityLabel("App Mixer")
        }
        .menuBarExtraStyle(.window)

        Window("App Mixer", id: "mixer") {
            MixerView()
                .environmentObject(mixer)
        }
        .defaultSize(width: 430, height: 590)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(mixer)
        }
    }
}
