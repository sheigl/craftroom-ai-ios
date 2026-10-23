import SwiftUI

@main
struct CraftRoomAIApp: App {
    init() {
        // One line per launch: proves the process got this far, and gives the
        // on-screen log something to show before the first Generate tap.
        Diagnostics.log("app launch")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
