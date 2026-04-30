import Foundation
import EmbeddedMockEngine
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation) && os(iOS)
import AVFoundation
#endif

/// A log entry representing a single HTTP request handled by the mock engine.
struct RequestLogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let method: String
    let url: String
    let routeID: String?
    let statusCode: Int
}

/// Observable wrapper around ``MockEngine`` for use in SwiftUI.
///
/// Manages the server lifecycle, configuration loading, request logging,
/// and iOS background execution so the server stays alive when the app
/// is not in the foreground.
///
/// ## Background Mode (iOS only)
/// On iOS the app uses the `audio` background mode to keep the server alive
/// when backgrounded. A silent audio session is activated to prevent iOS from
/// suspending the process. The `UIBackgroundTask` API provides a fallback
/// grace period if the audio session is interrupted.
///
/// On macOS there is no suspension concern — the server simply keeps running.
@MainActor
final class ServerManager: ObservableObject {

    // MARK: - Published state

    @Published var isRunning = false
    @Published var port: UInt16 = 8080
    @Published var assignedPort: UInt16?
    @Published var routeCount: Int = 0
    @Published var logEntries: [RequestLogEntry] = []
    @Published var statusMessage: String = "Server stopped"
    @Published var configurationName: String = "DefaultMockConfig"
    @Published var isBackgroundModeEnabled = true

    // MARK: - Private state

    private let engine = MockEngine()
    private var monitorTask: Task<Void, Never>?
    private let monitorIntervalNanoseconds: UInt64 = 2_000_000_000
    private var isServerTransitionInProgress = false
    private var isHealthCheckRestartInProgress = false

    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var silentAudioPlayer: AVAudioPlayer?
    #endif

    /// Maximum number of log entries to keep in memory.
    private let maxLogEntries = 500

    // MARK: - Init

    init() {
        #if os(iOS)
        registerForAppLifecycleNotifications()
        #endif
    }

    deinit {
        monitorTask?.cancel()
    }

    // MARK: - Server lifecycle

