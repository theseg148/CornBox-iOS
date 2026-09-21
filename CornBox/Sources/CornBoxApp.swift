import SwiftUI

@main
struct CornBoxApp: App {
    @StateObject private var store = CornBoxStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
