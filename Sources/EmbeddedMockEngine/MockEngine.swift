import Foundation

#if canImport(UIKit)
import UIKit
#endif

// MARK: - MockEngine

/// The primary public interface for EmbeddedMockEngine.
///
/// `MockEngine` embeds a full HTTP/1.x server inside your app or test target.
/// It matches incoming requests against a prioritised list of ``MockRoute``s and
/// returns the configured canned response (loaded from a file or specified inline).
///
/// ### Quick start
/// ```swift
/// let engine = MockEngine()
///
/// // Load routes from a JSON config file
/// try engine.loadConfiguration(from: configURL)
///
/// // Start listening (port 0 = OS-assigned free port)
/// let port = try await engine.start()
/// print("Mock server on http://localhost:\(port)")
///
/// // … run your tests …
///
/// await engine.stop()
/// ```
///
/// ### Programmatic configuration
/// ```swift
/// let engine = MockEngine()
/// engine.addRoute(MockRoute(
///     id: "list-users",
///     request: MockRequestMatcher(method: .get, urlPattern: "/api/users"),
///     response: MockResponseDefinition(statusCode: 200, body: #"{"users":[]}"#)
/// ))
/// let port = try await engine.start(port: 9090)
/// ```
public actor MockEngine {

    // MARK: - Stored state

    private var routes: [MockRoute] = []
    private var settings: MockServerSettings = MockServerSettings()
    private var responseProvider: ResponseProvider = ResponseProvider()

    private let server = MockServer()
    private var running = false
    /// The port the server was last started on (0 = not started yet).
    /// Used to restore the same port when the app returns to the foreground.
    private var lastStartedPort: UInt16 = 0

    // MARK: - App-lifecycle observers (iOS only)

#if canImport(UIKit)
    /// Retained references to the NotificationCenter observer tokens.
    /// Marked `nonisolated(unsafe)` so they can be cleared from `deinit`,
    /// which runs outside the actor's isolation domain.
    nonisolated(unsafe) private var backgroundObserver: NSObjectProtocol?
    nonisolated(unsafe) private var foregroundObserver: NSObjectProtocol?
#endif

    // MARK: - Init

    public init() {
#if canImport(UIKit)
        registerAppLifecycleObservers()
#endif
    }

    deinit {
#if canImport(UIKit)
        removeAppLifecycleObservers()
#endif
    }

    // MARK: - Configuration

    /// Loads ``MockConfiguration`` from a JSON file at `url`.
    ///
    /// Response files referenced inside the config are resolved relative to the
    /// directory that contains the config file.
    public func loadConfiguration(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(MockConfiguration.self, from: data)
        applyConfiguration(config, baseURL: url.deletingLastPathComponent(), bundle: nil)
    }

    /// Loads ``MockConfiguration`` from a JSON resource in a `Bundle`.
    ///
    /// - Parameters:
    ///   - name:      Resource name without extension (e.g. `"MockConfig"`).
    ///   - extension: File extension, default `"json"`.
    ///   - bundle:    Bundle to search; defaults to the main bundle.
    public func loadConfiguration(
        bundleResource name: String,
        withExtension ext: String = "json",
        bundle: Bundle = .main
    ) throws {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw MockEngineError.resourceNotFound(name: name, extension: ext)
        }
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(MockConfiguration.self, from: data)
        applyConfiguration(config, baseURL: url.deletingLastPathComponent(), bundle: bundle)
    }

    /// Applies a pre-built ``MockConfiguration`` programmatically.
    public func configure(with configuration: MockConfiguration, baseURL: URL? = nil, bundle: Bundle? = nil) {
        applyConfiguration(configuration, baseURL: baseURL, bundle: bundle)
    }

    /// Appends a single route.  Routes added later do **not** reset previously
    /// loaded routes — they are appended and re-sorted by priority.
    public func addRoute(_ route: MockRoute) {
        routes.append(route)
        sortRoutes()
    }

    /// Replaces all routes.
    public func setRoutes(_ newRoutes: [MockRoute]) {
        routes = newRoutes
        sortRoutes()
    }

    /// Removes all routes.
    public func clearRoutes() {
        routes = []
    }

    // MARK: - Lifecycle

    /// Starts the mock server and returns the TCP port it is listening on.
    ///
    /// - Parameter port: Port to bind to. Pass `0` (default) to let the OS
    ///   choose a free port.
    /// - Returns: The port number the server is actually listening on.
    @discardableResult
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        guard !running else { throw MockEngineError.alreadyRunning }

        let effectivePort = settings.port ?? port
        let handler = makeRequestHandler()
        let assignedPort = try server.start(port: effectivePort, requestHandler: handler)
        running = true
        lastStartedPort = assignedPort
        return assignedPort
    }

    /// Stops the mock server.
    public func stop() async {
        guard running else { return }
        server.stop()
        running = false
    }

    // MARK: - Introspection

    /// The port the server is listening on, or `nil` if not running.
    public var currentPort: UInt16? {
        running ? server.port : nil
    }

    /// `true` while the server is running.
    public var isRunning: Bool { running }

    // MARK: - Private helpers

    private func applyConfiguration(
        _ config: MockConfiguration,
        baseURL: URL?,
        bundle: Bundle?
    ) {
        if let s = config.settings { settings = s }
        routes = config.routes
        sortRoutes()
        responseProvider = ResponseProvider(baseURL: baseURL, bundle: bundle)
    }

    private func sortRoutes() {
        routes.sort { ($0.priority ?? 0) > ($1.priority ?? 0) }
    }

    /// Builds the request-handler closure that is injected into ``MockServer``.
    /// The closure captures a snapshot of the current routes/provider so that
    /// changes after `start()` are reflected immediately (actor re-entry is safe
    /// because we await back on the actor before reading state).
    private func makeRequestHandler() -> @Sendable (HTTPRequest) async -> HTTPResponse {
        // We capture `self` (the actor) so that `handleRequest` runs on the
        // actor's executor and can safely read `routes` and `responseProvider`.
        return { [weak self] request in
            guard let self else { return .internalError() }
            return await self.handleRequest(request)
        }
    }

    private func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        if settings.logRequests == true {
            print("[MockEngine] \(request.method) \(request.rawURL)")
        }

        // Find the first matching route (already sorted by priority)
        guard let route = routes.first(where: { RequestMatcher.matches(request: request, against: $0.request) }) else {
            if settings.logRequests == true {
                print("[MockEngine] No route matched – returning 404")
            }
            return .notFound(message: "No mock route matched \(request.method) \(request.path)")
        }

        if settings.logRequests == true {
            print("[MockEngine] Matched route '\(route.id)'")
        }

        // Combine global delay and per-route delay
        let totalDelay = (settings.globalDelay ?? 0) + (route.response.delay ?? 0)
        if totalDelay > 0 {
            let ns = UInt64(totalDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
        }

        return responseProvider.resolve(definition: route.response)
    }

    // MARK: - App lifecycle (iOS)

