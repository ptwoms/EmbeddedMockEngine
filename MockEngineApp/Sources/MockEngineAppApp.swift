import SwiftUI

/// The main entry point for the MockEngine standalone app (iOS & macOS).
///
/// This app runs EmbeddedMockEngine as an HTTP server that other apps on the
/// same device (iOS) or machine (macOS) can reach via `http://localhost:<port>/…`.
///
/// ## URL Scheme
/// Other apps can control the server by opening URLs:
/// - `mockengine://start`           — Start the server
/// - `mockengine://start?port=9090` — Start on a specific port
/// - `mockengine://stop`            — Stop the server
/// - `mockengine://status`          — Bring the app to the foreground
@main
struct MockEngineApp: App {
    @StateObject private var serverManager = ServerManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serverManager)
                .onOpenURL { url in
                    Task {
                        await serverManager.handleURL(url)
                    }
                }
                .task {
                    await serverManager.loadDefaultConfiguration()
                }
        }
        #if os(macOS)
        .defaultSize(width: 500, height: 600)
        #endif
    }
}
