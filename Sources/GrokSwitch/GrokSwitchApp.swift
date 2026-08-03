import SwiftUI

@main
struct GrokSwitchApp: App {
    @StateObject private var store = ProfileStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
        } label: {
            // CodexBar-style brand mark (16pt template); remaining % is title text.
            HStack(spacing: 4) {
                MenuBarIcon.image(usage: store.activeUsage)
                    .renderingMode(.template)
                    .frame(width: 16, height: 16)
                if !store.menuBarTitle.isEmpty {
                    Text(store.menuBarTitle)
                }
            }
        }
        .menuBarExtraStyle(.window)

        // Settings scene keeps the app from being pure accessory-only in some macOS versions;
        // we still set LSUIElement so there's no Dock icon.
        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