#if canImport(UIKit)
    /// Registers for `UIApplication` background / foreground notifications so the
    /// server is stopped when the app enters the background and restarted when it
    /// returns to the foreground.
    private nonisolated func registerAppLifecycleObservers() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleDidEnterBackground() }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleWillEnterForeground() }
        }
    }

    private nonisolated func removeAppLifecycleObservers() {
        if let obs = backgroundObserver {
            NotificationCenter.default.removeObserver(obs)
            backgroundObserver = nil
        }
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
            foregroundObserver = nil
        }
    }

    /// Called when the app enters the background: stops the server gracefully.
    private func handleDidEnterBackground() {
        guard running else { return }
        server.stop()
        running = false
    }

    /// Called when the app returns to the foreground: restarts the server on the
    /// same port it was previously listening on (falls back to any free port if the
    /// previous port is no longer available).
    private func handleWillEnterForeground() {
        guard !running else { return }
        let port = lastStartedPort
        let handler = makeRequestHandler()
        // Try the original port first; fall back to OS-assigned port on failure.
        if let assignedPort = try? server.start(port: port, requestHandler: handler) {
            running = true
            lastStartedPort = assignedPort
        } else if port != 0, let assignedPort = try? server.start(port: 0, requestHandler: handler) {
            running = true
            lastStartedPort = assignedPort
        } else {
            print("[MockEngine] Failed to restart server after returning to foreground")
        }
    }
#endif
}

// MARK: - MockEngineError

public enum MockEngineError: Error, Sendable {
    case alreadyRunning
    case notRunning
    case resourceNotFound(name: String, extension: String)
    case configurationDecodingFailed(underlying: Error)
}
