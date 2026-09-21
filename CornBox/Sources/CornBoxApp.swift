import SwiftUI

@main
struct CornBoxApp: App {
    init() {
        V6PlaybackRepair.install()
    }

    var body: some Scene {
        WindowGroup {
            RootViewV7()
                .preferredColorScheme(.dark)
        }
    }
}
