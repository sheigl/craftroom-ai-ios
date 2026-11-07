import SwiftUI

@main
struct CraftRoomAIApp: App {
    @StateObject private var model: AppModel
    @StateObject private var ladder: LadderController

    init() {
        // Both views share one model cache: the product flow and a manual ladder
        // run must never hold two UNets at once.
        let engine = Engine()
        _model = StateObject(wrappedValue: AppModel(engine: engine))
        _ladder = StateObject(wrappedValue: LadderController(engine: engine))
        // One line per launch: proves the process got this far, and gives the
        // on-screen log something to show before the first Generate tap.
        Diagnostics.log("app launch")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(ladder)
                .tint(Theme.accent)
        }
    }
}
