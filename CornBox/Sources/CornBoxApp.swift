import SwiftUI

@main
struct CornBoxApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        }
    }
}
