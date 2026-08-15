import SwiftUI

@main
struct M2MDisplayApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("M2M Display", systemImage: "rectangle.on.rectangle") {
            MenuBarView(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}
