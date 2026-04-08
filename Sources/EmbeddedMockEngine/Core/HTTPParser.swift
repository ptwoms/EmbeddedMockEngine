import Foundation

// MARK: - HTTPParser

/// Parses raw bytes received from a TCP socket into an ``HTTPRequest``.
///
/// Supports HTTP/1.0 and HTTP/1.1 with optional body determined by
/// the `Content-Length` header.  Chunked transfer-encoding is not supported.
enum HTTPParser {

    // MARK: - Completeness check

    /// Returns `true` when `data` contains a complete HTTP request
    /// (full headers + the number of body bytes indicated by `Content-Length`).
    static func isComplete(_ data: Data) -> Bool {
        guard let headerRange = headerBodySeparatorRange(in: data) else {
            return false    // headers not yet fully received
        }

        let headerEnd = headerRange.upperBound
        let headerBytes = data[data.startIndex..<headerRange.lowerBound]

        if let headerText = String(bytes: headerBytes, encoding: .utf8),
           let contentLength = parseContentLength(from: headerText) {
            let bodyBytesReceived = data.count - headerEnd
            return bodyBytesReceived >= contentLength
        }

        return true     // no body expected
    }

    // MARK: - Parse

    /// Parses `data` into an ``HTTPRequest``.
    /// - Returns: A parsed request, or `nil` if the data is malformed.
    static func parse(data: Data) -> HTTPRequest? {
        guard let headerRange = headerBodySeparatorRange(in: data) else { return nil }

        let headerEnd   = headerRange.upperBound
        let headerBytes = data[data.startIndex..<headerRange.lowerBound]

        guard let headerText = String(bytes: headerBytes, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst()
        let requestParts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }

        let method = String(requestParts[0])
        let rawURL  = String(requestParts[1])

        let (path, queryParams) = parseURL(rawURL)

        // Parse headers (lowercased names for case-insensitive comparison)
        var headers: [String: String] = [:]
        for line in lines {
            guard !line.isEmpty else { continue }
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name  = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // Parse body
        var body: Data? = nil
        if data.count > headerEnd {
            let bodySlice = data[headerEnd...]
            if !bodySlice.isEmpty {
                if let contentLength = parseContentLength(from: headerText) {
                    body = Data(bodySlice.prefix(contentLength))
                } else {
                    body = Data(bodySlice)
                }
            }
        }

        return HTTPRequest(
            method: method,
            path: path,
            queryParameters: queryParams,
            headers: headers,
            body: body,
            rawURL: rawURL
        )
    }

    // MARK: - Private helpers

    /// Returns the range of the `\r\n\r\n` separator between headers and body.
    private static func headerBodySeparatorRange(in data: Data) -> Range<Int>? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
        let sepLen = separator.count

        guard data.count >= sepLen else { return nil }

        let bytes = [UInt8](data)
        for i in 0...(bytes.count - sepLen) {
            if bytes[i..<(i + sepLen)].elementsEqual(separator) {
                return i..<(i + sepLen)
            }
        }
        return nil
    }

    /// Extracts the value of the `Content-Length` header from raw header text.
    private static func parseContentLength(from headerText: String) -> Int? {
        for line in headerText.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = lower
                    .dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    /// Splits a raw URL like `/path?key=value&key2=value2` into the decoded path
    /// and a dictionary of decoded query parameters.
    static func parseURL(_ rawURL: String) -> (path: String, queryParameters: [String: String]) {
        guard let questionMark = rawURL.firstIndex(of: "?") else {
            let decoded = percentDecoded(rawURL)
            return (decoded, [:])
        }

        let rawPath  = String(rawURL[rawURL.startIndex..<questionMark])
        let rawQuery = String(rawURL[rawURL.index(after: questionMark)...])

        let path   = percentDecoded(rawPath)
        let params = parseQueryString(rawQuery)

        return (path, params)
    }

    /// Parses `key=value&key2=value2` into a dictionary.
    static func parseQueryString(_ queryString: String) -> [String: String] {
        var params: [String: String] = [:]
        for pair in queryString.components(separatedBy: "&") {
            guard !pair.isEmpty else { continue }
            let parts = pair.components(separatedBy: "=")
            let key   = percentDecoded(parts[0].replacingOccurrences(of: "+", with: " "))
            let value = parts.count > 1
                ? percentDecoded(parts[1...].joined(separator: "=").replacingOccurrences(of: "+", with: " "))
                : ""
            params[key] = value
        }
        return params
    }

    /// Percent-decodes a URL component.
    private static func percentDecoded(_ string: String) -> String {
        string.removingPercentEncoding ?? string
    }
}
