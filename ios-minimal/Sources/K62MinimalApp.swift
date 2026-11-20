import SwiftUI

@main
struct K62MinimalApp: App {
    @StateObject private var watch = Watch.shared
    @StateObject private var studio = FaceStudio.shared
    @StateObject private var carousel = PhotoCarousel.shared
    @AppStorage("k62.theme") private var theme = AppTheme.system.rawValue
    @Environment(\.scenePhase) private var phase

    init() {
        Watch.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(watch)
                .environmentObject(studio)
                .environmentObject(carousel)
                .preferredColorScheme((AppTheme(rawValue: theme) ?? .system).scheme)
                .tint(Palette.mint)
        }
        .onChange(of: phase) { p in
            if p == .active { PhotoCarousel.shared.rotateIfDue() }
        }
    }
}
