import Foundation

// MARK: - HTTPResponse

/// An outgoing HTTP/1.x response that will be serialised and sent over a socket.
public struct HTTPResponse: Sendable {
    /// HTTP status code (e.g. 200, 404).
    public let statusCode: Int
    /// Response headers.  `Content-Length` is added automatically by the serialiser.
    public let headers: [String: String]
    /// Raw response body (may be nil for HEAD/204/304/etc.).
    public let body: Data?

    public init(statusCode: Int, headers: [String: String] = [:], body: Data? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

// MARK: - Convenience factory methods

public extension HTTPResponse {

    /// 200 OK with an optional body.
    static func ok(body: Data? = nil, contentType: String = "application/json") -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": contentType],
            body: body
        )
    }

    /// 400 Bad Request.
    static func badRequest(message: String = "Bad Request") -> HTTPResponse {
        HTTPResponse(
            statusCode: 400,
            headers: ["Content-Type": "text/plain"],
            body: message.data(using: .utf8)
        )
    }

    /// 404 Not Found.
    static func notFound(message: String = "Not Found") -> HTTPResponse {
        HTTPResponse(
            statusCode: 404,
            headers: ["Content-Type": "text/plain"],
            body: message.data(using: .utf8)
        )
    }

    /// 500 Internal Server Error.
    static func internalError(message: String = "Internal Server Error") -> HTTPResponse {
        HTTPResponse(
            statusCode: 500,
            headers: ["Content-Type": "text/plain"],
            body: message.data(using: .utf8)
        )
    }
}

// MARK: - HTTPStatusLine

/// Maps status codes to their standard reason phrases.
enum HTTPStatusLine {
    static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 100: return "Continue"
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default:  return "Unknown"
        }
    }
}