    func startServer() async {
        guard !isRunning, !isServerTransitionInProgress else { return }
        isServerTransitionInProgress = true
        defer { isServerTransitionInProgress = false }
        guard port != 0 else {
            statusMessage = "Invalid port: 0. Please choose a specific port."
            return
        }

        do {
            await engine.setRequestObserver { [weak self] method, url, routeID, statusCode in
                let entry = RequestLogEntry(
                    timestamp: Date(),
                    method: method,
                    url: url,
                    routeID: routeID,
                    statusCode: statusCode
                )
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.logEntries.insert(entry, at: 0)
                    if self.logEntries.count > self.maxLogEntries {
                        self.logEntries.removeLast(self.logEntries.count - self.maxLogEntries)
                    }
                }
            }

            let assigned = try await engine.start(port: port)
            assignedPort = assigned
            isRunning = true
            routeCount = await engine.routeCount
            statusMessage = "Server running on port \(assigned)"
            startHealthMonitor()

            #if os(iOS)
            if isBackgroundModeEnabled {
                activateBackgroundMode()
            }
            #endif
        } catch {
            statusMessage = "Failed to start: \(error.localizedDescription)"
        }
    }

    func stopServer() async {
        guard isRunning, !isServerTransitionInProgress else { return }
        isServerTransitionInProgress = true
        defer { isServerTransitionInProgress = false }

        stopHealthMonitor()
        await engine.stop()
        isRunning = false
        assignedPort = nil
        statusMessage = "Server stopped"

        #if os(iOS)
        deactivateBackgroundMode()
        #endif
    }

    func clearLog() {
        logEntries.removeAll()
    }

    private func startHealthMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: monitorIntervalNanoseconds)
                guard !Task.isCancelled else { break }

                let isHealthy = await self.engine.healthCheck()
                if isHealthy { continue }
                if self.isHealthCheckRestartInProgress { continue }

                self.isHealthCheckRestartInProgress = true
                defer { self.isHealthCheckRestartInProgress = false }

                self.isRunning = false
                self.assignedPort = nil
                self.statusMessage = "Health check failed — restarting server"

                await self.engine.stop()

                do {
                    let restartedPort = try await self.engine.start(port: self.port)
                    self.assignedPort = restartedPort
                    self.isRunning = true
                    self.statusMessage = "Server restarted on port \(restartedPort)"
                } catch {
                    self.statusMessage = "Server unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    private func stopHealthMonitor() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    // MARK: - Configuration

    /// Loads configuration from a JSON file URL (e.g. imported via document picker).
    func loadConfiguration(from url: URL) async {
        do {
            let wasRunning = isRunning
            if wasRunning { await stopServer() }

            try await engine.loadConfiguration(from: url)
            routeCount = await engine.routeCount
            configurationName = url.deletingPathExtension().lastPathComponent
            statusMessage = "Loaded \(routeCount) routes from \(configurationName)"

            if wasRunning { await startServer() }
        } catch {
            statusMessage = "Config error: \(error.localizedDescription)"
        }
    }

    /// Loads the default configuration bundled with the app.
    func loadDefaultConfiguration() async {
        guard let url = Bundle.main.url(forResource: "DefaultMockConfig", withExtension: "json") else {
            statusMessage = "Default config not found in bundle"
            return
        }
        await loadConfiguration(from: url)
    }

    // MARK: - URL scheme handling

    /// Handles incoming URLs from other apps.
    ///
    /// Supported URL schemes:
    /// - `mockengine://start`           — Start the server
    /// - `mockengine://start?port=9090` — Start on a specific port
    /// - `mockengine://stop`            — Stop the server
    /// - `mockengine://status`          — No-op (app comes to foreground showing status)
    func handleURL(_ url: URL) async {
        guard let host = url.host?.lowercased() else { return }

        switch host {
        case "start":
            if let portParam = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "port" })?.value,
               let requestedPort = UInt16(portParam),
               requestedPort != 0 {
                port = requestedPort
            }
            await startServer()

        case "stop":
            await stopServer()

        case "status":
            // Just bringing the app to foreground is enough
            break

        default:
            break
        }
    }

    // MARK: - iOS Background Mode Support

    #if os(iOS)
    private func registerForAppLifecycleNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func appDidEnterBackground() {
        guard isRunning, isBackgroundModeEnabled else { return }
        activateBackgroundMode()
    }

    @objc private func appWillEnterForeground() {
        // Stop the silent audio when returning to foreground to save resources.
        stopSilentAudio()
        endBackgroundTask()

        // Sync published state with the engine.
        // The engine may have transparently restarted its socket via its own
        // lifecycle observer while the app was backgrounded/suspended.
        guard isRunning, !isServerTransitionInProgress else { return }
        Task {
            // Give the engine's own foreground handler a moment to complete
            // before we read back its state.
            try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
            let enginePort = await engine.currentPort
            if let enginePort {
                assignedPort = enginePort
                statusMessage = "Server running on port \(enginePort)"
            } else {
                // Engine socket is gone and self-restart failed; let the health
                // monitor's next tick trigger a full restart.
                statusMessage = "Server recovering…"
            }
        }
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // Audio was interrupted (e.g. phone call, Siri). Player stops automatically.
            // The background task expiration handler is already in place as a safety net.
            break

        case .ended:
            guard isRunning, isBackgroundModeEnabled else { return }
            // Resume silent audio only if iOS signals it's safe to do so.
            let shouldResume = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionOptions(rawValue: $0) }
                .map { $0.contains(.shouldResume) } ?? false
            guard shouldResume else { return }
            startSilentAudio()

        @unknown default:
            break
        }
    }

    /// Activates background execution by starting a silent audio session and
    /// requesting a background task as a fallback.
    private func activateBackgroundMode() {
        startSilentAudio()
        beginBackgroundTask()
    }

    /// Deactivates all background execution helpers.
    private func deactivateBackgroundMode() {
        stopSilentAudio()
        endBackgroundTask()
    }

    // MARK: Background task (fallback — ~30 s grace period)

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "MockEngineServer") { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if self.silentAudioPlayer?.isPlaying != true {
                    self.statusMessage = "Background time expired — server stopped"
                    await self.stopServer()
                }
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: Silent audio session (keeps process alive indefinitely on iOS)

    private func startSilentAudio() {
        guard silentAudioPlayer == nil || silentAudioPlayer?.isPlaying == false else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try session.setActive(true)

            let silentData = Self.generateSilentWAV(sampleRate: 8000, numSamples: 8000)
            let player = try AVAudioPlayer(data: silentData)
            player.numberOfLoops = -1
            player.volume = 0.0
            player.play()
            silentAudioPlayer = player
        } catch {
            print("[MockEngine] Silent audio session failed: \(error)")
        }
    }

    private func stopSilentAudio() {
        silentAudioPlayer?.stop()
        silentAudioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Generates a minimal WAV file (PCM 16-bit mono) filled with silence.
    private static func generateSilentWAV(sampleRate: Int, numSamples: Int) -> Data {
        let bitsPerSample = 16
        let numChannels = 1
        let byteRate = sampleRate * numChannels * bitsPerSample / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = numSamples * blockAlign
        let fileSize = 36 + dataSize

        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(numChannels).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        data.append(Data(count: dataSize))
        return data
    }
    #endif
}
