import SwiftUI

@main
struct K62LabNativeApp: App {
    @StateObject private var bluetooth = K62BluetoothManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetooth)
        }
    }
}
