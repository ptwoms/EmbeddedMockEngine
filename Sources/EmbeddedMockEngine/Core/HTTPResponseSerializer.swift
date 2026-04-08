import Foundation

// MARK: - HTTPResponseSerializer

/// Serialises an ``HTTPResponse`` into raw bytes ready to be written to a socket.
///
/// The output conforms to HTTP/1.1 wire format:
/// ```
/// HTTP/1.1 <statusCode> <reasonPhrase>\r\n
/// <Header-Name>: <Header-Value>\r\n
/// Content-Length: <n>\r\n
/// Connection: close\r\n
/// \r\n
/// <body bytes>
/// ```
enum HTTPResponseSerializer {

    static func serialize(_ response: HTTPResponse) -> Data {
        var output = Data()

        // Status line
        let reason = HTTPStatusLine.reasonPhrase(for: response.statusCode)
        append("HTTP/1.1 \(response.statusCode) \(reason)\r\n", to: &output)

        // User-supplied headers
        for (name, value) in response.headers {
            append("\(name): \(value)\r\n", to: &output)
        }

        // Content-Length (always present)
        let bodyLength = response.body?.count ?? 0
        append("Content-Length: \(bodyLength)\r\n", to: &output)

        // Connection close (we don't support keep-alive in the mock server)
        append("Connection: close\r\n", to: &output)

        // Header/body separator
        append("\r\n", to: &output)

        // Body
        if let body = response.body, !body.isEmpty {
            output.append(body)
        }

        return output
    }

    // MARK: - Private

    private static func append(_ string: String, to data: inout Data) {
        if let bytes = string.data(using: .utf8) {
            data.append(bytes)
        }
    }
}
