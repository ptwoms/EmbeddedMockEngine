import Foundation

// MARK: - HTTPRequest

/// An incoming HTTP/1.x request parsed from raw bytes received over a socket.
public struct HTTPRequest: Sendable {
    /// HTTP method (e.g. "GET", "POST").
    public let method: String
    /// Decoded URL path without query string (e.g. "/api/users").
    public let path: String
    /// Decoded query parameters.
    public let queryParameters: [String: String]
    /// All request headers with lowercased names.
    public let headers: [String: String]
    /// Raw request body, if any.
    public let body: Data?
    /// The raw request URL as received (path + optional query string).
    public let rawURL: String

    public init(
        method: String,
        path: String,
        queryParameters: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil,
        rawURL: String
    ) {
        self.method = method
        self.path = path
        self.queryParameters = queryParameters
        self.headers = headers
        self.body = body
        self.rawURL = rawURL
    }
}
