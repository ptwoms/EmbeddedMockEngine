import Foundation

// MARK: - MockConfiguration

/// Top-level configuration loaded from a JSON file.
///
/// Example JSON layout:
/// ```json
/// {
///   "settings": { "port": 8080, "logRequests": true },
///   "routes": [ ... ]
/// }
/// ```
public struct MockConfiguration: Codable, Sendable {
    /// Global server settings (optional – all fields have defaults).
    public let settings: MockServerSettings?
    /// Ordered list of routes. The first matching route wins unless `priority` is used.
    public let routes: [MockRoute]

    public init(settings: MockServerSettings? = nil, routes: [MockRoute] = []) {
        self.settings = settings
        self.routes = routes
    }
}

// MARK: - MockServerSettings

/// Global settings that apply to the mock server.
public struct MockServerSettings: Codable, Sendable {
    /// Port to listen on. Use `0` (default) for automatic assignment.
    public let port: UInt16?
    /// Global response delay in seconds added to every response.
    public let globalDelay: TimeInterval?
    /// Whether to log each incoming request to stdout.
    public let logRequests: Bool?

    public init(port: UInt16? = nil, globalDelay: TimeInterval? = nil, logRequests: Bool? = nil) {
        self.port = port
        self.globalDelay = globalDelay
        self.logRequests = logRequests
    }
}

// MARK: - MockRoute

/// A single route that pairs a request matcher with a canned response.
public struct MockRoute: Codable, Sendable {
    /// Unique identifier for this route (used for debugging / logging).
    public let id: String
    /// Criteria used to match incoming requests.
    public let request: MockRequestMatcher
    /// Response to return when this route is matched.
    public let response: MockResponseDefinition
    /// Higher priority routes are evaluated first. Default: 0.
    public let priority: Int?

    public init(
        id: String,
        request: MockRequestMatcher,
        response: MockResponseDefinition,
        priority: Int? = nil
    ) {
        self.id = id
        self.request = request
        self.response = response
        self.priority = priority
    }
}

// MARK: - MockRequestMatcher

/// Criteria applied to an incoming request to decide whether a route matches.
///
/// All non-nil fields must match for the route to be selected.
/// Query-parameter and header matching is *subset* matching — the request may
/// carry additional parameters/headers beyond those listed here.
public struct MockRequestMatcher: Codable, Sendable {
    /// HTTP method (GET, POST, …). `nil` matches any method.
    public let method: HTTPMethod?
    /// URL path pattern. Supports:
    /// - Exact path:        `/api/users`
    /// - Wildcard:          `/api/users/*`   (`*` matches any single segment)
    /// - Double wildcard:   `/api/**`        (`**` matches zero or more segments)
    /// - Path parameters:   `/api/users/{id}`
    /// - Explicit regex:    `~^/api/users/[0-9]+$~`  (wrap in `~` delimiters)
    public let urlPattern: String?
    /// Headers that must be present (subset match, case-insensitive names).
    public let headers: [String: String]?
    /// Query parameters that must be present (subset match).
    public let queryParameters: [String: String]?
    /// Regular-expression pattern applied to the raw request body (UTF-8 string).
    public let bodyPattern: String?

    public init(
        method: HTTPMethod? = nil,
        urlPattern: String? = nil,
        headers: [String: String]? = nil,
        queryParameters: [String: String]? = nil,
        bodyPattern: String? = nil
    ) {
        self.method = method
        self.urlPattern = urlPattern
        self.headers = headers
        self.queryParameters = queryParameters
        self.bodyPattern = bodyPattern
    }
}

// MARK: - HTTPMethod

/// Standard HTTP methods.
public enum HTTPMethod: String, Codable, Sendable, CaseIterable {
    case get     = "GET"
    case post    = "POST"
    case put     = "PUT"
    case delete  = "DELETE"
    case patch   = "PATCH"
    case head    = "HEAD"
    case options = "OPTIONS"
    case trace   = "TRACE"
    case connect = "CONNECT"
}

// MARK: - MockResponseDefinition

/// Defines the response to return when a route is matched.
public struct MockResponseDefinition: Codable, Sendable {
    /// HTTP status code. Default: 200.
    public let statusCode: Int
    /// Response headers to include.
    public let headers: [String: String]?
    /// Path to a file containing the response body.
    /// Resolved relative to the directory that contains the config file,
    /// or relative to the bundle that loaded the config.
    public let bodyFile: String?
    /// Inline response body (used when `bodyFile` is nil).
    public let body: String?
    /// Extra delay (in seconds) before this response is sent.
    public let delay: TimeInterval?

    public init(
        statusCode: Int = 200,
        headers: [String: String]? = nil,
        bodyFile: String? = nil,
        body: String? = nil,
        delay: TimeInterval? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.bodyFile = bodyFile
        self.body = body
        self.delay = delay
    }
}
