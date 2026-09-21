import SwiftUI

@main
struct CornBoxApp: App {
    init() {
        V6PlaybackRepair.install()
    }

    var body: some Scene {
        WindowGroup {
            RootViewV6()
                .preferredColorScheme(.dark)
        }
    }
}
