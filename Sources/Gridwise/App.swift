import SwiftUI

@main
struct GridwiseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()
    @ObservedObject private var curtailer = Curtailer.shared

    var body: some Scene {
        Window("Gridwise", id: "main") {
            MainView().environmentObject(store)
                .task { curtailer.store = store; curtailer.resume() }
        }
        .defaultSize(width: 1100, height: 900)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Setup…") { store.showSetup = true }.keyboardShortcut(",")
            }
        }
        MenuBarExtra {
            MenuContent().environmentObject(store)
        } label: {
            Image(systemName: curtailer.curtailing ? "sun.max.trianglebadge.exclamationmark" : "sun.horizon")
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var cur = Curtailer.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Buy \(Fmt.cents(store.now("general")?.perKwh)) · feed-in \(Fmt.feedIn(store.now("feedIn")?.perKwh))")
        if let c = cur.config {
            Divider()
            Text("Curtailment (\(c.live ? "live" : "dry run")): \(cur.status)")
        }
        Divider()
        Button("Open Gridwise") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        if cur.config != nil { Button("Stop curtailment and put the limit back") { Task { await cur.stop() } } }
        Button("Quit Gridwise") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
