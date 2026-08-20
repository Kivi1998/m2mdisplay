import SwiftUI

@main
struct M2MDisplayApp: App {
    @NSApplicationDelegateAdaptor(M2MApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("M2M Display", systemImage: "rectangle.on.rectangle") {
            MenuBarView(appState: appDelegate.appState)
        }
        .menuBarExtraStyle(.window)
    }
}
