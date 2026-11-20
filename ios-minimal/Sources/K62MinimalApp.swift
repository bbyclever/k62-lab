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

    private var appTheme: AppTheme { AppTheme(rawValue: theme) ?? .system }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(watch)
                .environmentObject(studio)
                .environmentObject(carousel)
                .tint(Palette.mint)
                .onAppear { appTheme.apply() }
                .onChange(of: theme) { _ in appTheme.apply() }
        }
        .onChange(of: phase) { p in
            if p == .active {
                appTheme.apply()
                PhotoCarousel.shared.rotateIfDue()
            }
        }
    }
}
