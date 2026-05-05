import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(UIKit)
import UIKit

// MARK: - LifecycleObserver

/// Observes UIApplication foreground/background notifications on behalf of MockEngine.
///
/// Extracted into its own class because actors cannot use `@objc` selectors and
/// `NotificationCenter` block-based observation needs a non-isolated owner.
private final class LifecycleObserver: @unchecked Sendable {
    private var foregroundToken: NSObjectProtocol?
    private var backgroundToken: NSObjectProtocol?

    init(
        onWillEnterForeground: @escaping @Sendable () -> Void,
        onDidEnterBackground: @escaping @Sendable () -> Void
    ) {
        foregroundToken = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { _ in onWillEnterForeground() }

        backgroundToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { _ in onDidEnterBackground() }
    }

    deinit {
        [foregroundToken, backgroundToken].compactMap { $0 }.forEach {
            NotificationCenter.default.removeObserver($0)
        }
    }
}
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
    /// Base URL from which TLS cert/key paths (and response file paths) are resolved.
    private var configBaseURL: URL?

    private let server = MockServer()
    private var running = false

    /// The port the server was last successfully bound to, used for transparent restarts.
    private var lastBoundPort: UInt16 = 0
    /// The bind address used at the last successful `start()`.
    private var lastBindAddress: String = "127.0.0.1"
    /// The TLS config used at the last successful `start()`, retained for restarts.
    private var lastTLSConfiguration: TLSConfiguration?

    #if canImport(UIKit)
    private var lifecycleObserver: LifecycleObserver?
    #endif

    /// Optional callback invoked on every request for external logging (e.g. UI).
    /// Parameters: HTTP method, raw URL, matched route ID (nil if 404), status code.
    private var requestObserver: (@Sendable (String, String, String?, Int) -> Void)?

    /// Called after the engine transparently restarts the server on iOS foreground return.
    ///
    /// Receives the new port number the server is listening on.  Useful for callers that
    /// need to update UI or stored state when the engine self-heals after being backgrounded.
    public var foregroundRestartHandler: (@Sendable (UInt16) -> Void)?

    // MARK: - Init

    public init() {}

    /// Sets an observer that is called for every incoming request.
    ///
    /// - Parameter observer: A closure receiving `(method, rawURL, matchedRouteID?, statusCode)`.
    ///   Pass `nil` to remove the observer.
    public func setRequestObserver(_ observer: (@Sendable (String, String, String?, Int) -> Void)?) {
        self.requestObserver = observer
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
    /// - Parameters:
    ///   - port: Port to bind to. Pass `0` (default) to let the OS choose a free port.
    ///   - tls:  Optional TLS configuration for HTTPS. When provided, cert and key
    ///           paths are resolved relative to the config base URL (if any).
    ///           Overrides any TLS configuration set in ``MockServerSettings``.
    /// - Returns: The port number the server is actually listening on.
    @discardableResult
    public func start(port: UInt16 = 0, tls: TLSConfiguration? = nil) async throws -> UInt16 {
        guard !running else { throw MockEngineError.alreadyRunning }

        let effectivePort = settings.port ?? port
        let effectiveBindAddress = settings.bindAddress ?? "127.0.0.1"
        // Explicit `tls` parameter takes precedence over settings.
        let effectiveTLS = tls ?? settings.tlsConfiguration
        let handler = makeRequestHandler()

        // Resolve TLS cert/key paths relative to the config base URL.
        let resolvedTLS: TLSConfiguration? = effectiveTLS.map { cfg in
            TLSConfiguration(
                certificateFile: cfg.resolvedCertificateURL(relativeTo: configBaseURL).path,
                privateKeyFile:  cfg.resolvedPrivateKeyURL(relativeTo: configBaseURL).path
            )
        }

        let assignedPort = try server.start(
            port: effectivePort,
            bindAddress: effectiveBindAddress,
            tls: resolvedTLS,
            requestHandler: handler
        )
        running = true
        lastBoundPort = assignedPort
        lastBindAddress = effectiveBindAddress
        lastTLSConfiguration = resolvedTLS
        if settings.logRequests {
            let scheme = resolvedTLS != nil ? "https" : "http"
            print("[MockEngine] Server started on \(scheme)://\(effectiveBindAddress):\(assignedPort)")
        }

        #if canImport(UIKit)
        registerLifecycleObserver()
        #endif

        return assignedPort
    }

    /// Stops the mock server.
    public func stop() async {
        guard running else {
            if settings.logRequests {
                print("[MockEngine] Stop called but server is not running")
            }
            return
        }
        #if canImport(UIKit)
        lifecycleObserver = nil
        #endif
        server.stop()
        if settings.logRequests {
            let scheme = lastTLSConfiguration != nil ? "https" : "http"
            print("[MockEngine] Server stopped on \(scheme)://\(lastBindAddress):\(lastBoundPort)")
        }
        running = false
        lastBoundPort = 0
        lastTLSConfiguration = nil
    }

    // MARK: - Introspection

    /// The port the server is listening on, or `nil` if not running.
    public var currentPort: UInt16? {
        (running && server.isRunning) ? server.port : nil
    }

    /// `true` while the server is running.
    public var isRunning: Bool { running && server.isRunning }

    /// Performs an active probe against this mock server.
    ///
    /// Uses a lightweight TCP connect to verify the port is actually accepting
    /// connections, without going through the HTTP/URLSession stack.
    ///
    /// - Returns: `true` if the TCP connection succeeds, otherwise `false`.
    public func healthCheck() -> Bool {
        guard running, server.isRunning, let port = currentPort else { return false }

#if canImport(Darwin)
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
#else
        let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
#endif
        guard fd >= 0 else { return false }
        defer {
#if canImport(Darwin)
            Darwin.close(fd)
#else
            Glibc.close(fd)
#endif
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
#if canImport(Darwin)
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
#else
        addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
#endif

        let result = withUnsafeBytes(of: &addr) { ptr in
            connect(fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                    socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        return result == 0
    }

    /// The number of currently loaded routes.
    public var routeCount: Int { routes.count }

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
        configBaseURL = baseURL
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

    // MARK: - iOS lifecycle

    #if canImport(UIKit)
    /// Registers for UIApplication foreground/background events.
    /// Safe to call multiple times — always replaces any previous observer.
    private func registerLifecycleObserver() {
        lifecycleObserver = LifecycleObserver(
            onWillEnterForeground: { [weak self] in
                Task { await self?.handleWillEnterForeground() }
            },
            onDidEnterBackground: { [weak self] in
                Task { await self?.handleDidEnterBackground() }
            }
        )
    }

    /// Called when the app is about to return to the foreground.
    ///
    /// If the engine was running but its socket was killed by iOS while the app
    /// was suspended, this method transparently restarts the server on the same
    /// port and fires `foregroundRestartHandler` so callers can update their UI.
    private func handleWillEnterForeground() async {
        guard running else { return }

        // Socket still alive — nothing to do.
        if healthCheck() { return }
        
        if settings.logRequests {
            print("[MockEngine] Detected dead socket on foreground return; restarting server…")
        }

        // The socket was killed while in the background. Tear down stale state
        // and bind a fresh socket on the same port.
        server.stop()
        running = false

        let portToReuse = lastBoundPort
        let bindAddr = lastBindAddress
        let tlsConfig = lastTLSConfiguration
        let handler = makeRequestHandler()

        do {
            let newPort = try server.start(
                port: portToReuse,
                bindAddress: bindAddr,
                tls: tlsConfig,
                requestHandler: handler
            )
            running = true
            lastBoundPort = newPort
            lastTLSConfiguration = tlsConfig
            foregroundRestartHandler?(newPort)
        } catch {
            print("[MockEngine] Auto-restart after foreground failed: \(error)")
        }
    }

    /// Called when the app enters the background.
    ///
    /// Currently a no-op at the framework level; reserved for future use
    /// (e.g. signalling a graceful-drain period before suspension).
    private func handleDidEnterBackground() async {}
    #endif

    private func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        if settings.logRequests {
            print("[MockEngine] \(request.method) \(request.rawURL)")
        }

        // Find the first matching route (already sorted by priority)
        guard let route = routes.first(where: { RequestMatcher.matches(request: request, against: $0.request) }) else {
            // Built-in health endpoint: GET /health returns 200 unless overridden by a configured route
            if request.method == "GET" && request.path == "/health" {
                requestObserver?(request.method, request.rawURL, nil, 200)
                return .ok()
            }
            if settings.logRequests {
                print("[MockEngine] No route matched – returning 404")
            }
            requestObserver?(request.method, request.rawURL, nil, 404)
            return .notFound(message: "No mock route matched \(request.method) \(request.path)")
        }

        if settings.logRequests {
            print("[MockEngine] Matched route '\(route.id)'")
        }

        // Combine global delay and per-route delay
        let totalDelay = (settings.globalDelay ?? 0) + (route.response.delay ?? 0)
        if totalDelay > 0 {
            let ns = UInt64(totalDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
        }

        let response = responseProvider.resolve(definition: route.response)
        requestObserver?(request.method, request.rawURL, route.id, response.statusCode)
        return response
    }
}

// MARK: - MockEngineError

public enum MockEngineError: Error, Sendable {
    case alreadyRunning
    case notRunning
    case resourceNotFound(name: String, extension: String)
    case configurationDecodingFailed(underlying: Error)
}
