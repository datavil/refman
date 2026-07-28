import SwiftUI

@main
struct RefmanIOSApp: App {
    @State private var model = IPadAppModel.live()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
