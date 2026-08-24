import AppKit
import SwiftUI

@main
@MainActor
struct TsubameApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .defaultSize(width: 700, height: 500)
    }
}
