import SwiftUI

@main
struct K62MinimalApp: App {
    @StateObject private var watch = Watch.shared
    @StateObject private var studio = FaceStudio.shared

    init() {
        Watch.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(watch)
                .environmentObject(studio)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.37, green: 0.88, blue: 0.71))
        }
    }
}
