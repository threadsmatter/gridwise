import SwiftUI

@main
struct GridwiseApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup("Gridwise") {
            MainView().environmentObject(store)
        }
        .defaultSize(width: 1100, height: 900)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Setup…") { store.showSetup = true }.keyboardShortcut(",")
            }
        }
    }
}
